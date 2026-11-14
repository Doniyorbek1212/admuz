"""UZARO badges: a gold checkmark or any Telegram custom emoji next to a person's name, seen by UZARO users.

Bought by the month from the UZARO balance (price in the admin settings); buying again adds another month on top
of what is left. The emoji can be changed free while the badge is active. Only the Telegram account the customer
proved through the gifts bot gets the badge, so nobody can dress someone else's name.
"""

import uuid
from datetime import UTC, datetime, timedelta
from typing import Annotated, Any

from fastapi import APIRouter, Query
from pydantic import BaseModel, Field
from sqlalchemy import select

from app.deps import CustomerDep, DbDep, rate_limit
from app.errors import conflict
from app.models import ProfileBadge
from app.routers.gifts import TelegramId, _link
from app.services import wallet
from app.services.audit import audit
from app.services.market_settings import load_market_settings

router = APIRouter(prefix="/v1/badges", tags=["badges"])

PERIOD = timedelta(days=30)
MAX_LOOKUP = 100
EmojiId = Annotated[int, Field(ge=0, lt=1 << 63)]  # 0 = the UZARO checkmark


def _badge_out(badge: ProfileBadge | None, now: datetime) -> dict[str, Any] | None:
    if badge is None or badge.expires_at <= now:
        return None
    return {"emoji_id": str(badge.emoji_id), "expires_at": badge.expires_at.isoformat()}


class BadgeIn(BaseModel):
    emoji_id: EmojiId = 0


@router.get("/me")
async def my_badge(current: CustomerDep, db: DbDep) -> dict[str, Any]:
    settings = await load_market_settings(db)
    link = await _link(db, current.id)
    return {
        "price_uzs": settings.badge_price_uzs,
        "days": PERIOD.days,
        "badge": _badge_out(await db.get(ProfileBadge, link.telegram_user_id), datetime.now(UTC)),
        "balance_uzs": await wallet.balance(db, current.id),
    }


@router.post("/buy")
async def buy(body: BadgeIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    """One more month of the badge: starts now, or extends the one still running."""
    await rate_limit(f"badgebuy:{current.id}", limit=20, window_seconds=3600)
    settings = await load_market_settings(db)
    if settings.badge_price_uzs <= 0:
        raise conflict("BADGE_NOT_FOR_SALE")
    link = await _link(db, current.id, lock=True)  # serialises this customer's spending
    if await wallet.balance(db, current.id) < settings.badge_price_uzs:
        raise conflict("INSUFFICIENT_BALANCE")
    now = datetime.now(UTC)
    badge = await db.get(ProfileBadge, link.telegram_user_id, with_for_update=True)
    if badge is None:
        badge = ProfileBadge(telegram_user_id=link.telegram_user_id, emoji_id=body.emoji_id, expires_at=now + PERIOD)
        db.add(badge)
    else:
        badge.expires_at = max(badge.expires_at, now) + PERIOD
        badge.emoji_id = body.emoji_id
    reference = str(uuid.uuid4())
    await wallet.record(db, current.id, -settings.badge_price_uzs, "badge", reference)
    audit(db, f"customer:{current.id}", "badge_bought", reference, price_uzs=settings.badge_price_uzs)
    await db.commit()
    return {"badge": _badge_out(badge, now), "balance_uzs": await wallet.balance(db, current.id)}


@router.put("/me")
async def change(body: BadgeIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    """Swaps the emoji of a running badge; free until it expires."""
    await rate_limit(f"badgeset:{current.id}", limit=60, window_seconds=3600)
    link = await _link(db, current.id)
    now = datetime.now(UTC)
    badge = await db.get(ProfileBadge, link.telegram_user_id)
    if _badge_out(badge, now) is None:
        raise conflict("BADGE_NOT_ACTIVE")
    badge.emoji_id = body.emoji_id
    await db.commit()
    return {"badge": _badge_out(badge, now)}


@router.get("/of")
async def badges_of(
    current: CustomerDep, db: DbDep, ids: Annotated[list[TelegramId], Query(min_length=1, max_length=MAX_LOOKUP)]
) -> dict[str, Any]:
    """Active badges of the given Telegram users (the app asks for everyone on screen at once): {id: emoji_id}."""
    rows = await db.scalars(
        select(ProfileBadge).where(ProfileBadge.telegram_user_id.in_(set(ids)), ProfileBadge.expires_at > datetime.now(UTC))
    )
    return {"badges": {str(b.telegram_user_id): str(b.emoji_id) for b in rows}}
