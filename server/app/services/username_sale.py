"""UZARO username rules and the sale of short names, shared by the app API, the website check and the Telegram bot.

Names of 5+ characters are free. Names of 2-4 characters are sold for the UZARO balance at the price the owner
sets in the admin panel per length; a length without a price (0) is not on sale. Names that impersonate UZARO,
Telegram or bots are never given out.
"""

import re
import uuid
from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import TelegramLink, UzaroUsername
from app.services import wallet
from app.services.audit import audit
from app.services.market_settings import MarketSettings, load_market_settings

NAME_PATTERN = re.compile(r"^[a-z][a-z0-9_]{1,31}$")
FREE_MIN_LENGTH = 5
RESERVED_WORDS = ("uzaro", "sado", "telegram", "admin", "support", "official", "moderator")
RESERVED_NAMES = frozenset({"root", "system", "help", "security", "news", "info", "settings", "null", "undefined"})


class UsernameError(Exception):
    """A rule the name or the purchase breaks; code is the stable error code the clients localize."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def normalize(raw: str) -> str:
    return raw.strip().removeprefix("@").lower()


def check_name(name: str) -> None:
    if not NAME_PATTERN.fullmatch(name) or "__" in name or name.endswith("_"):
        raise UsernameError("USERNAME_INVALID")
    if name in RESERVED_NAMES or name.endswith("bot") or any(word in name for word in RESERVED_WORDS):
        raise UsernameError("USERNAME_RESERVED")


def is_paid(name: str) -> bool:
    return len(name) < FREE_MIN_LENGTH


def price_of(settings: MarketSettings, name: str) -> int:
    """Price in so'm; 0 for free names and for short names whose length is not on sale."""
    return getattr(settings, f"username_price_{len(name)}_uzs", 0) if is_paid(name) else 0


@dataclass(frozen=True)
class Quote:
    username: str
    # free (5+, claim it in the app) | for_sale | closed (short, no price set) | taken | yours
    status: str
    price_uzs: int


async def quote(db: AsyncSession, raw: str, customer_id: uuid.UUID | None = None) -> Quote:
    name = normalize(raw)
    check_name(name)
    owner = await db.scalar(select(UzaroUsername.customer_id).where(UzaroUsername.username == name))
    price = price_of(await load_market_settings(db), name)
    if owner is not None:
        status = "yours" if owner == customer_id else "taken"
    elif not is_paid(name):
        status = "free"
    else:
        status = "for_sale" if price > 0 else "closed"
    return Quote(name, status, price)


async def buy(db: AsyncSession, link: TelegramLink, raw: str, *, channel: str) -> tuple[UzaroUsername, int]:
    """Charges the price to the owner of [link] and gives them the name in place of their current one.

    The caller locks [link] (SELECT ... FOR UPDATE) so one customer's purchases cannot spend the same balance twice.
    Returns the name row and the balance left. Buying a name the customer already owns costs nothing.
    """
    offer = await quote(db, raw, link.customer_id)
    if offer.status == "yours":
        row = await db.get(UzaroUsername, link.customer_id)
        assert row is not None
        return row, await wallet.balance(db, link.customer_id)
    if offer.status == "taken":
        raise UsernameError("USERNAME_TAKEN")
    if offer.status == "free":
        raise UsernameError("USERNAME_FREE")
    if offer.status == "closed":
        raise UsernameError("USERNAME_SALE_CLOSED")
    if await wallet.balance(db, link.customer_id) < offer.price_uzs:
        raise UsernameError("INSUFFICIENT_BALANCE")
    row = await db.get(UzaroUsername, link.customer_id)
    previous = row.username if row else None
    if row is None:
        row = UzaroUsername(customer_id=link.customer_id, username=offer.username)
        db.add(row)
    row.username = offer.username
    # The name alone is not unique over time (it can be released and bought again), so the line gets its own id.
    await wallet.record(db, link.customer_id, -offer.price_uzs, "username", f"{offer.username}:{uuid.uuid4()}")
    audit(db, f"customer:{link.customer_id}", "username_bought", offer.username,
          price_uzs=offer.price_uzs, channel=channel, previous=previous)
    try:
        await db.commit()
    except IntegrityError:  # someone took it between the check and the commit; nothing was charged
        await db.rollback()
        raise UsernameError("USERNAME_TAKEN") from None
    return row, await wallet.balance(db, link.customer_id)
