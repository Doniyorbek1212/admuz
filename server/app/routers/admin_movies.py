"""Admin management of the hub's films and series: titles, posters, resumable chunked video uploads and storage stats."""

import asyncio
import uuid
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, Depends, File, Query, Request, UploadFile, status
from pydantic import BaseModel, Field, StringConstraints
from sqlalchemy import func, select

from app.config import get_settings
from app.deps import DbDep, require_admin
from app.errors import bad_request, conflict, not_found
from app.models import AdminRole, AdminUser, MovieKind, MovieTitle, MovieVideo, VideoStatus
from app.routers.movies import title_out, video_out
from app.services import movies
from app.services.audit import audit
from app.uploads import save_public

router = APIRouter(prefix="/v1/admin/movies", tags=["admin"])

Viewer = Annotated[AdminUser, Depends(require_admin(AdminRole.VIEWER))]
Support = Annotated[AdminUser, Depends(require_admin(AdminRole.SUPPORT))]


def _text(max_length: int) -> Any:
    return Annotated[str, StringConstraints(strip_whitespace=True, max_length=max_length)]


class TitleIn(BaseModel):
    kind: MovieKind
    title: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]
    description: _text(3000) = ""
    year: Annotated[int | None, Field(ge=1888, le=2100)] = None
    genres: _text(200) = ""
    country: _text(80) = ""
    language: _text(40) = ""
    active: bool = True
    sort_order: Annotated[int, Field(ge=-1000, le=1000)] = 0


class VideoIn(BaseModel):
    season: Annotated[int, Field(ge=0, le=100)] = 0
    episode: Annotated[int, Field(ge=0, le=10_000)] = 0
    name: _text(200) = ""
    file_name: _text(255) = ""
    size_bytes: Annotated[int, Field(gt=0)]


def _admin_video(video: MovieVideo) -> dict[str, Any]:
    stage, percent = movies.PROGRESS.get(video.id, ("", 0))
    return video_out(video) | {
        "status": video.status.value, "error": video.error, "original_name": video.original_name, "original_bytes": video.original_bytes,
        "uploaded_bytes": video.uploaded_bytes, "compressed_bytes": video.compressed_bytes, "stage": stage, "percent": percent,
    }


async def _title(db: DbDep, title_id: uuid.UUID) -> MovieTitle:
    title = await db.get(MovieTitle, title_id)
    if title is None:
        raise not_found("MOVIE_NOT_FOUND")
    return title


async def _video(db: DbDep, video_id: uuid.UUID) -> MovieVideo:
    video = await db.get(MovieVideo, video_id)
    if video is None:
        raise not_found("VIDEO_NOT_FOUND")
    return video


@router.get("/stats")
async def stats(admin: Viewer, db: DbDep) -> dict[str, Any]:
    """What the movies cost in storage: originals received, what Telegram holds, what the server holds right now."""
    row = (await db.execute(select(
        func.count(), func.coalesce(func.sum(MovieVideo.original_bytes), 0), func.coalesce(func.sum(MovieVideo.compressed_bytes), 0),
        func.coalesce(func.sum(MovieVideo.duration_seconds), 0),
    ).where(MovieVideo.status == VideoStatus.READY))).one()
    by_status = dict((await db.execute(select(MovieVideo.status, func.count()).group_by(MovieVideo.status))).all())
    titles = await db.scalar(select(func.count()).select_from(MovieTitle)) or 0
    settings = get_settings()
    return {
        "titles": titles,
        "videos": {s.value: by_status.get(s, 0) for s in VideoStatus},
        # SUM over bigint comes back as Decimal, which JSON would send as a string.
        "ready_original_bytes": int(row[1]),
        "ready_compressed_bytes": int(row[2]),
        "ready_duration_seconds": int(row[3]),
        **await asyncio.to_thread(movies.disk_report),
        "configured": settings.movies_configured,
        "channel": settings.movies_channel,
        "chunk_bytes": settings.movie_chunk_bytes,
        "max_upload_bytes": settings.movie_max_upload_bytes,
    }


@router.get("")
async def list_titles(
    admin: Viewer,
    db: DbDep,
    q: Annotated[str, StringConstraints(strip_whitespace=True, max_length=100)] = "",
    offset: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=200)] = 100,
) -> dict[str, Any]:
    stmt = select(MovieTitle)
    if q:
        stmt = stmt.where(MovieTitle.title.ilike(f"%{q.replace('%', '').replace('_', '')}%"))
    total = await db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    titles = list(await db.scalars(stmt.order_by(MovieTitle.created_at.desc()).offset(offset).limit(limit)))
    videos = await db.scalars(select(MovieVideo).where(MovieVideo.title_id.in_([t.id for t in titles])).order_by(MovieVideo.season, MovieVideo.episode))
    grouped: dict[uuid.UUID, list[dict[str, Any]]] = {}
    for video in videos:
        grouped.setdefault(video.title_id, []).append(_admin_video(video))
    return {"items": [title_out(t) | {"active": t.active, "sort_order": t.sort_order, "videos": grouped.get(t.id, [])} for t in titles], "total": total}


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_title(body: TitleIn, admin: Support, db: DbDep) -> dict[str, Any]:
    title = MovieTitle(**body.model_dump())
    db.add(title)
    await db.flush()
    audit(db, admin.name, "movie_created", str(title.id), title=title.title)
    await db.commit()
    await db.refresh(title)
    return title_out(title)


@router.put("/{title_id}")
async def update_title(title_id: uuid.UUID, body: TitleIn, admin: Support, db: DbDep) -> dict[str, Any]:
    title = await _title(db, title_id)
    for field, value in body.model_dump().items():
        setattr(title, field, value)
    audit(db, admin.name, "movie_updated", str(title.id), title=title.title)
    await db.commit()
    await db.refresh(title)
    return title_out(title)


@router.delete("/{title_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_title(title_id: uuid.UUID, admin: Support, db: DbDep) -> None:
    title = await _title(db, title_id)
    videos = list(await db.scalars(select(MovieVideo).where(MovieVideo.title_id == title_id)))
    if any(v.status == VideoStatus.PROCESSING for v in videos):
        raise conflict("VIDEO_PROCESSING")
    audit(db, admin.name, "movie_deleted", str(title.id), title=title.title, videos=len(videos))
    await db.delete(title)
    await db.commit()
    for video in videos:
        movies.remove_local_files(video.id)
    await movies.delete_from_channel([v.tg_message_id for v in videos if v.tg_message_id])


@router.post("/{title_id}/poster")
async def upload_poster(title_id: uuid.UUID, admin: Support, db: DbDep, file: Annotated[UploadFile, File()]) -> dict[str, Any]:
    title = await _title(db, title_id)
    name, kind, _ = await save_public(file)
    if kind != "image":
        raise bad_request("POSTER_NOT_AN_IMAGE")
    title.poster = name
    await db.commit()
    await db.refresh(title)
    return title_out(title)


@router.post("/{title_id}/videos", status_code=status.HTTP_201_CREATED)
async def start_video(title_id: uuid.UUID, body: VideoIn, admin: Support, db: DbDep) -> dict[str, Any]:
    """Opens an upload; the browser then sends the file with PUT .../content in chunk_bytes pieces."""
    title = await _title(db, title_id)
    settings = get_settings()
    if body.size_bytes > settings.movie_max_upload_bytes:
        raise bad_request("FILE_TOO_LARGE")
    report = await asyncio.to_thread(movies.disk_report)
    # The original and its compressed copy sit on disk together while processing.
    if report["disk_free_bytes"] - settings.movie_disk_reserve_bytes < body.size_bytes * 2:
        raise bad_request("DISK_FULL")
    video = MovieVideo(title_id=title.id, season=body.season, episode=body.episode, name=body.name, original_name=body.file_name,
                       original_bytes=body.size_bytes)
    db.add(video)
    await db.flush()
    audit(db, admin.name, "movie_video_started", str(video.id), title=title.title, size=body.size_bytes)
    await db.commit()
    await db.refresh(video)
    return _admin_video(video) | {"chunk_bytes": settings.movie_chunk_bytes}


def _append(path: Path, data: bytes, offset: int) -> None:
    with path.open("r+b" if offset else "wb") as f:
        f.truncate(offset)  # drops a half-written chunk from an interrupted request
        f.seek(offset)
        f.write(data)


@router.put("/videos/{video_id}/content")
async def upload_chunk(video_id: uuid.UUID, request: Request, admin: Support, db: DbDep, offset: Annotated[int, Query(ge=0)]) -> dict[str, Any]:
    """Appends one raw chunk at `offset`; a resumed upload asks GET .../videos/{id} for uploaded_bytes first."""
    video = await _video(db, video_id)
    if video.status != VideoStatus.UPLOADING:
        raise conflict("VIDEO_NOT_UPLOADING")
    if offset != video.uploaded_bytes:
        raise conflict("WRONG_OFFSET", str(video.uploaded_bytes))
    data = await request.body()
    if not data or len(data) > get_settings().movie_chunk_bytes or offset + len(data) > video.original_bytes:
        raise bad_request("BAD_CHUNK")
    if offset == 0 and not movies.looks_like_video(data[:512]):
        raise bad_request("NOT_A_VIDEO")
    await asyncio.to_thread(_append, movies.source_path(video.id), data, offset)
    video.uploaded_bytes = offset + len(data)
    if video.uploaded_bytes == video.original_bytes:
        video.status = VideoStatus.QUEUED
    await db.commit()
    await db.refresh(video)
    return _admin_video(video)


@router.get("/videos/{video_id}")
async def video_status(video_id: uuid.UUID, admin: Viewer, db: DbDep) -> dict[str, Any]:
    return _admin_video(await _video(db, video_id))


@router.post("/videos/{video_id}/retry")
async def retry_video(video_id: uuid.UUID, admin: Support, db: DbDep) -> dict[str, Any]:
    video = await _video(db, video_id)
    if video.status != VideoStatus.FAILED:
        raise conflict("VIDEO_NOT_FAILED")
    if not movies.source_path(video.id).is_file():
        raise bad_request("SOURCE_MISSING")
    video.status = VideoStatus.QUEUED
    video.error = ""
    await db.commit()
    await db.refresh(video)
    return _admin_video(video)


@router.delete("/videos/{video_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_video(video_id: uuid.UUID, admin: Support, db: DbDep) -> None:
    video = await _video(db, video_id)
    if video.status == VideoStatus.PROCESSING:
        raise conflict("VIDEO_PROCESSING")
    message_id = video.tg_message_id
    audit(db, admin.name, "movie_video_deleted", str(video.id))
    await db.delete(video)
    await db.commit()
    movies.remove_local_files(video_id)
    await movies.delete_from_channel([message_id] if message_id else [])
