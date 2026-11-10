"""UZARO balance in so'm: an append-only ledger (WalletEntry); the balance is the sum of its deltas.

Callers that spend must serialise per customer (the gifts router locks the sender's TelegramLink row) and
check the balance inside the same transaction.
"""

import uuid

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import WalletEntry


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
