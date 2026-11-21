"""The admins' content bot: its own webhook, videos still go to Movies, songs go to Music."""

import pytest
from sqlalchemy import select

from app.config import get_settings
from app.models import MovieTitle, MovieVideo, MusicTrack
from app.routers.content_bot import webhook_secret
from app.services import movie_bot, music_bot, telegram_api

pytestmark = pytest.mark.asyncio(loop_scope="session")

HOOK = "/v1/telegram/content-webhook"
ADMIN = 860_000_002
TOKEN = "2:content-token"
MP3 = b"ID3\x04\x00\x00\x00\x00\x00\x00" + b"\x00" * 64


class Calls(list):
    """Bot API calls in order, plus the file ids downloaded."""

    def __init__(self) -> None:
        super().__init__()
        self.downloads: list[str] = []


@pytest.fixture(autouse=True)
def bot(monkeypatch, tmp_path):
    settings = get_settings()
    monkeypatch.setattr(settings, "content_bot_token", TOKEN)
    monkeypatch.setattr(settings, "movies_bot_token", "1:movies-token")
    monkeypatch.setattr(settings, "gifts_bot_token", "1:movies-token")
    monkeypatch.setattr(settings, "movies_channel", "uzaro_kino")
    monkeypatch.setattr(settings, "movies_bot_admins", [ADMIN])
    monkeypatch.setattr(settings, "media_dir", str(tmp_path))
    calls = Calls()
    downloads = calls.downloads

    async def fake_call(method: str, *, bot_token=None, **params):
        assert bot_token == TOKEN  # the bot the admin talks to, never the gifts or pay bot
        calls.append((method, params))
        return {"message_id": 700 + len(calls)}

    async def fake_download(file_id, limit, *, bot_token=None):
        assert bot_token == TOKEN and limit <= music_bot.BOT_API_DOWNLOAD_LIMIT
        downloads.append(file_id)
        return MP3

    monkeypatch.setattr(telegram_api, "call", fake_call)
    monkeypatch.setattr(telegram_api, "download", fake_download)
    return calls


async def _send(client, update: dict, secret: str | None = None, hook: str = HOOK):
    headers = {"X-Telegram-Bot-Api-Secret-Token": secret or webhook_secret()}
    return await client.post(hook, json={"update_id": 1, **update}, headers=headers)


def _message(user_id: int = ADMIN, message_id: int = 10, **fields) -> dict:
    return {"message": {"message_id": message_id, "from": {"id": user_id, "is_bot": False},
                        "chat": {"id": user_id, "type": "private"}, **fields}}


def _press(data: str, user_id: int = ADMIN) -> dict:
    return {"callback_query": {"id": "cb", "from": {"id": user_id}, "data": data, "message": {"message_id": 9}}}


def _data(calls, label_part: str) -> str:
    markup = [p for m, p in calls if m in ("sendMessage", "editMessageText") and p.get("reply_markup", {}).get("inline_keyboard")][-1]
    return next(b["callback_data"] for row in markup["reply_markup"]["inline_keyboard"] for b in row if label_part in b["text"])


def _last_prompt(calls) -> int:
    index = max(i for i, (m, p) in enumerate(calls) if m == "sendMessage" and p.get("reply_markup") == {"force_reply": True})
    return 700 + index + 1


def _song(**fields) -> dict:
    return {"file_id": "SONG", "duration": 215, "file_size": 6_000_000, "mime_type": "audio/mpeg", **fields}


async def test_wrong_secret_and_strangers_are_refused(client, bot):
    assert (await _send(client, _message(text="/start"), secret="wrong")).status_code == 401
    await _send(client, _message(user_id=42, audio=_song()))
    assert bot[-1][1]["text"] == movie_bot.NOT_ALLOWED
    await _send(client, _press("m:deadbeef:uz_new", user_id=42))
    assert bot[-1][1]["text"] == movie_bot.NOT_ALLOWED and not bot.downloads
    await _send(client, _message(text="/start"))
    assert "Musiqa" in bot[-1][1]["text"]


async def test_song_with_tags_is_listed_in_the_chosen_section(client, bot, new_customer, session_factory):
    await _send(client, _message(audio=_song(title="Bahor", performer="Sherali Jo'rayev")))
    assert "Sherali Jo&#x27;rayev — Bahor" in bot[-1][1]["text"]
    press = _data(bot, "O'zbekcha eski")
    await _send(client, _press(press))
    await _send(client, _press(press))  # a second tap finds the draft gone, not a second copy

    async with session_factory() as db:
        tracks = list(await db.scalars(select(MusicTrack)))
    assert [(t.title, t.artist, t.category, t.duration_seconds) for t in tracks] == [("Bahor", "Sherali Jo'rayev", "uz_old", 215)]
    assert tracks[0].audio.endswith(".mp3") and bot.downloads == ["SONG"]
    assert bot[-1][1]["text"] == movie_bot.EXPIRED
    listed = (await (await new_customer()).get("/v1/music", params={"category": "uz_old"})).json()
    assert [t["title"] for t in listed["items"]] == ["Bahor"]


async def test_untagged_file_takes_its_name_and_can_be_renamed(client, bot, session_factory):
    await _send(client, _message(document={"file_id": "SONG", "file_name": "Yulduz_Usmonova - Dunyo.mp3", "mime_type": "audio/mpeg"}))
    assert "Yulduz Usmonova — Dunyo" in bot[-1][1]["text"]
    await _send(client, _press(_data(bot, "Nomini")))
    await _send(client, _message(message_id=11, text="Shahzoda – Yorim", reply_to_message={"message_id": _last_prompt(bot)}))
    await _send(client, _press(_data(bot, "Jahon")))
    async with session_factory() as db:
        track = await db.scalar(select(MusicTrack))
    assert (track.artist, track.title, track.category) == ("Shahzoda", "Yorim", "world")


async def test_too_big_song_is_refused_before_download(client, bot, session_factory):
    await _send(client, _message(audio=_song(file_size=music_bot.BOT_API_DOWNLOAD_LIMIT + 1)))
    assert "juda katta" in bot[-1][1]["text"] and not bot.downloads


async def test_videos_go_to_movies_and_the_gifts_bot_stops_asking(client, bot, session_factory):
    video = {"file_id": "VID", "duration": 60, "width": 1280, "height": 720, "file_size": 9_000_000, "file_name": "f.mp4"}
    await _send(client, _message(message_id=20, video=video))
    await _send(client, _press(_data(bot, "Yangi film")))
    await _send(client, _message(message_id=21, text="Sinov (2024)", reply_to_message={"message_id": _last_prompt(bot)}))
    await _send(client, _press(_data(bot, "Drama")))
    await _send(client, _press(_data(bot, "Tayyor")))
    await _send(client, _press(_data(bot, "kadrni")))
    assert next(p for m, p in bot if m == "copyMessage")["chat_id"] == "@uzaro_kino"
    async with session_factory() as db:
        assert (await db.scalar(select(MovieTitle))).year == 2024 and await db.scalar(select(MovieVideo))

    # The same admin on the gifts bot now gets the gifts bot's own answer, not the movie questions.
    from app.routers.gifts import webhook_secret as gifts_secret
    count = len(bot)
    reply = await _send(client, _message(message_id=30, video=video), secret=gifts_secret(), hook="/v1/telegram/webhook")
    assert reply.json()["method"] == "sendMessage" and len(bot) == count
