"""Webhook of the admins' content bot: videos go to Movies, songs to Music (services/movie_bot.py, music_bot.py)."""

from typing import Annotated

from fastapi import APIRouter, Header, Request

from app.config import get_settings
from app.deps import DbDep
from app.errors import unauthorized
from app.security import constant_time_equals, sha256_hex
from app.services import movie_bot

router = APIRouter(prefix="/v1", tags=["content-bot"])


def webhook_secret() -> str:
    """The secret_token given to setWebhook; Telegram echoes it in X-Telegram-Bot-Api-Secret-Token."""
    return sha256_hex(f"uzaro-content-webhook:{get_settings().content_bot_token}")


@router.post("/telegram/content-webhook", include_in_schema=False)
async def content_webhook(
    request: Request,
    db: DbDep,
    x_telegram_bot_api_secret_token: Annotated[str | None, Header()] = None,
) -> dict[str, bool]:
    if not get_settings().content_bot_token or not constant_time_equals(x_telegram_bot_api_secret_token or "", webhook_secret()):
        raise unauthorized("WEBHOOK_SECRET_INVALID")
    try:
        update = await request.json()
    except ValueError:
        return {"ok": True}
    # Strangers get the "admins only" answer from the bot itself; nothing else is done for them.
    if isinstance(update, dict) and movie_bot.configured():
        await movie_bot.handle(db, update)
    return {"ok": True}
