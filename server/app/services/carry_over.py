"""A reinstall (or a second phone) registers a new customer. When it proves the same Telegram account through the
gifts bot, everything the person owns moves from the customer that held that account to the new one, so nothing is
stranded: balance and its history, receipts and Payme orders, sent gifts, shops, ads, uploads, the shared profile,
interests and a bought @name. Nothing is deleted; rows the new customer already has a newer copy of stay behind.
Per-install records (devices, daily activity statistics) stay with the install they describe.
"""

import uuid

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import (
    AdCampaign,
    CustomerInterest,
    CustomerProfile,
    MediaUpload,
    PaymeOrder,
    SentGift,
    Shop,
    UzaroUsername,
    WalletEntry,
    WalletTopup,
)
from app.services import wallet


async def carry_over(db: AsyncSession, from_customer: uuid.UUID, to_customer: uuid.UUID) -> int:
    """Moves the person's data to [to_customer]; returns the so'm of balance that came along."""
    moved_uzs = await wallet.balance(db, from_customer)
    for model in (WalletEntry, WalletTopup, PaymeOrder, MediaUpload, AdCampaign):
        await db.execute(update(model).where(model.customer_id == from_customer).values(customer_id=to_customer))
    await db.execute(update(SentGift).where(SentGift.sender_customer_id == from_customer).values(sender_customer_id=to_customer))
    await db.execute(update(Shop).where(Shop.owner_id == from_customer).values(owner_id=to_customer))
    # One row per customer: the new customer keeps its own if it already has one.
    for model in (CustomerProfile, UzaroUsername):
        if await db.get(model, to_customer) is None:
            await db.execute(update(model).where(model.customer_id == from_customer).values(customer_id=to_customer))
    taken = select(CustomerInterest.topic).where(CustomerInterest.customer_id == to_customer)
    await db.execute(
        update(CustomerInterest)
        .where(CustomerInterest.customer_id == from_customer, CustomerInterest.topic.not_in(taken))
        .values(customer_id=to_customer)
    )
    return moved_uzs
