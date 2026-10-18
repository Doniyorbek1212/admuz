"""Public product media: customers upload photos and short videos; anyone can fetch them by their random name."""

import re
from typing import Annotated, Any

from fastapi import APIRouter, File, UploadFile, status
from fastapi.responses import FileResponse

from app.deps import CustomerDep, DbDep, rate_limit
from app.errors import not_found
from app.models import MediaUpload
from app.uploads import PUBLIC_NAME_PATTERN, public_dir, save_public

router = APIRouter(tags=["media"])

_NAME = re.compile(PUBLIC_NAME_PATTERN)
_TYPES = {"jpg": "image/jpeg", "png": "image/png", "webp": "image/webp", "mp4": "video/mp4"}


@router.post("/v1/media", status_code=status.HTTP_201_CREATED)
async def upload_media(current: CustomerDep, db: DbDep, file: Annotated[UploadFile, File()]) -> dict[str, Any]:
    await rate_limit(f"media:{current.id}", limit=120, window_seconds=3600)
    name, kind, size = await save_public(file)
    db.add(MediaUpload(name=name, customer_id=current.id, kind=kind, size_bytes=size))
    await db.commit()
    return {"type": kind, "url": f"/media/{name}"}


@router.get("/media/{name}")
async def get_media(name: str) -> FileResponse:
    if not _NAME.match(name):
        raise not_found("MEDIA_NOT_FOUND")
    path = public_dir() / name
    if not path.is_file():
        raise not_found("MEDIA_NOT_FOUND")
    # Names are random and files never change: cache for a long time.
    return FileResponse(path, media_type=_TYPES[name.rsplit(".", 1)[1]], headers={"Cache-Control": "public, max-age=31536000, immutable"})
