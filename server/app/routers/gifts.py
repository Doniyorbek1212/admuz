"""UZARO gifts: animated gifts bought from the UZARO balance and sent to Telegram users.

Only UZARO users see them (on the recipient's profile). A sender must first prove their Telegram id: the app
asks for a one-time code and sends "/start <code>" to the gifts bot through the user's own Telegram account;
Telegram then delivers that message to POST /v1/telegram/webhook with the real sender id.
The balance is topped up by card transfer: the customer uploads the receipt, an admin approves it.
"""

import logging
import secrets
import uuid
from typing import Annotated, Any

from fastapi import APIRouter, File, Form, Header, Query, Request, UploadFile, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, StringConstraints
from sqlalchemy import delete, func, select

from app.config import get_settings
from app.deps import CustomerDep, DbDep, get_redis, rate_limit
from app.errors import bad_request, conflict, forbidden, not_found, unauthorized, unavailable
from app.models import GiftItem, ProfileStyle, SentGift, TelegramLink, TopupStatus, WalletTopup
from app.security import constant_time_equals, sha256_hex
from app.services import username_bot, wallet
from app.services.audit import audit
from app.services.market_settings import load_market_settings
from app.uploads import save_receipt

router = APIRouter(prefix="/v1", tags=["gifts"])
log = logging.getLogger("app.gifts")

LINK_CODE_TTL_SECONDS = 600
MAX_PENDING_TOPUPS = 3
TelegramId = Annotated[int, Field(gt=0, lt=1 << 53)]


def webhook_secret() -> str:
    """The secret_token given to setWebhook; Telegram echoes it in X-Telegram-Bot-Api-Secret-Token."""
    return sha256_hex(f"uzaro-gifts-webhook:{get_settings().gifts_bot_token}")


def gift_out(gift: GiftItem) -> dict[str, Any]:
    return {
        "id": str(gift.id),
        "title": gift.title,
        "price_uzs": gift.price_uzs,
        "animation_url": f"/media/{gift.animation}",
        "video_url": f"/media/{gift.video}" if gift.video else None,
        "effect": gift.effect or None,
        "show_url": f"/media/{gift.show}" if gift.show else None,
        "sound_url": f"/media/{gift.sound}" if gift.sound else None,
        "duration_ms": gift.duration_ms or None,
        "tier": gift.tier or None,
        "titles": {"uz": gift.title, "ru": gift.title_ru or gift.title, "en": gift.title_en or gift.title},
    }


def sent_out(sent: SentGift, gift: GiftItem) -> dict[str, Any]:
    return {
        "id": str(sent.id),
        "gift": gift_out(gift),
        "sender_telegram_id": sent.sender_telegram_id,
        "recipient_telegram_id": sent.recipient_telegram_id,
        "text": sent.text,
        "hidden": sent.hidden,
        "created_at": sent.created_at.isoformat(),
    }


def topup_out(topup: WalletTopup) -> dict[str, Any]:
    return {
        "id": str(topup.id),
        "amount_uzs": topup.amount_uzs,
        "status": topup.status,
        "reject_reason": topup.reject_reason,
        "created_at": topup.created_at.isoformat(),
    }


async def _link(db: DbDep, customer_id: uuid.UUID, *, lock: bool = False) -> TelegramLink:
    stmt = select(TelegramLink).where(TelegramLink.customer_id == customer_id)
    link = await db.scalar(stmt.with_for_update() if lock else stmt)
    if link is None:
        raise forbidden("TELEGRAM_NOT_LINKED")
    return link


# ---- Telegram id proof ----


@router.post("/telegram/link")
async def start_link(current: CustomerDep) -> dict[str, Any]:
    settings = get_settings()
    if not (settings.gifts_bot_token and settings.gifts_bot_username):
        raise unavailable("GIFTS_BOT_NOT_CONFIGURED")
    await rate_limit(f"tglink:{current.id}", limit=10, window_seconds=3600)
    code = secrets.token_urlsafe(16)
    await get_redis().set(f"tglink:{code}", str(current.id), ex=LINK_CODE_TTL_SECONDS)
    return {"code": code, "bot_username": settings.gifts_bot_username, "expires_in": LINK_CODE_TTL_SECONDS}


@router.get("/telegram/me")
async def telegram_me(current: CustomerDep, db: DbDep) -> dict[str, Any]:
    link = await db.get(TelegramLink, current.id)
    return {"telegram_user_id": link.telegram_user_id if link else None}


def _reply(chat_id: int, text: str) -> JSONResponse:
    # Answering the webhook with a method call sends the message without an outgoing request.
    return JSONResponse({"method": "sendMessage", "chat_id": chat_id, "text": text})


@router.post("/telegram/webhook", include_in_schema=False)
async def telegram_webhook(
    request: Request,
    db: DbDep,
    x_telegram_bot_api_secret_token: Annotated[str | None, Header()] = None,
) -> Any:
    if not get_settings().gifts_bot_token or not constant_time_equals(x_telegram_bot_api_secret_token or "", webhook_secret()):
        raise unauthorized("WEBHOOK_SECRET_INVALID")
    try:
        update = await request.json()
    except ValueError:
        return {"ok": True}
    message = update.get("message") if isinstance(update, dict) else None
    if not isinstance(message, dict):
        return {"ok": True}
    sender = message.get("from") or {}
    chat = message.get("chat") or {}
    text = message.get("text") or ""
    user_id = sender.get("id")
    if not isinstance(user_id, int) or sender.get("is_bot") or chat.get("type") != "private":
        return {"ok": True}
    if (command := username_bot.command_name(text)) is not None:
        return _reply(chat["id"], await username_bot.answer(db, user_id, *command))
    parts = text.split(maxsplit=1)
    if not parts or parts[0] != "/start":
        return _reply(chat["id"], "UZARO sovg'alari faqat UZARO ilovasida ishlaydi: https://uzaromessenger.uz")
    customer_id = await get_redis().getdel(f"tglink:{parts[1].strip()}") if len(parts) == 2 else None
    if customer_id is None:
        return _reply(chat["id"], "Assalomu alaykum! Bu UZARO boti. Sovg'alar UZARO ilovasida: https://uzaromessenger.uz")
    customer = uuid.UUID(customer_id)
    # The newest proof wins: this Telegram account moves to this customer, this customer to this account.
    await db.execute(delete(TelegramLink).where((TelegramLink.telegram_user_id == user_id) | (TelegramLink.customer_id == customer)))
    db.add(TelegramLink(customer_id=customer, telegram_user_id=user_id))
    audit(db, f"customer:{customer}", "telegram_linked", str(customer))
    await db.commit()
    return _reply(chat["id"], "✅ UZARO hisobingiz tasdiqlandi. Ilovaga qayting — endi sovg'a yubora olasiz.")


# ---- catalog, sending, profiles ----


@router.get("/gifts/catalog")
async def catalog(current: CustomerDep, db: DbDep) -> dict[str, Any]:
    rows = await db.scalars(select(GiftItem).where(GiftItem.active.is_(True)).order_by(GiftItem.sort, GiftItem.price_uzs, GiftItem.id))
    return {"items": [gift_out(g) for g in rows]}


class SendIn(BaseModel):
    gift_id: uuid.UUID
    recipient_telegram_id: TelegramId
    text: Annotated[str, StringConstraints(strip_whitespace=True, max_length=140)] = ""


@router.post("/gifts/send", status_code=status.HTTP_201_CREATED)
async def send_gift(body: SendIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    await rate_limit(f"giftsend:{current.id}", limit=30, window_seconds=3600)
    link = await _link(db, current.id, lock=True)  # serialises this customer's spending
    gift = await db.get(GiftItem, body.gift_id)
    if gift is None or not gift.active:
        raise not_found("GIFT_NOT_FOUND")
    if await wallet.balance(db, current.id) < gift.price_uzs:
        raise conflict("INSUFFICIENT_BALANCE")
    sent = SentGift(
        id=uuid.uuid4(), gift_id=gift.id, sender_customer_id=current.id, sender_telegram_id=link.telegram_user_id,
        recipient_telegram_id=body.recipient_telegram_id, text=body.text, price_uzs=gift.price_uzs,
    )
    db.add(sent)
    await wallet.record(db, current.id, -gift.price_uzs, "gift", str(sent.id))
    audit(db, f"customer:{current.id}", "gift_sent", str(sent.id), price_uzs=gift.price_uzs)
    await db.commit()
    await db.refresh(sent)
    return {"gift": sent_out(sent, gift), "balance_uzs": await wallet.balance(db, current.id)}


async def _gifts_of(db: DbDep, telegram_user_id: int, *, include_hidden: bool, limit: int) -> list[dict[str, Any]]:
    stmt = select(SentGift, GiftItem).join(GiftItem, GiftItem.id == SentGift.gift_id).where(
        SentGift.recipient_telegram_id == telegram_user_id
    )
    if include_hidden:
        stmt = stmt.order_by(SentGift.created_at.desc(), SentGift.id)
    else:
        # On a profile the dearest gifts lead: they get the bubbles and the dearest premium one plays.
        stmt = stmt.where(SentGift.hidden.is_(False)).order_by(
            GiftItem.price_uzs.desc(), SentGift.created_at.desc(), SentGift.id
        )
    rows = await db.execute(stmt.limit(limit))
    return [sent_out(s, g) for s, g in rows.all()]


@router.get("/gifts/users/{telegram_user_id}")
async def user_gifts(
    telegram_user_id: int, current: CustomerDep, db: DbDep, limit: Annotated[int, Query(ge=1, le=100)] = 50
) -> dict[str, Any]:
    """What a UZARO user sees on someone's profile: the gifts they show (dearest first) and their background."""
    style = await db.get(ProfileStyle, telegram_user_id)
    background = (style.background or None) if style else None
    if style is not None and style.hide_gifts:
        return {"items": [], "total": 0, "background": background}
    total = await db.scalar(
        select(func.count()).select_from(SentGift).where(
            SentGift.recipient_telegram_id == telegram_user_id, SentGift.hidden.is_(False)
        )
    ) or 0
    return {
        "items": await _gifts_of(db, telegram_user_id, include_hidden=False, limit=limit),
        "total": total,
        "background": background,
    }


class BackgroundIn(BaseModel):
    # One color or a two-color gradient; null clears it.
    background: Annotated[str, StringConstraints(pattern=r"^#[0-9a-f]{6}(,#[0-9a-f]{6})?$")] | None = None


@router.put("/profile/background")
async def set_background(body: BackgroundIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    """Sets the profile background UZARO users see; only for the Telegram account this customer proved."""
    await rate_limit(f"profilebg:{current.id}", limit=60, window_seconds=3600)
    link = await _link(db, current.id)
    style = await db.get(ProfileStyle, link.telegram_user_id)
    # No background and gifts shown is the default, kept as no row.
    if style is None:
        if body.background is not None:
            db.add(ProfileStyle(telegram_user_id=link.telegram_user_id, background=body.background))
    elif body.background is None and not style.hide_gifts:
        await db.delete(style)
    else:
        style.background = body.background or ""
    await db.commit()
    return {"background": body.background}


@router.get("/gifts/received")
async def received(current: CustomerDep, db: DbDep) -> dict[str, Any]:
    link = await _link(db, current.id)
    style = await db.get(ProfileStyle, link.telegram_user_id)
    return {
        "items": await _gifts_of(db, link.telegram_user_id, include_hidden=True, limit=200),
        "hide_all": bool(style and style.hide_gifts),
    }


class VisibilityIn(BaseModel):
    hidden: bool


@router.post("/gifts/{sent_id}/visibility")
async def set_visibility(sent_id: uuid.UUID, body: VisibilityIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    link = await _link(db, current.id)
    sent = await db.get(SentGift, sent_id)
    if sent is None or sent.recipient_telegram_id != link.telegram_user_id:
        raise not_found("GIFT_NOT_FOUND")
    sent.hidden = body.hidden
    await db.commit()
    return {"id": str(sent.id), "hidden": sent.hidden}


@router.put("/profile/gifts-visibility")
async def set_all_gifts_hidden(body: VisibilityIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    """The profile switch: hide every received gift (now and later) from people opening the profile, or show them."""
    await rate_limit(f"giftsvis:{current.id}", limit=60, window_seconds=3600)
    link = await _link(db, current.id)
    style = await db.get(ProfileStyle, link.telegram_user_id)
    if style is None:
        if body.hidden:
            db.add(ProfileStyle(telegram_user_id=link.telegram_user_id, background="", hide_gifts=True))
    elif not body.hidden and not style.background:
        await db.delete(style)
    else:
        style.hide_gifts = body.hidden
    await db.commit()
    return {"hide_all": body.hidden}


# ---- balance ----


@router.get("/wallet")
async def get_wallet(current: CustomerDep, db: DbDep) -> dict[str, Any]:
    settings = await load_market_settings(db)
    topups = await db.scalars(
        select(WalletTopup).where(WalletTopup.customer_id == current.id).order_by(WalletTopup.created_at.desc()).limit(10)
    )
    return {
        "balance_uzs": await wallet.balance(db, current.id),
        "card": settings.ad_payment_card,
        "card_holder": settings.ad_payment_card_holder,
        "topups": [topup_out(t) for t in topups],
    }


@router.post("/wallet/topups", status_code=status.HTTP_201_CREATED)
async def create_topup(
    current: CustomerDep,
    db: DbDep,
    amount_uzs: Annotated[int, Form(ge=1_000, le=50_000_000)],
    receipt: Annotated[UploadFile, File()],
) -> dict[str, Any]:
    await rate_limit(f"topup:{current.id}", limit=10, window_seconds=3600)
    pending = await db.scalar(
        select(func.count()).select_from(WalletTopup).where(
            WalletTopup.customer_id == current.id, WalletTopup.status == TopupStatus.PENDING.value
        )
    ) or 0
    if pending >= MAX_PENDING_TOPUPS:
        raise bad_request("TOO_MANY_PENDING_TOPUPS")
    topup = WalletTopup(customer_id=current.id, amount_uzs=amount_uzs, receipt_path=await save_receipt(receipt))
    db.add(topup)
    audit(db, f"customer:{current.id}", "topup_requested", str(current.id), amount_uzs=amount_uzs)
    await db.commit()
    await db.refresh(topup)
    return topup_out(topup)
