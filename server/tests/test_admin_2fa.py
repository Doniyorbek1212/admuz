"""Admin sign-in confirmed in Telegram: approve, deny, a stranger's tap, timeout, one prompt at a time, fail closed."""

import asyncio

import pytest
from sqlalchemy import select

from app.config import get_settings
from app.models import AdminRole, AdminUser
from app.routers.gifts import webhook_secret
from app.security import hash_password, new_secret, sha256_hex
from app.services import admin_2fa, telegram_api

pytestmark = pytest.mark.asyncio(loop_scope="session")

OWNER_TG = 860_000_777
GOOD = {"login": "boss-login", "password": "Sado-Admin-2026"}


@pytest.fixture(autouse=True)
def bot(monkeypatch):
    monkeypatch.setattr(get_settings(), "gifts_bot_token", "7:gifts-token")
    monkeypatch.setattr(admin_2fa, "WAIT_SECONDS", 3)
    monkeypatch.setattr(admin_2fa, "POLL_SECONDS", 0.05)
    calls: list[tuple[str, dict]] = []

    async def fake_call(method: str, *, bot_token=None, **params):
        assert bot_token == "7:gifts-token"
        calls.append((method, params))
        return {"message_id": 900}

    monkeypatch.setattr(telegram_api, "call", fake_call)
    return calls


async def _owner(session_factory, telegram_id: int | None = OWNER_TG) -> None:
    async with session_factory() as db:
        db.add(AdminUser(name="boss", key_hash=sha256_hex(new_secret()), role=AdminRole.OWNER, login=GOOD["login"],
                         password_hash=hash_password(GOOD["password"]), telegram_user_id=telegram_id))
        await db.commit()


async def _prompt(bot) -> str:
    """Waits for the Telegram prompt and returns its request id."""
    for _ in range(100):
        sent = [p for m, p in bot if m == "sendMessage"]
        if sent:
            assert sent[-1]["chat_id"] == OWNER_TG and "IP:" in sent[-1]["text"]
            return sent[-1]["reply_markup"]["inline_keyboard"][0][0]["callback_data"].split(":")[1]
        await asyncio.sleep(0.02)
    raise AssertionError("no prompt sent")


async def _tap(client, request_id: str, answer: str, user_id: int = OWNER_TG):
    update = {"update_id": 1, "callback_query": {"id": "cb", "from": {"id": user_id}, "data": f"a2:{request_id}:{answer}",
                                                 "message": {"message_id": 900}}}
    return await client.post("/v1/telegram/webhook", json=update, headers={"X-Telegram-Bot-Api-Secret-Token": webhook_secret()})


async def test_sign_in_waits_for_the_telegram_tap(client, bot, session_factory):
    await _owner(session_factory)
    login = asyncio.create_task(client.post("/v1/admin/login", json=GOOD))
    request_id = await _prompt(bot)
    await _tap(client, request_id, "ok", user_id=12345)  # someone else's account cannot approve
    assert not login.done()
    assert [p for m, p in bot if m == "answerCallbackQuery"][-1]["text"] == "Bu so'rov sizga tegishli emas."
    await _tap(client, request_id, "ok")
    resp = await login
    assert resp.status_code == 200, resp.text
    me = await client.get("/v1/admin/me", headers={"X-Admin-Key": resp.json()["token"]})
    assert me.json() == {"name": "boss", "role": "owner"}
    await _tap(client, request_id, "ok")  # a spent prompt approves nothing
    assert [p for m, p in bot if m == "answerCallbackQuery"][-1]["text"] == "Bu so'rov eskirgan."


async def test_denied_or_unanswered_sign_in_gets_no_session(client, bot, session_factory):
    await _owner(session_factory)
    login = asyncio.create_task(client.post("/v1/admin/login", json=GOOD))
    await _tap(client, await _prompt(bot), "no")
    denied = await login
    assert (denied.status_code, denied.json()["detail"]["code"]) == (401, "LOGIN_DENIED") and "token" not in denied.text

    bot.clear()
    unanswered = await client.post("/v1/admin/login", json=GOOD)  # nobody taps within WAIT_SECONDS
    assert unanswered.json()["detail"]["code"] == "LOGIN_NOT_CONFIRMED"
    assert any(m == "editMessageText" and "muddati" in p["text"] for m, p in bot)


async def test_one_prompt_at_a_time_and_wrong_password_sends_none(client, bot, session_factory):
    await _owner(session_factory)
    assert (await client.post("/v1/admin/login", json={**GOOD, "password": "wrong-password"})).status_code == 401
    assert not bot  # no prompt before the password is right
    first = asyncio.create_task(client.post("/v1/admin/login", json=GOOD))
    request_id = await _prompt(bot)
    second = await client.post("/v1/admin/login", json=GOOD)
    assert (second.status_code, second.json()["detail"]["code"]) == (409, "LOGIN_PENDING")
    await _tap(client, request_id, "ok")
    assert (await first).status_code == 200


async def test_fails_closed_when_telegram_is_unreachable_and_admins_without_it_use_the_password(client, bot, session_factory, monkeypatch):
    await _owner(session_factory)

    async def down(method, *, bot_token=None, **params):
        raise telegram_api.TelegramError(f"{method}: ConnectError")

    monkeypatch.setattr(telegram_api, "call", down)
    resp = await client.post("/v1/admin/login", json=GOOD)
    assert (resp.status_code, resp.json()["detail"]["code"]) == (503, "TWO_FACTOR_UNAVAILABLE")

    async with session_factory() as db:
        (await db.scalar(select(AdminUser).where(AdminUser.name == "boss"))).telegram_user_id = None
        await db.commit()
    assert (await client.post("/v1/admin/login", json=GOOD)).status_code == 200
