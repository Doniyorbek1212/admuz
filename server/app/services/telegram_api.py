"""Outgoing Bot API calls of the pay bot (@UzaroPay_bot).

Errors never carry the request URL: it holds the bot token, and httpx puts the URL into its exception text.
"""

import logging
from typing import Any

import httpx

from app.config import get_settings

API = "https://api.telegram.org"
TIMEOUT_SECONDS = 15
log = logging.getLogger("app.telegram_api")


class TelegramError(Exception):
    """A failed Bot API call: Telegram's description, or the network error's class name."""


def configured() -> bool:
    settings = get_settings()
    return bool(settings.pay_bot_token and settings.pay_bot_username)


async def call(method: str, **params: Any) -> Any:
    """Calls a Bot API method with JSON parameters (None values dropped) and returns its result."""
    token = get_settings().pay_bot_token
    body = {key: value for key, value in params.items() if value is not None}
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS) as client:
            response = await client.post(f"{API}/bot{token}/{method}", json=body)
        data = response.json()
    except (httpx.HTTPError, ValueError) as error:
        raise TelegramError(f"{method}: {type(error).__name__}") from None
    if not data.get("ok"):
        raise TelegramError(f"{method}: {data.get('description', 'failed')}")
    return data.get("result")


async def download(file_id: str, limit: int) -> bytes:
    """A file a user sent the bot, refused when bigger than [limit] bytes."""
    info = await call("getFile", file_id=file_id)
    if int(info.get("file_size") or 0) > limit or not info.get("file_path"):
        raise TelegramError("getFile: FILE_TOO_LARGE")
    token = get_settings().pay_bot_token
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS) as client:
            response = await client.get(f"{API}/file/bot{token}/{info['file_path']}")
        response.raise_for_status()
    except httpx.HTTPError as error:
        raise TelegramError(f"download: {type(error).__name__}") from None
    if len(response.content) > limit:
        raise TelegramError("download: FILE_TOO_LARGE")
    return response.content


async def send_text(chat_id: int, text: str, **extra: Any) -> None:
    """A best-effort message (notifications): failures are logged, never raised."""
    try:
        await call("sendMessage", chat_id=chat_id, text=text, **extra)
    except TelegramError as error:
        log.warning("pay bot message not sent: %s", error)
