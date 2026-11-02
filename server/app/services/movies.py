"""Hub movies pipeline: chunked admin upload -> ffmpeg compress -> bot posts to a public Telegram channel -> local files deleted.

One worker task runs inside the API process (single uvicorn worker) and handles one video at a time, so a
movie never competes with another for the shared VPS CPU and disk.
"""

import asyncio
import json
import logging
import shutil
import uuid
from dataclasses import dataclass
from pathlib import Path

from sqlalchemy import select, update

from app.config import get_settings
from app.db import SessionFactory
from app.models import MovieTitle, MovieVideo, VideoStatus

log = logging.getLogger(__name__)

# Bots may upload files up to 2000 MiB over MTProto.
TELEGRAM_MAX_BYTES = 2000 * 1024 * 1024
POLL_SECONDS = 10

# video id -> (stage, percent) for the admin panel; in memory, lost on restart, which only resets the bar.
PROGRESS: dict[uuid.UUID, tuple[str, int]] = {}

# Magic bytes of the containers ffmpeg gets: MP4/MOV, Matroska/WebM, AVI, MPEG-TS.
_CONTAINERS = (
    lambda b: b[4:8] == b"ftyp",
    lambda b: b.startswith(b"\x1a\x45\xdf\xa3"),
    lambda b: b.startswith(b"RIFF") and b[8:12] == b"AVI ",
    lambda b: b[:1] == b"\x47" and len(b) > 188 and b[188:189] == b"\x47",
)


class MovieError(Exception):
    """A processing failure shown to the admin as the video's error."""


@dataclass(frozen=True)
class VideoInfo:
    duration: int
    width: int
    height: int


def looks_like_video(head: bytes) -> bool:
    return any(check(head) for check in _CONTAINERS)


def work_dir() -> Path:
    path = Path(get_settings().media_dir) / "movies"
    path.mkdir(parents=True, exist_ok=True)
    return path


def source_path(video_id: uuid.UUID) -> Path:
    return work_dir() / f"{video_id}.src"


def _output_path(video_id: uuid.UUID) -> Path:
    return work_dir() / f"{video_id}.mp4"


def _thumb_path(video_id: uuid.UUID) -> Path:
    return work_dir() / f"{video_id}.jpg"


def remove_local_files(video_id: uuid.UUID) -> None:
    for path in (source_path(video_id), _output_path(video_id), _thumb_path(video_id)):
        path.unlink(missing_ok=True)
    PROGRESS.pop(video_id, None)


def disk_report() -> dict[str, int]:
    """Bytes the pipeline holds on disk right now, plus the disk's free space."""
    held = sum(p.stat().st_size for p in work_dir().iterdir() if p.is_file())
    usage = shutil.disk_usage(work_dir())
    return {"work_bytes": held, "disk_free_bytes": usage.free, "disk_total_bytes": usage.total}


def episode_label(title: MovieTitle, video: MovieVideo) -> str:
    if video.season or video.episode:
        parts = [f"{video.season}-fasl" if video.season else "", f"{video.episode}-qism" if video.episode else ""]
        label = " ".join(p for p in parts if p)
        return f"{title.title} · {label}" + (f" · {video.name}" if video.name else "")
    return title.title + (f" · {video.name}" if video.name else "")


async def _run(*args: str) -> tuple[int, str]:
    proc = await asyncio.create_subprocess_exec(*args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    out, err = await proc.communicate()
    return proc.returncode or 0, (out or err).decode(errors="replace")


async def probe(path: Path) -> VideoInfo:
    code, out = await _run("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:format=duration",
                           "-of", "json", str(path))
    if code != 0:
        raise MovieError("Fayl video emas yoki buzilgan")
    data = json.loads(out)
    stream = (data.get("streams") or [{}])[0]
    return VideoInfo(round(float(data.get("format", {}).get("duration") or 0)), int(stream.get("width") or 0), int(stream.get("height") or 0))


async def compress(video_id: uuid.UUID, src: Path, dst: Path, info: VideoInfo) -> VideoInfo:
    """H.264/AAC MP4 at most movie_max_height tall, moov atom first so players can stream it."""
    settings = get_settings()
    height = min(info.height or settings.movie_max_height, settings.movie_max_height)
    height -= height % 2
    args = [
        "nice", "-n", "10", "ffmpeg", "-hide_banner", "-nostdin", "-y", "-i", str(src),
        "-map", "0:v:0", "-map", "0:a:0?", "-vf", f"scale=-2:{height}", "-c:v", "libx264", "-preset", "veryfast",
        "-crf", str(settings.movie_crf), "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-ac", "2",
        "-movflags", "+faststart", "-threads", str(settings.movie_ffmpeg_threads), "-progress", "pipe:1", "-nostats", str(dst),
    ]
    proc = await asyncio.create_subprocess_exec(*args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    assert proc.stdout is not None and proc.stderr is not None
    stderr_task = asyncio.create_task(proc.stderr.read())
    async for raw in proc.stdout:
        line = raw.decode(errors="replace").strip()
        if line.startswith("out_time_us=") and info.duration:
            try:
                done = int(line.split("=", 1)[1]) / 1_000_000
            except ValueError:
                continue
            PROGRESS[video_id] = ("compress", min(99, int(done * 100 / info.duration)))
    code = await proc.wait()
    stderr = (await stderr_task).decode(errors="replace")
    if code != 0:
        log.warning("ffmpeg failed for %s: %s", video_id, stderr[-2000:])
        raise MovieError("Siqishda xato: " + (stderr.strip().splitlines() or ["ffmpeg"])[-1][:200])
    return await probe(dst)


async def make_thumb(src: Path, dst: Path, info: VideoInfo) -> Path | None:
    code, _ = await _run("ffmpeg", "-hide_banner", "-nostdin", "-y", "-ss", str(max(1, info.duration // 10)), "-i", str(src),
                         "-frames:v", "1", "-vf", "scale=320:-2", "-q:v", "4", str(dst))
    return dst if code == 0 and dst.is_file() else None


async def _bot():  # telethon is imported lazily: tests and the API never load it
    from telethon import TelegramClient

    settings = get_settings()
    client = TelegramClient(str(work_dir() / "bot"), settings.tg_api_id, settings.tg_api_hash)
    await client.start(bot_token=settings.movies_bot_token)
    return client


async def post_to_channel(video_id: uuid.UUID, path: Path, thumb: Path | None, info: VideoInfo, caption: str) -> int:
    """Posts the file to the movies channel as a streamable video; returns the message id."""
    from telethon.tl.types import DocumentAttributeVideo

    settings = get_settings()

    def progress(sent: int, total: int) -> None:
        PROGRESS[video_id] = ("telegram", int(sent * 100 / total) if total else 0)

    client = await _bot()
    try:
        message = await client.send_file(
            settings.movies_channel, str(path), caption=caption, thumb=str(thumb) if thumb else None, supports_streaming=True,
            attributes=[DocumentAttributeVideo(duration=info.duration, w=info.width, h=info.height, supports_streaming=True)],
            progress_callback=progress, part_size_kb=512,
        )
        return int(message.id)
    finally:
        await client.disconnect()


async def delete_from_channel(message_ids: list[int]) -> None:
    """Best effort: a title deleted in the panel also disappears from the channel."""
    if not message_ids or not get_settings().movies_configured:
        return
    try:
        client = await _bot()
        try:
            await client.delete_messages(get_settings().movies_channel, message_ids)
        finally:
            await client.disconnect()
    except Exception:  # the DB delete already happened; leftovers are only orphaned posts
        log.exception("could not delete movie posts %s", message_ids)


async def process(video_id: uuid.UUID) -> None:
    """Compress and publish one queued video, recording the result on its row."""
    settings = get_settings()
    async with SessionFactory() as db:
        video = await db.get(MovieVideo, video_id)
        title = await db.get(MovieTitle, video.title_id) if video else None
        if video is None or title is None:
            return
        caption = episode_label(title, video)
    src, out, thumb = source_path(video_id), _output_path(video_id), _thumb_path(video_id)
    try:
        if not settings.movies_configured:
            raise MovieError("Telegram kanal sozlanmagan (SADO_BILLING_MOVIES_* sozlamalari)")
        if not src.is_file():
            raise MovieError("Asl fayl serverda topilmadi, qayta yuklang")
        PROGRESS[video_id] = ("compress", 0)
        info = await compress(video_id, src, out, await probe(src))
        size = out.stat().st_size
        if size > TELEGRAM_MAX_BYTES:
            raise MovieError(f"Siqilgan fayl {size // 1048576} MB: Telegram 2000 MB gacha qabul qiladi. Kinoni qismlarga bo'ling")
        thumb_file = await make_thumb(out, thumb, info)
        PROGRESS[video_id] = ("telegram", 0)
        message_id = await post_to_channel(video_id, out, thumb_file, info, caption)
    except Exception as error:  # any failure is recorded for the admin; the original stays for a retry
        if not isinstance(error, MovieError):
            log.exception("movie %s failed", video_id)
        out.unlink(missing_ok=True)
        thumb.unlink(missing_ok=True)
        PROGRESS.pop(video_id, None)
        async with SessionFactory() as db:
            await db.execute(update(MovieVideo).where(MovieVideo.id == video_id).values(status=VideoStatus.FAILED, error=str(error)[:500]))
            await db.commit()
        return
    async with SessionFactory() as db:
        await db.execute(update(MovieVideo).where(MovieVideo.id == video_id).values(
            status=VideoStatus.READY, error="", compressed_bytes=size, duration_seconds=info.duration, width=info.width,
            height=info.height, tg_channel=settings.movies_channel, tg_message_id=message_id,
        ))
        await db.commit()
    remove_local_files(video_id)
    log.info("movie %s published as message %s (%s -> %s bytes)", video_id, message_id, src, size)


async def _claim_next() -> uuid.UUID | None:
    async with SessionFactory() as db:
        video = await db.scalar(
            select(MovieVideo).where(MovieVideo.status == VideoStatus.QUEUED).order_by(MovieVideo.updated_at).limit(1).with_for_update(skip_locked=True)
        )
        if video is None:
            return None
        video.status = VideoStatus.PROCESSING
        await db.commit()
        return video.id


async def worker(stop: asyncio.Event) -> None:
    """Background loop started by the app's lifespan."""
    async with SessionFactory() as db:
        # A restart mid-job: the interrupted video goes back to the queue.
        await db.execute(update(MovieVideo).where(MovieVideo.status == VideoStatus.PROCESSING).values(status=VideoStatus.QUEUED))
        await db.commit()
    while not stop.is_set():
        try:
            video_id = await _claim_next()
            if video_id is not None:
                await process(video_id)
                continue
        except Exception:  # e.g. the database restarting: keep the worker alive
            log.exception("movie worker error")
        try:
            await asyncio.wait_for(stop.wait(), timeout=POLL_SECONDS)
        except TimeoutError:
            pass
