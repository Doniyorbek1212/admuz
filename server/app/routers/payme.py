"""Payme Merchant API: the UZARO balance topped up through Payme, credited the moment Payme performs the payment.

The app asks POST /v1/wallet/payme for an order and opens the returned checkout link. Payme then calls
POST /v1/payments/payme (JSON-RPC 2.0, Basic auth "Paycom:<key>") with CheckPerformTransaction, CreateTransaction,
PerformTransaction, CancelTransaction, CheckTransaction and GetStatement; the account carries our order_id.
Every answer is HTTP 200 with "result" or "error", as Payme expects. Amounts from Payme are in tiyin (so'm × 100).
"""

import base64
import binascii
import logging
import time
import uuid
from typing import Annotated, Any

from fastapi import APIRouter, Request
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.deps import CustomerDep, DbDep, rate_limit
from app.errors import unavailable
from app.models import PaymeOrder
from app.security import constant_time_equals
from app.services import pay_notify, wallet
from app.services.audit import audit

router = APIRouter(prefix="/v1", tags=["payme"])
log = logging.getLogger("app.payme")

# Payme cancels a created transaction it has not performed within 12 hours.
TRANSACTION_TIMEOUT_MS = 12 * 60 * 60 * 1000
MIN_TOPUP_UZS = 1_000
MAX_TOPUP_UZS = 50_000_000

STATE_NEW, STATE_CREATED, STATE_PERFORMED = 0, 1, 2
STATE_CANCELLED, STATE_CANCELLED_AFTER_PERFORM = -1, -2
REASON_TIMEOUT = 4

# Payme error codes.
ERR_PARSE, ERR_REQUEST, ERR_METHOD, ERR_AUTH = -32700, -32600, -32601, -32504
ERR_AMOUNT, ERR_TX_NOT_FOUND, ERR_CANNOT_CANCEL, ERR_CANNOT_PERFORM = -31001, -31003, -31007, -31008
ERR_ORDER_NOT_FOUND, ERR_ORDER_BUSY = -31050, -31051

_MESSAGES: dict[int, tuple[str, str, str]] = {
    ERR_PARSE: ("Ошибка разбора запроса", "So'rovni o'qib bo'lmadi", "Parse error"),
    ERR_REQUEST: ("Неверный запрос", "Noto'g'ri so'rov", "Invalid request"),
    ERR_METHOD: ("Метод не найден", "Metod topilmadi", "Method not found"),
    ERR_AUTH: ("Недостаточно привилегий", "Ruxsat yo'q", "Insufficient privileges"),
    ERR_AMOUNT: ("Неверная сумма", "Noto'g'ri summa", "Wrong amount"),
    ERR_TX_NOT_FOUND: ("Транзакция не найдена", "Tranzaksiya topilmadi", "Transaction not found"),
    ERR_CANNOT_CANCEL: ("Невозможно отменить транзакцию", "Tranzaksiyani bekor qilib bo'lmaydi", "Cannot cancel"),
    ERR_CANNOT_PERFORM: ("Невозможно выполнить операцию", "Amalni bajarib bo'lmaydi", "Cannot perform"),
    ERR_ORDER_NOT_FOUND: ("Заказ не найден", "Buyurtma topilmadi", "Order not found"),
    ERR_ORDER_BUSY: ("Заказ уже оплачивается или оплачен", "Buyurtma to'lanmoqda yoki to'langan", "Order busy or paid"),
}


class PaymeError(Exception):
    def __init__(self, code: int, data: str | None = None) -> None:
        super().__init__(code)
        self.code = code
        self.data = data


def payme_configured() -> bool:
    settings = get_settings()
    return bool(settings.payme_merchant_id and settings.payme_key)


def _now_ms() -> int:
    return int(time.time() * 1000)


# ---- the app side: a new order and its checkout link ----


class PaymeOrderIn(BaseModel):
    amount_uzs: Annotated[int, Field(ge=MIN_TOPUP_UZS, le=MAX_TOPUP_UZS)]


def checkout_url(order: PaymeOrder, return_url: str | None = None) -> str:
    settings = get_settings()
    back = return_url or settings.payme_return_url
    params = f"m={settings.payme_merchant_id};ac.order_id={order.id};a={order.amount_uzs * 100};l=uz;c={back}"
    return f"{settings.payme_checkout_url.rstrip('/')}/{base64.b64encode(params.encode()).decode()}"


async def new_order(db: AsyncSession, customer_id: uuid.UUID, amount_uzs: int, channel: str) -> PaymeOrder:
    """A Payme order for this customer (committed); [channel] (app, bot, web) only goes to the audit log."""
    if not payme_configured():
        raise unavailable("PAYME_NOT_CONFIGURED")
    await rate_limit(f"payme:{customer_id}", limit=20, window_seconds=3600)
    order = PaymeOrder(id=uuid.uuid4(), customer_id=customer_id, amount_uzs=amount_uzs)
    db.add(order)
    audit(db, f"customer:{customer_id}", "payme_order", str(order.id), amount_uzs=amount_uzs, channel=channel)
    await db.commit()
    return order


@router.post("/wallet/payme", status_code=201)
async def create_order(body: PaymeOrderIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    order = await new_order(db, current.id, body.amount_uzs, "app")
    return {"order_id": str(order.id), "amount_uzs": order.amount_uzs, "checkout_url": checkout_url(order)}


# ---- the Payme side: JSON-RPC ----


def _authorized(request: Request) -> bool:
    header = request.headers.get("authorization", "")
    scheme, _, encoded = header.partition(" ")
    if scheme.lower() != "basic" or not payme_configured():
        return False
    try:
        login, _, password = base64.b64decode(encoded, validate=True).decode().partition(":")
    except (binascii.Error, UnicodeDecodeError):
        return False
    return login == "Paycom" and constant_time_equals(password, get_settings().payme_key)


def _error(request_id: Any, code: int, data: str | None = None) -> dict[str, Any]:
    ru, uz, en = _MESSAGES[code]
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": {"ru": ru, "uz": uz, "en": en}, "data": data}}


@router.post("/payments/payme", include_in_schema=False)
async def payme_rpc(request: Request, db: DbDep) -> dict[str, Any]:
    try:
        payload = await request.json()
    except ValueError:
        return _error(None, ERR_PARSE)
    request_id = payload.get("id") if isinstance(payload, dict) else None
    if not _authorized(request):
        return _error(request_id, ERR_AUTH)
    if not isinstance(payload, dict) or not isinstance(payload.get("params"), dict):
        return _error(request_id, ERR_REQUEST)
    handler = _METHODS.get(payload.get("method"))
    if handler is None:
        return _error(request_id, ERR_METHOD)
    try:
        result = await handler(db, payload["params"])
    except PaymeError as error:
        await db.rollback()
        return _error(request_id, error.code, error.data)
    except (KeyError, TypeError, ValueError) as error:
        await db.rollback()
        log.warning("payme bad params in %s: %s", payload.get("method"), error)
        return _error(request_id, ERR_REQUEST)
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


async def _order_for(db: DbDep, params: dict[str, Any]) -> PaymeOrder:
    """The order named in the account, locked, with the amount checked."""
    try:
        order_id = uuid.UUID(str((params.get("account") or {})["order_id"]))
    except (KeyError, ValueError, TypeError) as exc:
        raise PaymeError(ERR_ORDER_NOT_FOUND, "order_id") from exc
    order = await db.scalar(select(PaymeOrder).where(PaymeOrder.id == order_id).with_for_update())
    if order is None:
        raise PaymeError(ERR_ORDER_NOT_FOUND, "order_id")
    amount = params.get("amount")
    if not isinstance(amount, int) or isinstance(amount, bool) or amount != order.amount_uzs * 100:
        raise PaymeError(ERR_AMOUNT)
    return order


async def _transaction(db: DbDep, params: dict[str, Any]) -> PaymeOrder:
    order = await db.scalar(select(PaymeOrder).where(PaymeOrder.payme_id == str(params["id"])).with_for_update())
    if order is None:
        raise PaymeError(ERR_TX_NOT_FOUND)
    return order


def _expired(order: PaymeOrder) -> bool:
    return _now_ms() - order.create_time > TRANSACTION_TIMEOUT_MS


async def _cancel(db: DbDep, order: PaymeOrder, state: int, reason: int) -> None:
    order.state = state
    order.reason = reason
    order.cancel_time = _now_ms()
    await db.commit()


async def check_perform(db: DbDep, params: dict[str, Any]) -> dict[str, Any]:
    order = await _order_for(db, params)
    if order.state != STATE_NEW:
        raise PaymeError(ERR_ORDER_BUSY, "order_id")
    return {"allow": True}


async def create_transaction(db: DbDep, params: dict[str, Any]) -> dict[str, Any]:
    payme_id = str(params["id"])
    existing = await db.scalar(select(PaymeOrder).where(PaymeOrder.payme_id == payme_id).with_for_update())
    if existing is not None:
        if existing.state != STATE_CREATED:
            raise PaymeError(ERR_CANNOT_PERFORM)
        if _expired(existing):
            await _cancel(db, existing, STATE_CANCELLED, REASON_TIMEOUT)
            raise PaymeError(ERR_CANNOT_PERFORM)
        return {"create_time": existing.create_time, "transaction": str(existing.id), "state": existing.state}
    order = await _order_for(db, params)
    # One transaction per order: another one created, paid or cancelled keeps this order closed.
    if order.state != STATE_NEW:
        raise PaymeError(ERR_ORDER_BUSY, "order_id")
    order.payme_id = payme_id
    order.payme_time = int(params["time"])
    order.state = STATE_CREATED
    order.create_time = _now_ms()
    await db.commit()
    return {"create_time": order.create_time, "transaction": str(order.id), "state": order.state}


async def perform_transaction(db: DbDep, params: dict[str, Any]) -> dict[str, Any]:
    order = await _transaction(db, params)
    if order.state == STATE_CREATED:
        if _expired(order):
            await _cancel(db, order, STATE_CANCELLED, REASON_TIMEOUT)
            raise PaymeError(ERR_CANNOT_PERFORM)
        order.state = STATE_PERFORMED
        order.perform_time = _now_ms()
        await wallet.record_topup(db, order.customer_id, order.amount_uzs, f"payme:{order.id}")
        audit(db, "payme", "payme_performed", str(order.id), amount_uzs=order.amount_uzs)
        await db.commit()
        # Payme waits for this answer, so the pay bot's "money arrived" message goes out in the background.
        await pay_notify.credited_later(db, order.customer_id, order.amount_uzs, "Payme")
    elif order.state != STATE_PERFORMED:
        raise PaymeError(ERR_CANNOT_PERFORM)
    return {"transaction": str(order.id), "perform_time": order.perform_time, "state": order.state}


async def cancel_transaction(db: DbDep, params: dict[str, Any]) -> dict[str, Any]:
    order = await _transaction(db, params)
    reason = int(params["reason"])
    if order.state == STATE_CREATED:
        await _cancel(db, order, STATE_CANCELLED, reason)
    elif order.state == STATE_PERFORMED:
        # A refund takes the money (and the top-up bonus it gave) back off the balance; once spent, the payment stays.
        bonus = await wallet.topup_bonus(db, order.customer_id, f"payme:{order.id}")
        if await wallet.balance(db, order.customer_id) < order.amount_uzs + bonus:
            raise PaymeError(ERR_CANNOT_CANCEL)
        await wallet.record(db, order.customer_id, -order.amount_uzs, "refund", f"payme:{order.id}")
        if bonus:
            await wallet.record(db, order.customer_id, -bonus, "refund", f"bonus:payme:{order.id}")
        audit(db, "payme", "payme_refunded", str(order.id), amount_uzs=order.amount_uzs)
        await _cancel(db, order, STATE_CANCELLED_AFTER_PERFORM, reason)
    return {"transaction": str(order.id), "cancel_time": order.cancel_time, "state": order.state}


def _details(order: PaymeOrder) -> dict[str, Any]:
    return {
        "create_time": order.create_time,
        "perform_time": order.perform_time,
        "cancel_time": order.cancel_time,
        "transaction": str(order.id),
        "state": order.state,
        "reason": order.reason,
    }


async def check_transaction(db: DbDep, params: dict[str, Any]) -> dict[str, Any]:
    return _details(await _transaction(db, params))


async def get_statement(db: DbDep, params: dict[str, Any]) -> dict[str, Any]:
    start, end = int(params["from"]), int(params["to"])
    rows = await db.scalars(
        select(PaymeOrder)
        .where(PaymeOrder.payme_time.is_not(None), PaymeOrder.payme_time >= start, PaymeOrder.payme_time <= end)
        .order_by(PaymeOrder.payme_time)
    )
    return {
        "transactions": [
            {
                "id": order.payme_id,
                "time": order.payme_time,
                "amount": order.amount_uzs * 100,
                "account": {"order_id": str(order.id)},
                **_details(order),
            }
            for order in rows
        ]
    }


_METHODS = {
    "CheckPerformTransaction": check_perform,
    "CreateTransaction": create_transaction,
    "PerformTransaction": perform_transaction,
    "CancelTransaction": cancel_transaction,
    "CheckTransaction": check_transaction,
    "GetStatement": get_statement,
}
