"""The hub's music: songs admins uploaded to this server, by category; the app streams each from /media/<name>."""

from typing import Annotated, Any

from fastapi import APIRouter, Query
from pydantic import StringConstraints
from sqlalchemy import func, or_, select

from app.db import like_pattern
from app.deps import CustomerDep, DbDep
from app.models import MusicCategory, MusicTrack

router = APIRouter(prefix="/v1/music", tags=["music"])

Search = Annotated[str, StringConstraints(strip_whitespace=True, max_length=100)]


def track_out(track: MusicTrack) -> dict[str, Any]:
    return {
        "id": str(track.id),
        "category": track.category,
        "title": track.title,
        "artist": track.artist,
        "audio_url": f"/media/{track.audio}",
        "duration_seconds": track.duration_seconds,
        "size_bytes": track.size_bytes,
    }


@router.get("")
async def list_tracks(
    current: CustomerDep,
    db: DbDep,
    category: MusicCategory | None = None,
    q: Search = "",
    offset: Annotated[int, Query(ge=0, le=10_000)] = 0,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
) -> dict[str, Any]:
    stmt = select(MusicTrack).where(MusicTrack.active.is_(True))
    if category is not None:
        stmt = stmt.where(MusicTrack.category == category.value)
    for word in q.split()[:5]:
        pattern = like_pattern(word)
        stmt = stmt.where(or_(MusicTrack.title.ilike(pattern), MusicTrack.artist.ilike(pattern)))
    total = await db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    rows = await db.scalars(stmt.order_by(MusicTrack.created_at.desc(), MusicTrack.id).offset(offset).limit(limit))
    return {"items": [track_out(t) for t in rows], "total": total}
