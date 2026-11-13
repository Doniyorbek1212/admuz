"""UZARO balance in so'm: an append-only ledger (WalletEntry); the balance is the sum of its deltas.

Callers that spend must serialise per customer (the gifts router locks the sender's TelegramLink row) and
check the balance inside the same transaction.
"""

import uuid
from typing import Any, Literal

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import GiftItem, SentGift, WalletEntry

Direction = Literal["all", "in", "out"]


async def balance(db: AsyncSession, customer_id: uuid.UUID) -> int:
    total = await db.scalar(select(func.coalesce(func.sum(WalletEntry.delta_uzs), 0)).where(WalletEntry.customer_id == customer_id))
    return int(total or 0)


async def record(db: AsyncSession, customer_id: uuid.UUID, delta_uzs: int, kind: str, reference: str) -> bool:
    """Adds one ledger line; returns False (and changes nothing) if (kind, reference) was already applied."""
    exists = await db.scalar(
        select(WalletEntry.id).where(
            WalletEntry.customer_id == customer_id, WalletEntry.kind == kind, WalletEntry.reference == reference
        )
    )
    if exists is not None:
        return False
    db.add(WalletEntry(customer_id=customer_id, delta_uzs=delta_uzs, kind=kind, reference=reference))
    return True


async def history(
    db: AsyncSession, customer_id: uuid.UUID, *, offset: int = 0, limit: int = 30, direction: Direction = "all"
) -> tuple[list[dict[str, Any]], bool]:
    """Ledger lines newest first, each with what it was (gift name and recipient, @name, top-up method); and whether
    more follow."""
    stmt = select(WalletEntry).where(WalletEntry.customer_id == customer_id)
    if direction == "in":
        stmt = stmt.where(WalletEntry.delta_uzs > 0)
    elif direction == "out":
        stmt = stmt.where(WalletEntry.delta_uzs < 0)
    rows = list(await db.scalars(stmt.order_by(WalletEntry.created_at.desc(), WalletEntry.id).offset(offset).limit(limit + 1)))
    more = len(rows) > limit
    entries = rows[:limit]
    gifts = await _gifts_by_reference(db, [e.reference for e in entries if e.kind == "gift"])
    return [_entry_out(e, gifts.get(e.reference)) for e in entries], more


async def _gifts_by_reference(db: AsyncSession, references: list[str]) -> dict[str, tuple[SentGift, GiftItem]]:
    ids = []
    for reference in references:
        try:
            ids.append(uuid.UUID(reference))
        except ValueError:
            continue
    if not ids:
        return {}
    rows = await db.execute(select(SentGift, GiftItem).join(GiftItem, GiftItem.id == SentGift.gift_id).where(SentGift.id.in_(ids)))
    return {str(sent.id): (sent, gift) for sent, gift in rows.all()}


def _entry_out(entry: WalletEntry, gift: tuple[SentGift, GiftItem] | None) -> dict[str, Any]:
    out: dict[str, Any] = {
        "delta_uzs": entry.delta_uzs,
        "kind": entry.kind,
        "created_at": entry.created_at.isoformat(),
        "title": None,
        "method": None,
        "recipient_id": None,
        "to_self": False,
    }
    if entry.kind in ("topup", "refund"):
        out["method"] = "payme" if entry.reference.startswith("payme:") else "card"
    elif entry.kind == "username":
        out["title"] = entry.reference.split(":", 1)[0]
    elif gift is not None:
        sent, item = gift
        out["title"] = item.title
        out["titles"] = {"uz": item.title, "ru": item.title_ru or item.title, "en": item.title_en or item.title}
        out["recipient_id"] = sent.recipient_telegram_id
        out["to_self"] = sent.recipient_telegram_id == sent.sender_telegram_id
    return out
