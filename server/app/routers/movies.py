"""The hub's films and series. Only titles with at least one published video are listed; the app streams each video
from its post in the public Telegram channel (tg_channel + tg_message_id) through TDLib."""

import uuid
from typing import Annotated, Any

from fastapi import APIRouter, Query
from pydantic import StringConstraints
from sqlalchemy import String, exists, func, or_, select

from app.db import like_pattern
from app.deps import CustomerDep, DbDep
from app.errors import not_found
from app.models import MovieKind, MovieTitle, MovieVideo, VideoStatus

router = APIRouter(prefix="/v1/movies", tags=["movies"])


def title_out(title: MovieTitle) -> dict[str, Any]:
    return {
        "id": str(title.id),
        "kind": title.kind.value,
        "title": title.title,
        "description": title.description,
        "year": title.year,
        "genres": title.genres,
        "categories": categories_of(title),
        "country": title.country,
        "language": title.language,
        "poster_url": f"/media/{title.poster}" if title.poster else None,
    }


def video_out(video: MovieVideo) -> dict[str, Any]:
    return {
        "id": str(video.id),
        "season": video.season,
        "episode": video.episode,
        "name": video.name,
        "duration_seconds": video.duration_seconds,
        "width": video.width,
        "height": video.height,
        "size_bytes": video.compressed_bytes,
        "channel": video.tg_channel,
        "message_id": video.tg_message_id,
    }


_published = exists().where(MovieVideo.title_id == MovieTitle.id, MovieVideo.status == VideoStatus.READY)

Search = Annotated[str, StringConstraints(strip_whitespace=True, max_length=100)]


def categories_of(title: MovieTitle) -> list[str]:
    """Genres are stored as one comma-separated string: "Drama, Turk seriallari"."""
    return [g.strip() for g in title.genres.split(",") if g.strip()]


@router.get("/categories")
async def categories(current: CustomerDep, db: DbDep, kind: MovieKind | None = None) -> list[dict[str, Any]]:
    """Categories that have something to watch, most titles first."""
    stmt = select(MovieTitle.genres).where(MovieTitle.active.is_(True), _published)
    if kind is not None:
        stmt = stmt.where(MovieTitle.kind == kind)
    counts: dict[str, int] = {}
    for genres in await db.scalars(stmt):
        for name in {g.strip() for g in genres.split(",") if g.strip()}:
            counts[name] = counts.get(name, 0) + 1
    return [{"name": name, "count": n} for name, n in sorted(counts.items(), key=lambda item: (-item[1], item[0].lower()))]


@router.get("")
async def list_titles(
    current: CustomerDep,
    db: DbDep,
    kind: MovieKind | None = None,
    category: Search = "",
    q: Search = "",
    offset: Annotated[int, Query(ge=0, le=10_000)] = 0,
    limit: Annotated[int, Query(ge=1, le=60)] = 30,
) -> dict[str, Any]:
    stmt = select(MovieTitle).where(MovieTitle.active.is_(True), _published)
    if kind is not None:
        stmt = stmt.where(MovieTitle.kind == kind)
    if category:
        # Whole comma-separated entries only, so "Drama" does not match "Melodrama".
        padded = func.concat(",", func.regexp_replace(MovieTitle.genres, r"\s*,\s*", ",", "g"), ",")
        stmt = stmt.where(func.lower(padded).contains(f",{category.lower()},", autoescape=True))
    for word in q.split()[:5]:
        pattern = like_pattern(word)
        stmt = stmt.where(or_(MovieTitle.title.ilike(pattern), MovieTitle.genres.ilike(pattern), MovieTitle.country.ilike(pattern),
                              MovieTitle.description.ilike(pattern), func.cast(MovieTitle.year, String).ilike(pattern)))
    total = await db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    rows = await db.scalars(stmt.order_by(MovieTitle.sort_order.desc(), MovieTitle.created_at.desc()).offset(offset).limit(limit))
    return {"items": [title_out(t) for t in rows], "total": total}


@router.get("/{title_id}")
async def title_detail(title_id: uuid.UUID, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    title = await db.get(MovieTitle, title_id)
    if title is None or not title.active:
        raise not_found("MOVIE_NOT_FOUND")
    videos = await db.scalars(
        select(MovieVideo).where(MovieVideo.title_id == title_id, MovieVideo.status == VideoStatus.READY).order_by(MovieVideo.season, MovieVideo.episode)
    )
    return title_out(title) | {"videos": [video_out(v) for v in videos]}
