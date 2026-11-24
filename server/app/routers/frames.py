"""Animated avatar frames: bought once from the UZARO balance, worn around the avatar for UZARO users to see.

Like the badge, a frame belongs to the Telegram account the customer proved through the gifts bot, so nobody can
dress someone else's avatar. One frame is worn at a time; switching between owned frames, or taking it off, is free.
"""

import uuid
from typing import Annotated, Any

from fastapi import APIRouter, Query
from pydantic import BaseModel, StringConstraints
from sqlalchemy import select, update

from app.deps import CustomerDep, DbDep, rate_limit
from app.errors import conflict, forbidden, not_found
from app.models import FrameItem, OwnedFrame, TelegramLink
from app.routers.gifts import TelegramId, _link
from app.services import wallet
from app.services.audit import audit

router = APIRouter(prefix="/v1/frames", tags=["frames"])

MAX_LOOKUP = 100
FrameKey = Annotated[str, StringConstraints(pattern=r"^[a-z][a-z0-9_]{1,31}$")]


def frame_out(frame: FrameItem) -> dict[str, Any]:
    return {
        "key": frame.key,
        "title": frame.title,
        "title_ru": frame.title_ru or frame.title,
        "title_en": frame.title_en or frame.title,
        "tier": frame.tier,
        "price_uzs": frame.price_uzs,
        "animation_url": f"/media/{frame.animation}",
        "small_url": f"/media/{frame.small}",
    }


async def _owned(db: DbDep, telegram_user_id: int) -> list[OwnedFrame]:
    return list(await db.scalars(select(OwnedFrame).where(OwnedFrame.telegram_user_id == telegram_user_id)))


async def _mine(db: DbDep, customer_id: uuid.UUID, link: TelegramLink | None) -> dict[str, Any]:
    owned = await _owned(db, link.telegram_user_id) if link else []
    return {
        "linked": link is not None,
        "owned": sorted(o.frame_key for o in owned),
        "equipped": next((o.frame_key for o in owned if o.equipped), None),
        "balance_uzs": await wallet.balance(db, customer_id),
    }


@router.get("/catalog")
async def catalog(current: CustomerDep, db: DbDep) -> dict[str, Any]:
    """Every frame on sale (keys of retired ones still resolve through /of), plus what this customer owns and wears."""
    rows = await db.scalars(select(FrameItem).order_by(FrameItem.sort, FrameItem.key))
    link = await db.scalar(select(TelegramLink).where(TelegramLink.customer_id == current.id))
    return {"items": [frame_out(f) | {"active": f.active} for f in rows], **await _mine(db, current.id, link)}


class BuyIn(BaseModel):
    key: FrameKey


@router.post("/buy")
async def buy(body: BuyIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    """Buys a frame for good and puts it on."""
    await rate_limit(f"framebuy:{current.id}", limit=20, window_seconds=3600)
    link = await _link(db, current.id, lock=True)  # serialises this customer's spending
    frame = await db.get(FrameItem, body.key)
    if frame is None or not frame.active:
        raise not_found("FRAME_NOT_FOUND")
    if await db.get(OwnedFrame, (link.telegram_user_id, frame.key)) is not None:
        raise conflict("FRAME_OWNED")
    if await wallet.balance(db, current.id) < frame.price_uzs:
        raise conflict("INSUFFICIENT_BALANCE")
    await db.execute(update(OwnedFrame).where(OwnedFrame.telegram_user_id == link.telegram_user_id).values(equipped=False))
    db.add(OwnedFrame(telegram_user_id=link.telegram_user_id, frame_key=frame.key, equipped=True, price_uzs=frame.price_uzs))
    reference = f"{frame.key}:{uuid.uuid4()}"
    await wallet.record(db, current.id, -frame.price_uzs, "frame", reference)
    audit(db, f"customer:{current.id}", "frame_bought", reference, price_uzs=frame.price_uzs)
    await db.commit()
    return await _mine(db, current.id, link)


class WearIn(BaseModel):
    key: FrameKey | None = None  # None takes the frame off


@router.put("/me")
async def wear(body: WearIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    """Puts on one of the customer's frames, or takes the worn one off."""
    await rate_limit(f"frameset:{current.id}", limit=60, window_seconds=3600)
    link = await _link(db, current.id, lock=True)
    owned = {o.frame_key: o for o in await _owned(db, link.telegram_user_id)}
    if body.key is not None and body.key not in owned:
        raise forbidden("FRAME_NOT_OWNED")
    for key, row in owned.items():
        row.equipped = key == body.key
    await db.commit()
    return await _mine(db, current.id, link)


@router.get("/of")
async def frames_of(
    current: CustomerDep, db: DbDep, ids: Annotated[list[TelegramId], Query(min_length=1, max_length=MAX_LOOKUP)]
) -> dict[str, Any]:
    """Worn frames of the given Telegram users (the app asks for everyone on screen at once): {id: frame key}."""
    rows = await db.execute(
        select(OwnedFrame.telegram_user_id, OwnedFrame.frame_key).where(
            OwnedFrame.telegram_user_id.in_(set(ids)), OwnedFrame.equipped.is_(True)
        )
    )
    return {"frames": {str(user_id): key for user_id, key in rows}}
