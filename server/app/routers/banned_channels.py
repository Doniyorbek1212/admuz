"""Banned Telegram channels: the app downloads the list and hides those chats from search; admins keep it current."""

import re
import uuid
from typing import Annotated, Any

from fastapi import APIRouter, Depends, status
from pydantic import BaseModel, StringConstraints, field_validator, model_validator
from sqlalchemy import or_, select

from app.db import like_pattern
from app.deps import CustomerDep, DbDep, require_admin
from app.errors import not_found
from app.models import AdminRole, AdminUser, BannedChannel
from app.services.audit import audit

router = APIRouter(prefix="/v1/banned-channels", tags=["banned"])
admin_router = APIRouter(prefix="/v1/admin/banned-channels", tags=["admin"])

Viewer = Annotated[AdminUser, Depends(require_admin(AdminRole.VIEWER))]
Support = Annotated[AdminUser, Depends(require_admin(AdminRole.SUPPORT))]
Text = Annotated[str, StringConstraints(strip_whitespace=True, max_length=300)]

# A public username, or "+hash" of an invite link.
USERNAME = re.compile(r"\+?[A-Za-z0-9_-]{4,64}")
LINK_PREFIX = re.compile(r"^(?:https?://)?(?:www\.)?(?:t\.me|telegram\.me)/|^@", re.IGNORECASE)


class ChannelIn(BaseModel):
    title: Text = ""
    username: Text = ""
    note: Text = ""
    active: bool = True

    @field_validator("username")
    @classmethod
    def _username(cls, value: str) -> str:
        """Accepts "@name", "t.me/name", "https://t.me/name/123" or "t.me/+hash"; stores just the name."""
        name = LINK_PREFIX.sub("", value).split("/")[0].split("?")[0]
        if name and not USERNAME.fullmatch(name):
            raise ValueError("USERNAME_INVALID")
        return name

    @model_validator(mode="after")
    def _something(self) -> "ChannelIn":
        if not self.title and not self.username:
            raise ValueError("TITLE_OR_USERNAME_REQUIRED")
        return self


def _out(row: BannedChannel) -> dict[str, Any]:
    return {"id": str(row.id), "title": row.title, "username": row.username, "note": row.note, "active": row.active,
            "created_at": row.created_at.isoformat()}


@router.get("")
async def banned_list(current: CustomerDep, db: DbDep) -> dict[str, Any]:
    """Usernames (lowercase) match exactly; titles only for entries without a username, normalized by the app."""
    rows = (await db.execute(select(BannedChannel.title, BannedChannel.username).where(BannedChannel.active.is_(True)))).all()
    return {
        "usernames": sorted({u.lower() for _, u in rows if u}),
        "titles": sorted({t for t, u in rows if t and not u}),
    }


async def _row(db: DbDep, channel_id: uuid.UUID) -> BannedChannel:
    row = await db.get(BannedChannel, channel_id)
    if row is None:
        raise not_found("CHANNEL_NOT_FOUND")
    return row


@admin_router.get("")
async def list_channels(admin: Viewer, db: DbDep, q: Annotated[str, StringConstraints(strip_whitespace=True, max_length=100)] = "") -> dict[str, Any]:
    stmt = select(BannedChannel)
    if q:
        pattern = like_pattern(q)
        stmt = stmt.where(or_(BannedChannel.title.ilike(pattern), BannedChannel.username.ilike(pattern), BannedChannel.note.ilike(pattern)))
    rows = list(await db.scalars(stmt.order_by(BannedChannel.created_at.desc(), BannedChannel.title)))
    return {"items": [_out(r) for r in rows], "total": len(rows)}


@admin_router.post("", status_code=status.HTTP_201_CREATED)
async def add_channel(body: ChannelIn, admin: Support, db: DbDep) -> dict[str, Any]:
    row = BannedChannel(**body.model_dump())
    db.add(row)
    await db.flush()
    audit(db, admin.name, "banned_channel_added", str(row.id), title=row.title, username=row.username)
    await db.commit()
    await db.refresh(row)
    return _out(row)


@admin_router.put("/{channel_id}")
async def update_channel(channel_id: uuid.UUID, body: ChannelIn, admin: Support, db: DbDep) -> dict[str, Any]:
    row = await _row(db, channel_id)
    for key, value in body.model_dump().items():
        setattr(row, key, value)
    audit(db, admin.name, "banned_channel_updated", str(row.id), title=row.title, username=row.username, active=row.active)
    await db.commit()
    await db.refresh(row)
    return _out(row)


@admin_router.delete("/{channel_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_channel(channel_id: uuid.UUID, admin: Support, db: DbDep) -> None:
    row = await _row(db, channel_id)
    audit(db, admin.name, "banned_channel_deleted", str(row.id), title=row.title, username=row.username)
    await db.delete(row)
    await db.commit()
