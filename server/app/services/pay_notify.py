"""Pay bot messages about the balance: money credited (Payme, Stars, TON, an approved receipt) or a receipt rejected.

Only customers with a proven Telegram id get them, and only while the pay bot is configured.
"""

import asyncio
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import TelegramLink
from app.services import telegram_api

# Running background sends; kept so the event loop does not drop them half-way.
_pending: set[asyncio.Task[None]] = set()


def som(amount: int) -> str:
    return f"{amount:,}".replace(",", " ") + " so'm"


async def _chat_of(db: AsyncSession, customer_id: uuid.UUID) -> int | None:
    if not telegram_api.configured():
        return None
    return await db.scalar(select(TelegramLink.telegram_user_id).where(TelegramLink.customer_id == customer_id))


async def credited(db: AsyncSession, customer_id: uuid.UUID, amount_uzs: int, method: str) -> None:
    if (chat := await _chat_of(db, customer_id)) is not None:
        await telegram_api.send_text(chat, f"✅ Hamyoningizga {som(amount_uzs)} tushdi ({method}).")


async def credited_later(db: AsyncSession, customer_id: uuid.UUID, amount_uzs: int, method: str) -> None:
    """Like [credited], but the message is sent in the background (the caller must answer quickly)."""
    if (chat := await _chat_of(db, customer_id)) is None:
        return
    task = asyncio.create_task(telegram_api.send_text(chat, f"✅ Hamyoningizga {som(amount_uzs)} tushdi ({method})."))
    _pending.add(task)
    task.add_done_callback(_pending.discard)


async def rejected(db: AsyncSession, customer_id: uuid.UUID, amount_uzs: int, reason: str) -> None:
    if (chat := await _chat_of(db, customer_id)) is not None:
        await telegram_api.send_text(chat, f"❌ {som(amount_uzs)} uchun chek rad etildi.\nSabab: {reason}")
