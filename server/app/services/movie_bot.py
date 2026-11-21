"""The movies bot: an admin sends (or forwards) a video, answers a few button questions, and the bot copies the video
into the public movies channel and lists it in the app's Movies section. On the content bot a song goes to Music
(services/music_bot.py) the same way.

Nothing is downloaded: copyMessage reuses Telegram's own file, so any size Telegram accepts works and the server disk
is never touched. Only Telegram ids in settings.movies_bot_admins may use it. Each video gets its own draft in Redis,
keyed by a short id carried in the buttons, so several videos (a season forwarded at once) can be described side by side.
"""

import html
import json
import logging
import re
import secrets
import uuid
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.deps import get_redis
from app.errors import ApiError
from app.models import MovieKind, MovieTitle, MovieVideo, VideoStatus
from app.services import music_bot
from app.services import telegram_api as tg
from app.services.audit import audit
from app.services.movies import episode_label
from app.uploads import save_public_image_bytes

log = logging.getLogger("app.movie_bot")

DRAFT_TTL_SECONDS = 2 * 24 * 3600
SERIES_BUTTONS = 10
# shortcut: a copy of MOVIE_CATEGORIES in admin_movies.js; move both to one server list if they start to drift.
CATEGORIES = (
    "Jangari", "Komediya", "Drama", "Melodrama", "Tarixiy", "Fantastika", "Sarguzasht", "Detektiv", "Triller", "Qo'rqinchli",
    "Multfilm", "Oilaviy", "Hujjatli", "O'zbek kinolari", "Turk seriallari", "Koreys seriallari", "Hind kinolari", "Rus kinolari",
)
NOT_ALLOWED = "Bu bot faqat UZARO kino adminlari uchun."
EXPIRED = "Bu so'rov eskirgan. Videoni qaytadan yuboring."
HELP = (
    "🎬 Kino yoki serial qismini shu yerga <b>video qilib</b> yuboring yoki forward qiling.\n"
    "Bot bir nechta savol beradi va videoni kanalga joylaydi: u darhol UZARO ilovasining «Kinolar» bo'limida ko'rinadi."
)
HELP_WITH_MUSIC = HELP + "\n\n🎵 Qo'shiq (MP3 yoki M4A) yuborsangiz, bo'limini tanlaysiz va u «Musiqa» bo'limiga qo'shiladi."
NOT_A_VIDEO = (
    "Bu video «fayl» qilib yuborilgan, ilovada ochilmaydi. Uni oddiy video qilib yuboring "
    "(yuborishda «Fayl sifatida» belgisini olib tashlang)."
)
_YEAR = re.compile(r"^(.*?)[\s,]*\(?((?:18|19|20)\d{2})\)?$")
_ANY_YEAR = re.compile(r"(?<!\d)((?:18|19|20)\d{2})(?!\d)")
_SEASON = re.compile(r"(\d{1,3})\s*-?\s*fasl|\bs(\d{1,2})\s*e\d", re.IGNORECASE)
_EPISODE = re.compile(r"(\d{1,4})\s*-?\s*qism|qism\s*(\d{1,4})|\bs\d{1,2}\s*e(\d{1,4})|\bep?(?:isode)?\s*(\d{1,4})\b", re.IGNORECASE)


def bot_token() -> str:
    """The bot admins talk to: the dedicated content bot, else the movies bot (when it is the gifts bot)."""
    settings = get_settings()
    return settings.content_bot_token or settings.movies_bot_token


def configured() -> bool:
    settings = get_settings()
    if not settings.movies_channel:
        return False
    # Without the content bot, the movies bot is the gifts bot (@uzaro_uzbot): it hears admins through the gifts webhook.
    return bool(settings.content_bot_token or (settings.movies_bot_token and settings.movies_bot_token == settings.gifts_bot_token))


def wants(update: dict[str, Any]) -> bool:
    """Whether a gifts-webhook update belongs here: any button press (the gifts bot has none), and an admin's
    messages except slash commands with arguments (/start <code> links accounts, username commands).
    Never once the content bot is on: then admins publish there."""
    if not configured() or get_settings().content_bot_token:
        return False
    if isinstance(update.get("callback_query"), dict):
        return True
    message = update.get("message")
    if not isinstance(message, dict) or (message.get("from") or {}).get("id") not in get_settings().movies_bot_admins:
        return False
    text = str(message.get("text") or "").strip()
    return not text.startswith("/") or text == "/start"


async def _api(method: str, **params: Any) -> Any:
    return await tg.call(method, bot_token=bot_token(), **params)


def _button(text: str, data: str) -> dict[str, str]:
    return {"text": text, "callback_data": data}


def _keyboard(rows: list[list[dict[str, str]]]) -> dict[str, Any]:
    return {"inline_keyboard": [row for row in rows if row]}


async def _say(user_id: int, text: str, **extra: Any) -> None:
    await _api("sendMessage", chat_id=user_id, text=text, parse_mode="HTML", **extra)


# ---- drafts ----


async def _load(draft_id: str) -> dict[str, Any] | None:
    raw = await get_redis().get(f"movbot:d:{draft_id[:16]}")
    return json.loads(raw) if raw else None


async def _save(draft: dict[str, Any]) -> None:
    await get_redis().set(f"movbot:d:{draft['id']}", json.dumps(draft), ex=DRAFT_TTL_SECONDS)


async def _drop(draft: dict[str, Any]) -> None:
    await get_redis().delete(f"movbot:d:{draft['id']}")


async def _expect(draft: dict[str, Any], prompt_id: int | None = None) -> None:
    """Marks the draft as the one waiting for this admin's next text or photo (and for replies to [prompt_id])."""
    redis = get_redis()
    if prompt_id is not None:
        await redis.set(f"movbot:r:{draft['u']}:{prompt_id}", draft["id"], ex=DRAFT_TTL_SECONDS)
    await redis.set(f"movbot:last:{draft['u']}", draft["id"], ex=DRAFT_TTL_SECONDS)


async def _awaited(user_id: int, message: dict[str, Any]) -> dict[str, Any] | None:
    """The draft a text or photo answers: the one whose question it replies to, else the last one asked."""
    redis = get_redis()
    draft_id = None
    if isinstance(reply_id := (message.get("reply_to_message") or {}).get("message_id"), int):
        draft_id = await redis.get(f"movbot:r:{user_id}:{reply_id}")
    draft_id = draft_id or await redis.get(f"movbot:last:{user_id}")
    return await _load(draft_id) if draft_id else None


async def _show(draft: dict[str, Any], text: str, rows: list[list[dict[str, str]]], fresh: bool = False) -> None:
    """Puts a step's question with its buttons on the draft's message, or on a new one when [fresh] (or none yet)."""
    markup = _keyboard(rows)
    if fresh or not draft.get("ui"):
        sent = await _api("sendMessage", chat_id=draft["u"], text=text, parse_mode="HTML", reply_markup=markup)
        draft["ui"] = sent["message_id"]
    else:
        await _api("editMessageText", chat_id=draft["u"], message_id=draft["ui"], text=text, parse_mode="HTML", reply_markup=markup)


async def _ask_text(draft: dict[str, Any], text: str, step: str) -> None:
    draft["step"] = step
    sent = await _api("sendMessage", chat_id=draft["u"], text=text, parse_mode="HTML", reply_markup={"force_reply": True})
    draft["ui"] = None  # the next step's buttons go below the answer
    await _save(draft)
    await _expect(draft, sent["message_id"])


# ---- entry point ----


async def handle(db: AsyncSession, update: dict[str, Any]) -> None:
    """One webhook update. Telegram API failures are logged; the update is never retried."""
    try:
        if isinstance(query := update.get("callback_query"), dict):
            await _callback(db, query)
        elif isinstance(message := update.get("message"), dict):
            await _message(db, message)
    except tg.TelegramError as error:
        log.warning("movies bot update not handled: %s", error)


async def _message(db: AsyncSession, message: dict[str, Any]) -> None:
    sender, chat = message.get("from") or {}, message.get("chat") or {}
    user_id = sender.get("id")
    if not isinstance(user_id, int) or sender.get("is_bot") or chat.get("type") != "private":
        return
    if user_id not in get_settings().movies_bot_admins:
        return await _say(user_id, NOT_ALLOWED)
    music = bool(get_settings().content_bot_token)  # songs only on the dedicated bot, the gifts bot stays movies-only
    if isinstance(video := message.get("video"), dict):
        return await _new_draft(user_id, message, video)
    if str((message.get("document") or {}).get("mime_type") or "").startswith("video/"):
        return await _say(user_id, NOT_A_VIDEO)
    if music and (song := music_bot.song_of(message)):
        return await music_bot.new_draft(user_id, message, song)
    draft = await _awaited(user_id, message)
    text = (message.get("text") or "").strip()
    if draft and draft["step"] == "poster" and message.get("photo"):
        return await _poster_photo(db, draft, message)
    if draft and text and not text.startswith("/"):
        if draft["step"] == "name":
            return await _got_name(db, draft, text)
        if draft["step"] == "episode":
            return await _got_episode_text(db, draft, text)
        if draft["step"] == music_bot.RENAME_STEP:
            return await music_bot.got_name(draft, text)
    await _say(user_id, HELP_WITH_MUSIC if music else HELP)


async def _new_draft(user_id: int, message: dict[str, Any], video: dict[str, Any]) -> None:
    draft = {
        "id": secrets.token_hex(4), "u": user_id, "chat": message["chat"]["id"], "msg": message["message_id"],
        "dur": int(video.get("duration") or 0), "w": int(video.get("width") or 0), "h": int(video.get("height") or 0),
        "size": int(video.get("file_size") or 0), "fname": str(video.get("file_name") or "")[:255],
        "thumb": (video.get("thumbnail") or video.get("thumb") or {}).get("file_id"),
        "hint": f"{video.get('file_name') or ''} {message.get('caption') or ''}"[:500],
        "step": "kind", "kind": None, "title_id": None, "name": "", "year": None, "cats": [], "season": 0, "episode": 0, "ui": None,
    }
    rows = [
        [_button("🎬 Yangi film", f"k:{draft['id']}:movie"), _button("📺 Yangi serial", f"k:{draft['id']}:series")],
        [_button("➕ Serialga yangi qism", f"k:{draft['id']}:ep")],
        [_button("✖ Bekor qilish", f"x:{draft['id']}")],
    ]
    sent = await _api("sendMessage", chat_id=user_id, text="Bu video nima?", reply_markup=_keyboard(rows),
                      reply_parameters={"message_id": draft["msg"], "allow_sending_without_reply": True})
    draft["ui"] = sent["message_id"]
    await _save(draft)


# ---- buttons ----


async def _callback(db: AsyncSession, query: dict[str, Any]) -> None:
    user_id = (query.get("from") or {}).get("id")
    alert = NOT_ALLOWED
    if isinstance(user_id, int) and user_id in get_settings().movies_bot_admins:
        alert = await _route(db, user_id, str(query.get("data") or ""))
    await _api("answerCallbackQuery", callback_query_id=query.get("id"), text=alert, show_alert=bool(alert))


async def _route(db: AsyncSession, user_id: int, data: str) -> str | None:
    """Runs a button ("<step>:<draft id>[:<choice>]"); returns a pop-up text for the admin, or None."""
    kind, _, rest = data.partition(":")
    draft_id, _, choice = rest.partition(":")
    draft = await _load(draft_id)
    if draft is None or draft["u"] != user_id:
        return EXPIRED
    if kind == "x":
        await _show(draft, "✖ Bekor qilindi.", [])
        await _drop(draft)
        return None
    handlers = {"k": _picked_kind, "s": _picked_series, "c": _picked_category, "e": _picked_episode, "p": _skipped_poster,
                "m": music_bot.picked}
    if kind not in handlers:
        return None
    return await handlers[kind](db, draft, choice)


async def _picked_kind(db: AsyncSession, draft: dict[str, Any], choice: str) -> str | None:
    if choice in (MovieKind.MOVIE, MovieKind.SERIES):
        draft["kind"] = choice
        label = "🎬 Yangi film" if choice == MovieKind.MOVIE else "📺 Yangi serial"
        await _show(draft, label, [])
        await _ask_text(draft, f"{label}: nomini yozing.\nYilini ham qo'shsa bo'ladi: <i>Qasoskorlar: Final (2019)</i>", "name")
        return None
    if choice != "ep":
        return None
    series = list(await db.scalars(
        select(MovieTitle).where(MovieTitle.kind == MovieKind.SERIES).order_by(MovieTitle.updated_at.desc()).limit(SERIES_BUTTONS)
    ))
    if not series:
        return "Hali serial yo'q. «Yangi serial» ni tanlang."
    rows = [[_button(t.title[:60], f"s:{draft['id']}:{t.id}")] for t in series] + [[_button("✖ Bekor qilish", f"x:{draft['id']}")]]
    await _show(draft, "Qaysi serialga qism qo'shamiz?", rows)
    await _save(draft)
    return None


async def _picked_series(db: AsyncSession, draft: dict[str, Any], choice: str) -> str | None:
    try:
        title = await db.get(MovieTitle, uuid.UUID(choice))
    except ValueError:
        title = None
    if title is None or title.kind != MovieKind.SERIES:
        return "Bu serial topilmadi."
    draft.update(kind=MovieKind.SERIES.value, title_id=str(title.id), name=title.title)
    await _ask_episode(db, draft)
    return None


async def _picked_category(db: AsyncSession, draft: dict[str, Any], choice: str) -> str | None:
    if choice == "ok":
        if not draft["cats"]:
            return "Kamida bitta kategoriyani belgilang."
        if draft["kind"] == MovieKind.SERIES:
            await _ask_episode(db, draft)
        else:
            await _ask_poster(draft)
        return None
    if choice.isdigit() and int(choice) < len(CATEGORIES):
        name = CATEGORIES[int(choice)]
        draft["cats"] = [c for c in draft["cats"] if c != name] if name in draft["cats"] else [*draft["cats"], name]
        await _show_categories(draft)
    return None


async def _picked_episode(db: AsyncSession, draft: dict[str, Any], choice: str) -> str | None:
    if choice == "type":
        await _show(draft, f"<b>{html.escape(draft['name'])}</b>", [])
        await _ask_text(draft, "Fasl va qism raqamini yozing, masalan: <i>1 5</i> (1-fasl 5-qism).", "episode")
        return None
    season, _, episode = choice.partition(":")
    if not (season.isdigit() and episode.isdigit()):
        return None
    return await _set_episode(db, draft, int(season), int(episode))


async def _skipped_poster(db: AsyncSession, draft: dict[str, Any], choice: str) -> str | None:
    return await _publish(db, draft)


# ---- steps ----


async def _got_name(db: AsyncSession, draft: dict[str, Any], text: str) -> None:
    """The first line is the name; a pasted channel caption's other lines become the description, and its year is kept."""
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    first = lines[0][:200]
    match = _YEAR.match(first)
    name, year = (match.group(1).strip(), int(match.group(2))) if match and match.group(1).strip() else (first, None)
    if year is None and (found := _ANY_YEAR.search(text)):
        year = int(found.group(1))
    draft.update(name=name, year=year, desc="\n".join(lines[1:])[:3000])
    if draft["kind"] == MovieKind.SERIES:
        existing = await db.scalar(select(MovieTitle).where(
            MovieTitle.kind == MovieKind.SERIES, func.lower(MovieTitle.title) == name.lower()
        ).limit(1))
        if existing is not None:  # the series is already listed: this video becomes its next episode
            draft["title_id"] = str(existing.id)
            return await _ask_episode(db, draft)
    await _show_categories(draft)


async def _show_categories(draft: dict[str, Any]) -> None:
    draft["step"] = "cats"
    buttons = [_button(("✅ " if c in draft["cats"] else "") + c, f"c:{draft['id']}:{i}") for i, c in enumerate(CATEGORIES)]
    rows = [buttons[i : i + 2] for i in range(0, len(buttons), 2)] + [[_button("Tayyor ➡", f"c:{draft['id']}:ok")]]
    await _show(draft, f"<b>{html.escape(draft['name'])}</b>: kategoriyalarni belgilang, keyin «Tayyor» ni bosing.", rows)
    await _save(draft)


def _guess(pattern: re.Pattern[str], hint: str) -> int | None:
    match = pattern.search(hint)
    number = next((int(g) for g in match.groups() if g), None) if match else None
    return number if number and number <= 10_000 else None


async def _ask_episode(db: AsyncSession, draft: dict[str, Any]) -> None:
    """Offers the episode the file name suggests, the next one after the last published, and a new season."""
    season, episode = 1, 1
    if draft["title_id"]:
        title_id = uuid.UUID(draft["title_id"])
        season = await db.scalar(select(func.max(MovieVideo.season)).where(MovieVideo.title_id == title_id)) or 1
        last = await db.scalar(select(func.max(MovieVideo.episode)).where(MovieVideo.title_id == title_id, MovieVideo.season == season))
        episode = (last or 0) + 1
    draft["ns"] = season
    options = []
    if guessed := _guess(_EPISODE, draft["hint"]):
        options.append((_guess(_SEASON, draft["hint"]) or season, guessed))
    options += [(season, episode), (season + 1, 1)]
    unique = list(dict.fromkeys(options))
    rows = [[_button(f"{s}-fasl {e}-qism", f"e:{draft['id']}:{s}:{e}")] for s, e in unique]
    rows.append([_button("✏️ Boshqa raqam", f"e:{draft['id']}:type")])
    draft["step"] = "episode"
    await _show(draft, f"<b>{html.escape(draft['name'])}</b>: nechanchi qism?", rows)
    await _save(draft)


async def _got_episode_text(db: AsyncSession, draft: dict[str, Any], text: str) -> None:
    numbers = [int(n) for n in re.findall(r"\d{1,5}", text)[:2]]
    if not numbers:
        return await _say(draft["u"], "Raqam yozing, masalan: <i>1 5</i> (1-fasl 5-qism).")
    season, episode = (numbers[0], numbers[1]) if len(numbers) == 2 else (draft.get("ns") or 1, numbers[0])
    if alert := await _set_episode(db, draft, season, episode):
        await _say(draft["u"], alert)


async def _set_episode(db: AsyncSession, draft: dict[str, Any], season: int, episode: int) -> str | None:
    if not (0 <= season <= 100 and 1 <= episode <= 10_000):
        return "Fasl 0–100, qism 1–10000 oralig'ida bo'lsin."
    draft.update(season=season, episode=episode)
    if draft["title_id"]:
        return await _publish(db, draft)
    await _ask_poster(draft)
    return None


async def _ask_poster(draft: dict[str, Any]) -> None:
    draft["step"] = "poster"
    rows = [[_button("🖼 Videodagi kadrni qo'yish", f"p:{draft['id']}")]]
    await _show(draft, f"<b>{html.escape(draft['name'])}</b>: poster rasmini yuboring (rasm qilib).", rows)
    await _save(draft)
    await _expect(draft)


async def _poster_photo(db: AsyncSession, draft: dict[str, Any], message: dict[str, Any]) -> None:
    file_id = (message.get("photo") or [{}])[-1].get("file_id")
    try:
        draft["poster"] = await save_public_image_bytes(await tg.download(
            str(file_id), get_settings().max_image_bytes, bot_token=bot_token()
        ))
    except (tg.TelegramError, ApiError):
        return await _say(draft["u"], "Rasmni o'qib bo'lmadi. Posterni JPG yoki PNG rasm qilib qayta yuboring.")
    draft["ui"] = None  # the result goes below the photo
    if alert := await _publish(db, draft):
        await _say(draft["u"], alert)


async def _frame_poster(draft: dict[str, Any]) -> str | None:
    """The video's own preview frame, when the admin sends no poster."""
    if not draft.get("thumb"):
        return None
    try:
        return await save_public_image_bytes(await tg.download(
            draft["thumb"], get_settings().max_image_bytes, bot_token=bot_token()
        ))
    except (tg.TelegramError, ApiError):
        return None


# ---- publishing ----


async def _publish(db: AsyncSession, draft: dict[str, Any]) -> str | None:
    """Copies the video to the channel, then lists it; returns a pop-up text when it cannot."""
    channel = get_settings().movies_channel
    title = await db.get(MovieTitle, uuid.UUID(draft["title_id"])) if draft["title_id"] else None
    if draft["title_id"] and title is None:
        await _drop(draft)
        return "Bu serial o'chirilgan. Videoni qaytadan yuboring."
    fresh = title is None
    if title is None:
        title = MovieTitle(kind=MovieKind(draft["kind"]), title=draft["name"], year=draft["year"], description=draft.get("desc", ""),
                           genres=", ".join(draft["cats"])[:200], poster=draft.get("poster") or await _frame_poster(draft))
    video = MovieVideo(season=draft["season"], episode=draft["episode"], name="", status=VideoStatus.READY,
                       original_name=draft["fname"], original_bytes=draft["size"], uploaded_bytes=draft["size"],
                       compressed_bytes=draft["size"], duration_seconds=draft["dur"], width=draft["w"], height=draft["h"], tg_channel=channel)
    caption = episode_label(title, video)
    try:
        copied = await _api("copyMessage", chat_id=f"@{channel}", from_chat_id=draft["chat"], message_id=draft["msg"], caption=caption)
    except tg.TelegramError as error:
        log.warning("movies bot could not post to the channel: %s", error)
        return "Kanalga joylab bo'lmadi: bot kanalda admin ekanini tekshiring yoki videoni qayta yuboring."
    video.tg_message_id = int(copied["message_id"])
    if fresh:
        db.add(title)
        await db.flush()
        audit(db, f"telegram:{draft['u']}", "movie_created", str(title.id), title=title.title, via="bot")
    else:
        title.updated_at = func.now()  # the series moves to the top of the bot's list
    video.title_id = title.id
    db.add(video)
    await db.flush()
    audit(db, f"telegram:{draft['u']}", "movie_video_published", str(video.id), title=title.title, message=video.tg_message_id)
    await db.commit()
    await _drop(draft)
    link = {"text": "Kanalda ko'rish", "url": f"https://t.me/{channel}/{video.tg_message_id}"}
    await _show(draft, f"✅ Joylandi: <b>{html.escape(caption)}</b>\nIlovada «Kinolar» bo'limida ko'rinadi.", [[link]])
    return None
