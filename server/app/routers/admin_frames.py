"""Admin side of avatar frames: importing rendered frame packs, price, title, order and sale status, and deleting unsold ones."""

import tempfile
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, Depends, File, UploadFile, status
from pydantic import BaseModel, Field
from sqlalchemy import func, select

from app.deps import DbDep, require_admin
from app.errors import conflict, not_found
from app.models import AdminRole, AdminUser, FrameItem, OwnedFrame
from app.routers.admin_gifts import Title, unpack_upload
from app.routers.frames import FrameKey, frame_out
from app.services import frame_catalog
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


@router.post("/import")
async def import_frame_pack(
    admin: Support,
    db: DbDep,
    file: Annotated[UploadFile | None, File()] = None,
    files: Annotated[list[UploadFile] | None, File()] = None,
) -> dict[str, Any]:
    """Rendered frames (frame_renders: manifest.json plus <id>.webp and <id>_small.webp) as one ZIP [file] or the
    folder's own [files]. Same-id frames are upgraded and keep their price; the app picks them up from the catalog."""
    with tempfile.TemporaryDirectory() as folder:
        frames = await unpack_upload(Path(folder), file, files, "FRAME_PACK", frame_catalog.pack_file_limit, frame_catalog.parse_manifest)
        added, updated = await frame_catalog.import_rendered_frames(db, frames)
    name = file.filename if file is not None else "folder"
    ids = [f.key for f in frames]
    audit(db, f"admin:{admin.name}", "frame_pack_imported", "frames", file=(name or "")[:120], added=added, updated=updated, ids=ids)
    await db.commit()
    return {"added": added, "updated": updated, "ids": ids}


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
