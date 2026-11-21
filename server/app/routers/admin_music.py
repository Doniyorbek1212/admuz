"""Admin management of the hub's music: upload songs (MP3/M4A) straight to the server, edit, hide, delete."""

import asyncio
import uuid
from typing import Annotated, Any

from fastapi import APIRouter, Depends, File, Form, Query, UploadFile, status
from pydantic import BaseModel, StringConstraints
from sqlalchemy import func, or_, select

from app.db import like_pattern
from app.deps import DbDep, require_admin
from app.errors import bad_request, not_found
from app.models import AdminRole, AdminUser, MusicCategory, MusicTrack
from app.routers.music import track_out
from app.services.audit import audit
from app.uploads import public_dir, save_audio

router = APIRouter(prefix="/v1/admin/music", tags=["admin"])

Viewer = Annotated[AdminUser, Depends(require_admin(AdminRole.VIEWER))]
Support = Annotated[AdminUser, Depends(require_admin(AdminRole.SUPPORT))]
Name = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]


class TrackIn(BaseModel):
    category: MusicCategory
    title: Name
    artist: Annotated[str, StringConstraints(strip_whitespace=True, max_length=200)] = ""
    active: bool = True


def _admin_track(track: MusicTrack) -> dict[str, Any]:
    return track_out(track) | {"active": track.active, "created_at": track.created_at.isoformat()}


async def _track(db: DbDep, track_id: uuid.UUID) -> MusicTrack:
    track = await db.get(MusicTrack, track_id)
    if track is None:
        raise not_found("TRACK_NOT_FOUND")
    return track


@router.get("")
async def list_tracks(
    admin: Viewer,
    db: DbDep,
    category: MusicCategory | None = None,
    q: Annotated[str, StringConstraints(strip_whitespace=True, max_length=100)] = "",
    offset: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=500)] = 200,
) -> dict[str, Any]:
    stmt = select(MusicTrack)
    if category is not None:
        stmt = stmt.where(MusicTrack.category == category.value)
    if q:
        stmt = stmt.where(or_(MusicTrack.title.ilike(like_pattern(q)), MusicTrack.artist.ilike(like_pattern(q))))
    total = await db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    counts = dict((await db.execute(select(MusicTrack.category, func.count()).group_by(MusicTrack.category))).all())
    rows = await db.scalars(stmt.order_by(MusicTrack.created_at.desc(), MusicTrack.id).offset(offset).limit(limit))
    return {"items": [_admin_track(t) for t in rows], "total": total, "counts": {c.value: counts.get(c.value, 0) for c in MusicCategory}}


@router.post("", status_code=status.HTTP_201_CREATED)
async def upload_track(
    admin: Support,
    db: DbDep,
    file: Annotated[UploadFile, File()],
    category: Annotated[MusicCategory, Form()],
    title: Annotated[str, Form(max_length=200)],
    artist: Annotated[str, Form(max_length=200)] = "",
    duration_seconds: Annotated[int, Form(ge=0, le=24 * 3600)] = 0,
) -> dict[str, Any]:
    """One song per request; the browser reads the duration from the file before sending it."""
    if not title.strip():
        raise bad_request("TITLE_REQUIRED")
    name, size = await save_audio(file)
    track = MusicTrack(category=category.value, title=title.strip(), artist=artist.strip(), audio=name, size_bytes=size,
                       duration_seconds=duration_seconds)
    db.add(track)
    await db.flush()
    audit(db, admin.name, "music_uploaded", str(track.id), title=track.title, category=track.category, size=size)
    await db.commit()
    await db.refresh(track)
    return _admin_track(track)


@router.put("/{track_id}")
async def update_track(track_id: uuid.UUID, body: TrackIn, admin: Support, db: DbDep) -> dict[str, Any]:
    track = await _track(db, track_id)
    track.category = body.category.value
    track.title = body.title
    track.artist = body.artist
    track.active = body.active
    audit(db, admin.name, "music_updated", str(track.id), title=track.title)
    await db.commit()
    await db.refresh(track)
    return _admin_track(track)


@router.delete("/{track_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_track(track_id: uuid.UUID, admin: Support, db: DbDep) -> None:
    track = await _track(db, track_id)
    audio = track.audio
    audit(db, admin.name, "music_deleted", str(track.id), title=track.title)
    await db.delete(track)
    await db.commit()
    await asyncio.to_thread((public_dir() / audio).unlink, missing_ok=True)
