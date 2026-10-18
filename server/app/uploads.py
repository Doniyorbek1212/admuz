"""File uploads: content sniffing (never trust the client's content type), size limits and storage."""

import asyncio
import uuid
from pathlib import Path

from fastapi import UploadFile

from app.config import get_settings
from app.errors import bad_request

# Magic bytes of accepted images.
_IMAGE_TYPES = ((b"\xff\xd8\xff", "jpg"), (b"\x89PNG\r\n\x1a\n", "png"))
PUBLIC_NAME_PATTERN = r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp|mp4)$"


def sniff(data: bytes) -> tuple[str, str] | None:
    """Returns (kind, extension) for JPEG, PNG, WebP images and MP4/MOV videos, else None."""
    for magic, ext in _IMAGE_TYPES:
        if data.startswith(magic):
            return "image", ext
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image", "webp"
    if data[4:8] == b"ftyp":
        return "video", "mp4"
    return None


async def read_limited(file: UploadFile, limit: int) -> bytes:
    data = await file.read(limit + 1)
    if len(data) > limit:
        raise bad_request("FILE_TOO_LARGE")
    if not data:
        raise bad_request("FILE_EMPTY")
    return data


def _write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


async def save_receipt(file: UploadFile) -> str:
    """Stores a payment receipt image privately; returns its path relative to the media dir."""
    data = await read_limited(file, get_settings().max_image_bytes)
    kind = sniff(data)
    if kind is None or kind[0] != "image":
        raise bad_request("RECEIPT_NOT_AN_IMAGE")
    relative = f"receipts/{uuid.uuid4()}.{kind[1]}"
    await asyncio.to_thread(_write, Path(get_settings().media_dir) / relative, data)
    return relative


async def save_public(file: UploadFile) -> tuple[str, str, int]:
    """Stores a product photo or video publicly; returns (name, kind, size)."""
    settings = get_settings()
    data = await read_limited(file, max(settings.max_image_bytes, settings.max_video_bytes))
    kind = sniff(data)
    if kind is None:
        raise bad_request("MEDIA_TYPE_NOT_SUPPORTED")
    limit = settings.max_image_bytes if kind[0] == "image" else settings.max_video_bytes
    if len(data) > limit:
        raise bad_request("FILE_TOO_LARGE")
    name = f"{uuid.uuid4()}.{kind[1]}"
    await asyncio.to_thread(_write, public_dir() / name, data)
    return name, kind[0], len(data)


def public_dir() -> Path:
    return Path(get_settings().media_dir) / "public"


def private_file(relative: str) -> Path | None:
    """Resolves a stored receipt path, refusing anything outside the media dir."""
    root = Path(get_settings().media_dir).resolve()
    path = (root / relative).resolve()
    return path if root in path.parents and path.is_file() else None
