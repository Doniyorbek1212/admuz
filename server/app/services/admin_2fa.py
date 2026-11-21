"""Second factor for admin panel sign-ins: after the right password, @uzaro_uzbot asks the admin in Telegram.

POST /v1/admin/login waits (up to WAIT_SECONDS) until the admin taps "Tasdiqlash" or "Rad etish", then answers as
before, so the web panel and the mobile admin screen keep their request shape. A stolen password alone opens nothing.
Only one request per admin waits at a time, so an attacker with the password cannot flood the admin with prompts.
It fails closed: an admin with a Telegram id is never let in on the password alone when Telegram is unreachable.
"""

import asyncio
import html
import json
import logging
import secrets
from datetime import UTC, datetime, timedelta
from typing import Any

from app.config import get_settings
from app.deps import get_redis
from app.errors import conflict, unauthorized, unavailable
from app.services import telegram_api as tg

log = logging.getLogger("app.admin_2fa")

WAIT_SECONDS = 90
POLL_SECONDS = 1.0
PREFIX = "a2:"  # callback data: a2:<request id>:ok|no


def _key(request_id: str) -> str:
    return f"admin2fa:req:{request_id}"


async def _api(method: str, **params: Any) -> Any:
    return await tg.call(method, bot_token=get_settings().gifts_bot_token, **params)


def _prompt(name: str, ip: str) -> str:
    tashkent = datetime.now(UTC) + timedelta(hours=5)
    return (
        "🔐 <b>UZARO admin panelga kirish so'raldi</b>\n\n"
        f"Admin: <b>{html.escape(name)}</b>\nIP: <code>{html.escape(ip)}</code>\nVaqt: {tashkent:%d.%m.%Y %H:%M}\n\n"
        "Hozir o'zingiz kirayotgan bo'lsangiz, tasdiqlang. Siz bo'lmasangiz, rad eting va parolni darhol almashtiring."
    )


async def confirm(admin_id: str, name: str, telegram_id: int, ip: str) -> None:
    """Asks in Telegram and waits for the answer; returns when approved, raises otherwise."""
    if not get_settings().gifts_bot_token:
        raise unavailable("TWO_FACTOR_UNAVAILABLE")
    redis = get_redis()
    if not await redis.set(f"admin2fa:wait:{admin_id}", "1", ex=WAIT_SECONDS + 5, nx=True):
        raise conflict("LOGIN_PENDING")
    request_id = secrets.token_urlsafe(12)
    try:
        await redis.set(_key(request_id), json.dumps({"t": telegram_id, "s": "pending"}), ex=WAIT_SECONDS + 30)
        buttons = [[{"text": "✅ Tasdiqlash", "callback_data": f"{PREFIX}{request_id}:ok"},
                    {"text": "❌ Rad etish", "callback_data": f"{PREFIX}{request_id}:no"}]]
        try:
            sent = await _api("sendMessage", chat_id=telegram_id, text=_prompt(name, ip), parse_mode="HTML",
                              reply_markup={"inline_keyboard": buttons})
        except tg.TelegramError as error:
            log.warning("admin 2fa prompt not sent: %s", error)
            raise unavailable("TWO_FACTOR_UNAVAILABLE") from None
        state = await _wait(request_id)
        if state != "ok":
            if state == "pending":  # nobody answered: the buttons must not approve a later attempt
                await _edit(telegram_id, sent["message_id"], "⌛ Kirish so'rovi muddati o'tdi.")
            raise unauthorized("LOGIN_DENIED" if state == "no" else "LOGIN_NOT_CONFIRMED")
    finally:
        await redis.delete(_key(request_id), f"admin2fa:wait:{admin_id}")


async def _wait(request_id: str) -> str:
    redis = get_redis()
    loop = asyncio.get_running_loop()
    deadline = loop.time() + WAIT_SECONDS
    while loop.time() < deadline:
        raw = await redis.get(_key(request_id))
        state = json.loads(raw)["s"] if raw else "no"
        if state != "pending":
            return state
        await asyncio.sleep(POLL_SECONDS)
    return "pending"


async def _edit(chat_id: int, message_id: int, text: str) -> None:
    try:
        await _api("editMessageText", chat_id=chat_id, message_id=message_id, text=text)
    except tg.TelegramError as error:
        log.warning("admin 2fa message not updated: %s", error)


def wants(update: dict[str, Any]) -> bool:
    query = update.get("callback_query")
    return isinstance(query, dict) and str(query.get("data") or "").startswith(PREFIX)


async def handle(update: dict[str, Any]) -> None:
    """A tap on the prompt's buttons; only the Telegram account the prompt was sent to can answer it."""
    query = update["callback_query"]
    request_id, _, answer = str(query.get("data") or "").removeprefix(PREFIX)[:40].partition(":")
    user_id = (query.get("from") or {}).get("id")
    message = query.get("message") or {}
    redis = get_redis()
    raw = await redis.get(_key(request_id))
    entry = json.loads(raw) if raw else None
    alert = None
    if entry is None or entry["s"] != "pending":
        alert = "Bu so'rov eskirgan."
    elif entry["t"] != user_id or answer not in ("ok", "no"):
        alert = "Bu so'rov sizga tegishli emas."
    else:
        await redis.set(_key(request_id), json.dumps({**entry, "s": answer}), keepttl=True)
        text = "✅ Kirish tasdiqlandi." if answer == "ok" else "❌ Kirish rad etildi. Parolni almashtiring: admin panel → Adminlar."
        if isinstance(message.get("message_id"), int):
            await _edit(user_id, message["message_id"], text)
    try:
        await _api("answerCallbackQuery", callback_query_id=query.get("id"), text=alert, show_alert=bool(alert))
    except tg.TelegramError as error:
        log.warning("admin 2fa callback not answered: %s", error)
