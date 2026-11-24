"""Admin side of avatar frames: price, title, order and sale status of the imported frames, and deleting unsold ones."""

from typing import Annotated, Any

from fastapi import APIRouter, Depends, status
from pydantic import BaseModel, Field
from sqlalchemy import func, select

from app.deps import DbDep, require_admin
from app.errors import conflict, not_found
from app.models import AdminRole, AdminUser, FrameItem, OwnedFrame
from app.routers.admin_gifts import Title
from app.routers.frames import FrameKey, frame_out
from app.services.audit import audit
from app.services.gift_catalog import MAX_PRICE_UZS
from app.uploads import public_dir

router = APIRouter(prefix="/v1/admin/frames", tags=["admin"])

Viewer = Annotated[AdminUser, Depends(require_admin(AdminRole.VIEWER))]
Support = Annotated[AdminUser, Depends(require_admin(AdminRole.SUPPORT))]


def _out(frame: FrameItem, owners: int = 0) -> dict[str, Any]:
    return frame_out(frame) | {"sort": frame.sort, "active": frame.active, "owners": owners}


async def _frame(db: DbDep, key: str) -> FrameItem:
    frame = await db.get(FrameItem, key)
    if frame is None:
        raise not_found("FRAME_NOT_FOUND")
    return frame


@router.get("")
async def list_frames(admin: Viewer, db: DbDep) -> dict[str, Any]:
    owners = dict((await db.execute(select(OwnedFrame.frame_key, func.count()).group_by(OwnedFrame.frame_key))).all())
    rows = await db.scalars(select(FrameItem).order_by(FrameItem.sort, FrameItem.key))
    return {"items": [_out(f, owners.get(f.key, 0)) for f in rows]}


class FrameIn(BaseModel):
    title: Title
    price_uzs: Annotated[int, Field(gt=0, le=MAX_PRICE_UZS)]
    sort: Annotated[int, Field(ge=0, le=10_000)] = 0
    active: bool = True


@router.put("/{key}")
async def update_frame(key: FrameKey, body: FrameIn, admin: Support, db: DbDep) -> dict[str, Any]:
    """Owners keep what they paid; a new price only applies to later purchases."""
    frame = await _frame(db, key)
    frame.title, frame.price_uzs, frame.sort, frame.active = body.title, body.price_uzs, body.sort, body.active
    audit(db, f"admin:{admin.name}", "frame_updated", key, price_uzs=body.price_uzs, active=body.active)
    await db.commit()
    return _out(frame)


@router.delete("/{key}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_frame(key: FrameKey, admin: Support, db: DbDep) -> None:
    """Only a frame nobody has bought; a bought one stays on its owners, so it can only be taken off sale."""
    frame = await _frame(db, key)
    if await db.scalar(select(OwnedFrame.frame_key).where(OwnedFrame.frame_key == key).limit(1)) is not None:
        raise conflict("FRAME_IN_USE")
    files = [name for name in (frame.animation, frame.small) if name]
    await db.delete(frame)
    audit(db, f"admin:{admin.name}", "frame_deleted", key)
    await db.commit()
    for name in files:
        (public_dir() / name).unlink(missing_ok=True)
