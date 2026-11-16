"""The movies bot: an allowed admin sends a video, answers the buttons, the bot copies it to the channel and the app lists it."""

import pytest
from sqlalchemy import select

from app.config import get_settings
from app.models import MovieKind, MovieTitle, MovieVideo, VideoStatus
from app.routers.gifts import webhook_secret
from app.services import movie_bot, telegram_api

pytestmark = pytest.mark.asyncio(loop_scope="session")

HOOK = "/v1/telegram/webhook"  # the movies bot is the gifts bot
ADMIN = 860_000_001
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64


@pytest.fixture(autouse=True)
def bot(monkeypatch, tmp_path):
    settings = get_settings()
    monkeypatch.setattr(settings, "movies_bot_token", "1:movies-token")
    monkeypatch.setattr(settings, "gifts_bot_token", "1:movies-token")
    monkeypatch.setattr(settings, "movies_channel", "uzaro_kino")
    monkeypatch.setattr(settings, "movies_bot_admins", [ADMIN])
    monkeypatch.setattr(settings, "media_dir", str(tmp_path))
    calls: list[tuple[str, dict]] = []

    async def fake_call(method: str, *, bot_token=None, **params):
        assert bot_token == "1:movies-token"  # never the pay bot's token
        calls.append((method, params))
        return {"message_id": 500 + len(calls)}

    async def fake_download(file_id, limit, *, bot_token=None):
        assert bot_token == "1:movies-token"
        return PNG

    monkeypatch.setattr(telegram_api, "call", fake_call)
    monkeypatch.setattr(telegram_api, "download", fake_download)
    return calls


async def _send(client, update: dict, secret: str | None = None):
    headers = {"X-Telegram-Bot-Api-Secret-Token": secret or webhook_secret()}
    return await client.post(HOOK, json={"update_id": 1, **update}, headers=headers)


def _message(user_id: int = ADMIN, message_id: int = 10, **fields) -> dict:
    return {"message": {"message_id": message_id, "from": {"id": user_id, "is_bot": False},
                        "chat": {"id": user_id, "type": "private"}, **fields}}


def _video(file_name: str = "film.mp4") -> dict:
    return {"file_id": "VID", "duration": 5400, "width": 1280, "height": 720, "file_size": 900_000_000,
            "file_name": file_name, "thumbnail": {"file_id": "THUMB"}}


def _press(data: str, user_id: int = ADMIN) -> dict:
    return {"callback_query": {"id": "cb", "from": {"id": user_id}, "data": data, "message": {"message_id": 9}}}


def _buttons(calls) -> list[dict]:
    markup = [p for m, p in calls if m in ("sendMessage", "editMessageText") and p.get("reply_markup", {}).get("inline_keyboard")][-1]
    return [b for row in markup["reply_markup"]["inline_keyboard"] for b in row]


def _data(calls, label_part: str) -> str:
    return next(b["callback_data"] for b in _buttons(calls) if label_part in b["text"])


def _last_prompt(calls) -> int:
    """The message id fake_call gave the last ForceReply question."""
    index = max(i for i, (m, p) in enumerate(calls) if m == "sendMessage" and p.get("reply_markup") == {"force_reply": True})
    return 500 + index + 1


async def test_wrong_secret_strangers_and_file_videos_are_refused(client, bot):
    assert (await _send(client, _message(text="/start"), secret="wrong")).status_code == 401
    # A stranger's video and an admin's /start <code> stay with the gifts bot (answered in the webhook reply).
    stranger = await _send(client, _message(user_id=42, video=_video()))
    assert "UZARO" in stranger.json()["text"] and not bot
    linking = await _send(client, _message(text="/start abc123"))
    assert linking.json()["method"] == "sendMessage" and not bot
    await _send(client, _message(text="/start"))
    assert "video qilib" in bot[-1][1]["text"]
    await _send(client, _message(document={"file_id": "D", "mime_type": "video/x-matroska"}))
    assert bot[-1][1]["text"] == movie_bot.NOT_A_VIDEO
    await _send(client, _press("k:deadbeef:movie", user_id=42))
    assert bot[-1] == ("answerCallbackQuery", {"callback_query_id": "cb", "text": movie_bot.NOT_ALLOWED, "show_alert": True})


async def test_new_film_is_copied_to_the_channel_and_listed_in_the_app(client, bot, new_customer, session_factory):
    await _send(client, _message(message_id=10, video=_video()))
    await _send(client, _press(_data(bot, "Yangi film")))
    await _send(client, _message(message_id=11, text="Qasoskorlar: Final (2019)", reply_to_message={"message_id": _last_prompt(bot)}))
    await _send(client, _press(_data(bot, "Jangari")))
    await _send(client, _press(_data(bot, "Fantastika")))
    await _send(client, _press(_data(bot, "Tayyor")))
    await _send(client, _message(message_id=12, photo=[{"file_id": "small"}, {"file_id": "big"}]))

    copy = next(p for m, p in bot if m == "copyMessage")
    assert copy == {"chat_id": "@uzaro_kino", "from_chat_id": ADMIN, "message_id": 10, "caption": "Qasoskorlar: Final"}
    async with session_factory() as db:
        title = await db.scalar(select(MovieTitle))
        video = await db.scalar(select(MovieVideo))
    assert (title.kind, title.title, title.year, title.genres) == (MovieKind.MOVIE, "Qasoskorlar: Final", 2019, "Jangari, Fantastika")
    assert title.poster and title.poster.endswith(".png")
    assert video.status == VideoStatus.READY and video.tg_channel == "uzaro_kino" and video.duration_seconds == 5400
    copied_id = 500 + [m for m, _ in bot].index("copyMessage") + 1
    assert video.tg_message_id == copied_id

    customer = await new_customer()
    listed = (await customer.get("/v1/movies")).json()
    assert [t["title"] for t in listed["items"]] == ["Qasoskorlar: Final"]
    detail = (await customer.get(f"/v1/movies/{title.id}")).json()
    assert (detail["videos"][0]["channel"], detail["videos"][0]["message_id"]) == ("uzaro_kino", copied_id)


async def test_episode_is_added_to_an_existing_series_with_the_suggested_number(client, bot, session_factory):
    async with session_factory() as db:
        series = MovieTitle(kind=MovieKind.SERIES, title="Kuzgun", genres="Drama")
        db.add(series)
        await db.flush()
        db.add(MovieVideo(title_id=series.id, season=1, episode=3, status=VideoStatus.READY, tg_channel="uzaro_kino", tg_message_id=3))
        await db.commit()

    await _send(client, _message(message_id=20, video=_video("Kuzgun 7-qism.mp4")))
    await _send(client, _press(_data(bot, "Serialga yangi qism")))
    await _send(client, _press(_data(bot, "Kuzgun")))
    labels = [b["text"] for b in _buttons(bot)]
    assert labels[:3] == ["1-fasl 7-qism", "1-fasl 4-qism", "2-fasl 1-qism"]  # file name, next after the last, new season
    await _send(client, _press(_data(bot, "1-fasl 4-qism")))

    assert next(p for m, p in bot if m == "copyMessage")["caption"] == "Kuzgun · 1-fasl 4-qism"
    async with session_factory() as db:
        episodes = sorted((v.season, v.episode) for v in await db.scalars(select(MovieVideo)))
        titles = list(await db.scalars(select(MovieTitle)))
    assert episodes == [(1, 3), (1, 4)] and len(titles) == 1


async def test_typed_episode_number_and_cancel(client, bot, session_factory):
    await _send(client, _message(message_id=30, video=_video()))
    await _send(client, _press(_data(bot, "Yangi serial")))
    await _send(client, _message(message_id=31, text="Yangi serial", reply_to_message={"message_id": _last_prompt(bot)}))
    await _send(client, _press(_data(bot, "Drama")))
    await _send(client, _press(_data(bot, "Tayyor")))
    await _send(client, _press(_data(bot, "Boshqa raqam")))
    await _send(client, _message(message_id=32, text="2 5", reply_to_message={"message_id": _last_prompt(bot)}))
    await _send(client, _press(_data(bot, "kadrni")))  # no poster: the video's own frame
    async with session_factory() as db:
        video = await db.scalar(select(MovieVideo))
        title = await db.scalar(select(MovieTitle))
    assert (video.season, video.episode, title.kind) == (2, 5, MovieKind.SERIES) and title.poster

    await _send(client, _message(message_id=40, video=_video()))
    cancel = _data(bot, "Bekor")
    await _send(client, _press(cancel))
    await _send(client, _press(cancel))
    assert bot[-1][1]["text"] == movie_bot.EXPIRED
