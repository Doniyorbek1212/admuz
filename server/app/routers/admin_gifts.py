"""Admin side of UZARO gifts: the catalog (upload animated WebP/GIF, price, order, hide) and balance top-ups
(check the card-transfer receipt, then approve to credit the balance or reject with a reason)."""

import uuid
from datetime import UTC, datetime
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, File, Form, UploadFile, status
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field, StringConstraints, model_validator
from sqlalchemy import func, select

from app.deps import DbDep, require_admin
from app.errors import bad_request, conflict, not_found
from app.models import AdminRole, AdminUser, Customer, GiftItem, SentGift, TelegramLink, TopupStatus, WalletTopup
from app.routers.admin_market import ReasonIn
from app.routers.gifts import gift_out, topup_out
from app.services import wallet
from app.services.audit import audit
from app.uploads import private_file, save_gift_animation, save_gift_video

router = APIRouter(prefix="/v1/admin/gifts", tags=["admin"])

Viewer = Annotated[AdminUser, Depends(require_admin(AdminRole.VIEWER))]
Support = Annotated[AdminUser, Depends(require_admin(AdminRole.SUPPORT))]
Finance = Annotated[AdminUser, Depends(require_admin(AdminRole.FINANCE))]
Title = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=64)]
Price = Annotated[int, Field(ge=0, le=10_000_000)]


async def _gift(db: DbDep, gift_id: uuid.UUID) -> GiftItem:
    gift = await db.get(GiftItem, gift_id)
    if gift is None:
        raise not_found("GIFT_NOT_FOUND")
    return gift


@router.get("")
async def list_gifts(admin: Viewer, db: DbDep) -> dict[str, Any]:
    sold = dict((await db.execute(select(SentGift.gift_id, func.count()).group_by(SentGift.gift_id))).all())
    rows = await db.scalars(select(GiftItem).order_by(GiftItem.sort, GiftItem.price_uzs, GiftItem.id))
    return {"items": [gift_out(g) | {"active": g.active, "sort": g.sort, "sent": sold.get(g.id, 0)} for g in rows]}


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_gift(
    admin: Support,
    db: DbDep,
    file: Annotated[UploadFile, File()],
    title: Annotated[str, Form(min_length=1, max_length=64)],
    price_uzs: Annotated[int, Form(ge=0, le=10_000_000)],
    sort: Annotated[int, Form(ge=0, le=10_000)] = 0,
    video: Annotated[UploadFile | None, File()] = None,
) -> dict[str, Any]:
    if not title.strip():
        raise bad_request("TITLE_REQUIRED")
    gift = GiftItem(
        title=title.strip(),
        price_uzs=price_uzs,
        sort=sort,
        animation=await save_gift_animation(file),
        video=await save_gift_video(video) if video is not None else "",
    )
    db.add(gift)
    await db.flush()
    audit(db, f"admin:{admin.name}", "gift_created", str(gift.id), price_uzs=price_uzs)
    await db.commit()
    return gift_out(gift)


class GiftIn(BaseModel):
    title: Title
    price_uzs: Price
    sort: Annotated[int, Field(ge=0, le=10_000)] = 0
    active: bool = True


@router.put("/{gift_id}")
async def update_gift(gift_id: uuid.UUID, body: GiftIn, admin: Support, db: DbDep) -> dict[str, Any]:
    gift = await _gift(db, gift_id)
    gift.title, gift.price_uzs, gift.sort, gift.active = body.title, body.price_uzs, body.sort, body.active
    audit(db, f"admin:{admin.name}", "gift_updated", str(gift.id), price_uzs=body.price_uzs, active=body.active)
    await db.commit()
    return gift_out(gift)


@router.delete("/{gift_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_gift(gift_id: uuid.UUID, admin: Support, db: DbDep) -> None:
    """Only a gift nobody has received yet; a sent one stays on profiles, so it can only be hidden from the shop."""
    gift = await _gift(db, gift_id)
    if await db.scalar(select(SentGift.id).where(SentGift.gift_id == gift.id).limit(1)) is not None:
        raise conflict("GIFT_IN_USE")
    await db.delete(gift)
    audit(db, f"admin:{admin.name}", "gift_deleted", str(gift_id))
    await db.commit()


# ---- top-ups ----


async def _topup(db: DbDep, topup_id: uuid.UUID, *, lock: bool = False) -> WalletTopup:
    stmt = select(WalletTopup).where(WalletTopup.id == topup_id)
    topup = await db.scalar(stmt.with_for_update() if lock else stmt)
    if topup is None:
        raise not_found("TOPUP_NOT_FOUND")
    return topup


@router.get("/topups")
async def list_topups(admin: Viewer, db: DbDep, state: Literal["pending", "approved", "rejected"] = "pending") -> dict[str, Any]:
    rows = await db.execute(
        select(WalletTopup, TelegramLink.telegram_user_id)
        .outerjoin(TelegramLink, TelegramLink.customer_id == WalletTopup.customer_id)
        .where(WalletTopup.status == state)
        .order_by(WalletTopup.created_at.desc())
        .limit(300)
    )
    pending = await db.scalar(select(func.count()).select_from(WalletTopup).where(WalletTopup.status == TopupStatus.PENDING.value)) or 0
    return {
        "items": [
            topup_out(t) | {"customer_id": str(t.customer_id), "telegram_user_id": tg, "reviewed_by": t.reviewed_by}
            for t, tg in rows.all()
        ],
        "pending": pending,
    }


@router.get("/topups/{topup_id}/receipt")
async def topup_receipt(topup_id: uuid.UUID, admin: Support, db: DbDep) -> FileResponse:
    path = private_file((await _topup(db, topup_id)).receipt_path)
    if path is None:
        raise not_found("RECEIPT_NOT_FOUND")
    return FileResponse(path)


@router.post("/topups/{topup_id}/approve")
async def approve_topup(topup_id: uuid.UUID, admin: Support, db: DbDep) -> dict[str, Any]:
    topup = await _topup(db, topup_id, lock=True)
    if topup.status != TopupStatus.PENDING.value:
        raise conflict("TOPUP_NOT_PENDING")
    topup.status = TopupStatus.APPROVED.value
    topup.reviewed_by = admin.name
    topup.reviewed_at = datetime.now(UTC)
    await wallet.record(db, topup.customer_id, topup.amount_uzs, "topup", str(topup.id))
    audit(db, f"admin:{admin.name}", "topup_approved", str(topup.id), amount_uzs=topup.amount_uzs)
    await db.commit()
    return topup_out(topup)


@router.post("/topups/{topup_id}/reject")
async def reject_topup(topup_id: uuid.UUID, body: ReasonIn, admin: Support, db: DbDep) -> dict[str, Any]:
    topup = await _topup(db, topup_id, lock=True)
    if topup.status != TopupStatus.PENDING.value:
        raise conflict("TOPUP_NOT_PENDING")
    topup.status = TopupStatus.REJECTED.value
    topup.reject_reason = body.reason
    topup.reviewed_by = admin.name
    topup.reviewed_at = datetime.now(UTC)
    audit(db, f"admin:{admin.name}", "topup_rejected", str(topup.id), reason=body.reason)
    await db.commit()
    return topup_out(topup)


# ---- bonus / cashback ----


class CreditIn(BaseModel):
    """The user is named by exactly one of: their Telegram id, or the customer picked in the users list."""

    telegram_user_id: Annotated[int | None, Field(gt=0)] = None
    customer_id: uuid.UUID | None = None
    amount_uzs: Annotated[int, Field(ge=100, le=5_000_000)]
    reason: Annotated[str, StringConstraints(strip_whitespace=True, min_length=3, max_length=256)]

    @model_validator(mode="after")
    def _one_target(self) -> "CreditIn":
        if (self.telegram_user_id is None) == (self.customer_id is None):
            raise ValueError("give telegram_user_id or customer_id, not both")
        return self


@router.post("/credit")
async def credit_balance(body: CreditIn, admin: Finance, db: DbDep) -> dict[str, Any]:
    """Money from UZARO to a user's balance (cashback, bonus, goodwill): one ledger line, audited."""
    if body.customer_id is not None:
        customer = await db.get(Customer, body.customer_id)
        if customer is None or customer.deleted_at is not None:
            raise not_found("CUSTOMER_NOT_FOUND")
        customer_id = customer.id
    else:
        customer_id = await db.scalar(select(TelegramLink.customer_id).where(TelegramLink.telegram_user_id == body.telegram_user_id))
        if customer_id is None:
            raise not_found("TELEGRAM_NOT_LINKED")
    reference = f"admin:{uuid.uuid4().hex}"
    await wallet.record(db, customer_id, body.amount_uzs, "bonus", reference)
    audit(db, f"admin:{admin.name}", "wallet_bonus", str(customer_id), telegram_user_id=body.telegram_user_id,
          amount_uzs=body.amount_uzs, reason=body.reason, reference=reference)
    await db.commit()
    return {"customer_id": str(customer_id), "amount_uzs": body.amount_uzs, "balance_uzs": await wallet.balance(db, customer_id)}
