"""Songs on the content bot: an admin sends (or forwards) an MP3/M4A, picks the Music section with a button, and the
song is stored on this server and listed in the app, exactly like an upload from the admin panel.

Drafts, buttons and the admin check are the movies bot's (services/movie_bot.py); this module only adds the song steps.
Unlike a video, the song is downloaded: the app streams music from /media. The Bot API hands bots files up to 20 MB.
"""

import html
import re
import secrets
from pathlib import PurePath
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.deps import get_redis
from app.errors import ApiError
from app.models import MusicCategory, MusicTrack
from app.services import movie_bot as bot
from app.services import telegram_api as tg
from app.services.audit import audit
from app.uploads import save_audio_bytes

BOT_API_DOWNLOAD_LIMIT = 20 * 1024 * 1024
RENAME_STEP = "song_name"
# shortcut: a copy of MUSIC_CATEGORIES in admin_music.js; move both to one server list if they start to drift.
SECTIONS = {
    MusicCategory.UZ_NEW: "O'zbekcha yangi", MusicCategory.UZ_OLD: "O'zbekcha eski",
    MusicCategory.WORLD: "Jahon qo'shiqlari", MusicCategory.CAR: "Mashina uchun",
}
_AUDIO_MIME = ("audio/mpeg", "audio/mp3", "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/aac")
_DASH = re.compile(r"\s+[-–—]\s+")


def _limit() -> int:
    return min(get_settings().max_audio_bytes, BOT_API_DOWNLOAD_LIMIT)


def song_of(message: dict[str, Any]) -> dict[str, Any] | None:
    """The song in a message: an audio, or a document that is an MP3/M4A file (voice notes are not songs)."""
    if isinstance(audio := message.get("audio"), dict):
        return audio
    document = message.get("document")
    if not isinstance(document, dict):
        return None
    name = str(document.get("file_name") or "").lower()
    if str(document.get("mime_type") or "").lower() in _AUDIO_MIME or name.endswith((".mp3", ".m4a")):
        return document
    return None


def split_name(text: str) -> tuple[str, str]:
    """"Ijrochi - Qo'shiq" into (artist, title); a name without a dash is the title alone."""
    parts = _DASH.split(text.strip(), maxsplit=1)
    artist, title = (parts[0], parts[1]) if len(parts) == 2 and parts[0] and parts[1] else ("", text.strip())
    return artist.strip()[:200], title.strip()[:200]


def _label(draft: dict[str, Any]) -> str:
    name = f"{draft['artist']} — {draft['title']}" if draft["artist"] else draft["title"]
    return html.escape(name)


async def new_draft(user_id: int, message: dict[str, Any], song: dict[str, Any]) -> None:
    if int(song.get("file_size") or 0) > _limit():
        return await bot._say(user_id, f"Fayl juda katta: bot {_limit() // 1_048_576} MB gacha qo'shiqni yuklay oladi. "
                                       "Kattaroq faylni admin paneldan yuklang.")
    stem = PurePath(str(song.get("file_name") or "")).stem.replace("_", " ").strip()
    artist, title = str(song.get("performer") or "").strip()[:200], str(song.get("title") or "").strip()[:200]
    if not title:
        artist, title = (artist, stem[:200]) if artist else split_name(stem)
    draft = {
        "id": secrets.token_hex(4), "u": user_id, "t": "song", "file": song.get("file_id"), "msg": message["message_id"],
        "dur": int(song.get("duration") or 0), "title": title or "Nomsiz qo'shiq", "artist": artist, "step": "song_section", "ui": None,
    }
    await _ask_section(draft, reply_to=draft["msg"])


async def _ask_section(draft: dict[str, Any], reply_to: int | None = None) -> None:
    draft["step"] = "song_section"
    buttons = [bot._button(label, f"m:{draft['id']}:{section.value}") for section, label in SECTIONS.items()]
    rows = [buttons[i : i + 2] for i in range(0, len(buttons), 2)] + [
        [bot._button("✏️ Nomini o'zgartirish", f"m:{draft['id']}:rename")],
        [bot._button("✖ Bekor qilish", f"x:{draft['id']}")],
    ]
    text = f"🎵 <b>{_label(draft)}</b>\nQaysi bo'limga qo'shamiz?"
    if reply_to is None:
        await bot._show(draft, text, rows)
    else:
        sent = await bot._api("sendMessage", chat_id=draft["u"], text=text, parse_mode="HTML", reply_markup=bot._keyboard(rows),
                              reply_parameters={"message_id": reply_to, "allow_sending_without_reply": True})
        draft["ui"] = sent["message_id"]
    await bot._save(draft)


async def got_name(draft: dict[str, Any], text: str) -> None:
    artist, title = split_name(text.splitlines()[0])
    if not title:
        return await bot._say(draft["u"], "Nomini yozing, masalan: <i>Sherali Jo'rayev - Bahor</i>")
    draft.update(artist=artist, title=title)
    await _ask_section(draft)


async def picked(db: AsyncSession, draft: dict[str, Any], choice: str) -> str | None:
    """A button under a song: rename, or a section, which publishes it; returns a pop-up text, or None."""
    if draft.get("t") != "song":
        return None
    if choice == "rename":
        await bot._show(draft, f"🎵 <b>{_label(draft)}</b>", [])
        await bot._ask_text(draft, "Qo'shiq nomini yozing: <i>Ijrochi - Qo'shiq nomi</i>", RENAME_STEP)
        return None
    try:
        section = MusicCategory(choice)
    except ValueError:
        return None
    # A second tap while the song downloads must not list it twice.
    if not await get_redis().set(f"movbot:busy:{draft['id']}", "1", nx=True, ex=300):
        return "Yuklanmoqda, biroz kuting…"
    try:
        return await _publish(db, draft, section)
    finally:
        await get_redis().delete(f"movbot:busy:{draft['id']}")


async def _publish(db: AsyncSession, draft: dict[str, Any], section: MusicCategory) -> str | None:
    try:
        name, size = await save_audio_bytes(await tg.download(str(draft["file"]), _limit(), bot_token=bot.bot_token()))
    except tg.TelegramError as error:
        bot.log.warning("content bot could not download a song: %s", error)
        return "Faylni yuklab bo'lmadi. Qo'shiqni qaytadan yuboring."
    except ApiError:
        return "Bu MP3 yoki M4A fayl emas. Qo'shiqni MP3 yoki M4A qilib yuboring."
    track = MusicTrack(category=section.value, title=draft["title"], artist=draft["artist"], audio=name, size_bytes=size,
                       duration_seconds=draft["dur"])
    db.add(track)
    await db.flush()
    audit(db, f"telegram:{draft['u']}", "music_uploaded", str(track.id), title=track.title, category=track.category, size=size, via="bot")
    await db.commit()
    await bot._drop(draft)
    await bot._show(draft, f"✅ Qo'shildi: <b>{_label(draft)}</b>\nIlovada «Musiqa» → «{SECTIONS[section]}» bo'limida ko'rinadi.", [])
    return None
