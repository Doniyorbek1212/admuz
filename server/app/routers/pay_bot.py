"""The pay bot's webhook and the website's wallet page (uzaromessenger.uz/hamyon.html).

Website sign-in goes through the bot, so nobody types a phone number or a name: the page asks for a one-time code
(POST /v1/web/login), the person opens t.me/<pay bot>?start=web_<code> and presses Start, the bot confirms the code
for the UZARO account linked to that Telegram account, and the page (polling GET /v1/web/login/<code>) receives a
30-minute session. With it the page shows the balance and opens a Payme checkout for one of the packs.
"""

import json
import secrets
import uuid
from typing import Annotated, Any

from fastapi import APIRouter, Header, Request
from pydantic import BaseModel

from app.config import get_settings
from app.deps import DbDep, client_ip, get_redis, rate_limit
from app.errors import bad_request, not_found, unauthorized, unavailable
from app.routers import payme
from app.security import constant_time_equals
from app.services import pay_bot, telegram_api, wallet
from app.services.pay_notify import som

router = APIRouter(prefix="/v1", tags=["pay-bot"])

LOGIN_TTL_SECONDS = 10 * 60
SESSION_TTL_SECONDS = 30 * 60
WEB_RETURN_URL = "https://uzaromessenger.uz/hamyon.html"


@router.post("/telegram/pay-webhook", include_in_schema=False)
async def pay_webhook(
    request: Request,
    db: DbDep,
    x_telegram_bot_api_secret_token: Annotated[str | None, Header()] = None,
) -> dict[str, bool]:
    if not telegram_api.configured() or not constant_time_equals(x_telegram_bot_api_secret_token or "", pay_bot.webhook_secret()):
        raise unauthorized("WEBHOOK_SECRET_INVALID")
    try:
        update = await request.json()
    except ValueError:
        return {"ok": True}
    if isinstance(update, dict):
        await pay_bot.handle(db, update)
    return {"ok": True}


# ---- website wallet ----


def _require_bot() -> None:
    if not telegram_api.configured():
        raise unavailable("PAY_BOT_NOT_CONFIGURED")


@router.post("/web/login")
async def web_login(request: Request) -> dict[str, Any]:
    _require_bot()
    await rate_limit(f"weblogin:{client_ip(request)}", limit=20, window_seconds=3600)
    code = secrets.token_urlsafe(18)
    await get_redis().set(f"weblogin:{code}", "", ex=LOGIN_TTL_SECONDS)
    username = get_settings().pay_bot_username
    return {"code": code, "bot_url": f"https://t.me/{username}?start={pay_bot.WEB_PREFIX}{code}", "expires_in": LOGIN_TTL_SECONDS}


@router.get("/web/login/{code}")
async def web_login_status(code: str, request: Request) -> dict[str, Any]:
    await rate_limit(f"weblogin-poll:{client_ip(request)}", limit=600, window_seconds=3600)
    redis = get_redis()
    value = await redis.get(f"weblogin:{code[:64]}")
    if value is None:
        raise not_found("LOGIN_EXPIRED")
    if value == "":
        return {"status": "pending"}
    # Confirmed in the bot: the code is spent (atomically, so two polls never both get a session) and becomes a session.
    value = await redis.getdel(f"weblogin:{code[:64]}")
    if not value:
        raise not_found("LOGIN_EXPIRED")
    token = secrets.token_urlsafe(32)
    await redis.set(f"websess:{token}", value, ex=SESSION_TTL_SECONDS)
    return {"status": "ok", "token": token, "expires_in": SESSION_TTL_SECONDS}


async def _session(token: str | None) -> dict[str, str]:
    raw = await get_redis().get(f"websess:{(token or '')[:64]}") if token else None
    if raw is None:
        raise unauthorized("WEB_SESSION_EXPIRED")
    return json.loads(raw)


@router.get("/web/wallet")
async def web_wallet(db: DbDep, x_wallet_session: Annotated[str | None, Header()] = None) -> dict[str, Any]:
    session = await _session(x_wallet_session)
    customer = uuid.UUID(session["c"])
    balance = await wallet.balance(db, customer)
    return {
        "name": session.get("name", ""),
        "balance_uzs": balance,
        "balance_text": som(balance),
        "packs": [{"amount_uzs": a, "text": som(a)} for a in wallet.TOPUP_PACKS_UZS],
        "payme": payme.payme_configured(),
    }


class WebPaymeIn(BaseModel):
    amount_uzs: int


@router.post("/web/payme", status_code=201)
async def web_payme(body: WebPaymeIn, db: DbDep, x_wallet_session: Annotated[str | None, Header()] = None) -> dict[str, Any]:
    session = await _session(x_wallet_session)
    if body.amount_uzs not in wallet.TOPUP_PACKS_UZS:
        raise bad_request("AMOUNT_NOT_A_PACK")
    order = await payme.new_order(db, uuid.UUID(session["c"]), body.amount_uzs, "web")
    return {"checkout_url": payme.checkout_url(order, WEB_RETURN_URL)}


@router.post("/web/logout", status_code=204)
async def web_logout(x_wallet_session: Annotated[str | None, Header()] = None) -> None:
    if x_wallet_session:
        await get_redis().delete(f"websess:{x_wallet_session[:64]}")
