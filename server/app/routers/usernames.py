"""UZARO usernames: a public @name people find in UZARO search, next to their Telegram username.

Claiming needs a proven Telegram id (the gifts bot link), and a name always resolves through the owner's current
link, so nobody can point a name at someone else's account. Names of 5+ characters are free; 2-4 character names
are sold for the UZARO balance (here, on the website and in the gifts bot; rules in services/username_sale).
"""

import re
from datetime import UTC, datetime, timedelta
from typing import Annotated, Any

from fastapi import APIRouter, Query, Request, status
from pydantic import BaseModel, Field, StringConstraints
from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError

from app.config import get_settings
from app.deps import CustomerDep, DbDep, client_ip, rate_limit
from app.errors import ApiError, conflict, forbidden, not_found
from app.models import TelegramLink, UzaroUsername
from app.routers.gifts import TelegramId, _link
from app.services import username_sale
from app.services.username_sale import UsernameError, normalize

router = APIRouter(prefix="/v1/usernames", tags=["usernames"])

SEARCH_LIMIT = 10
MAX_CONTACT_TTL_SECONDS = 400 * 24 * 3600
_STATUS_OF = {"USERNAME_TAKEN": status.HTTP_409_CONFLICT, "INSUFFICIENT_BALANCE": status.HTTP_409_CONFLICT,
              "USERNAME_SALE_CLOSED": status.HTTP_409_CONFLICT}


def _http(error: UsernameError) -> ApiError:
    return ApiError(_STATUS_OF.get(error.code, status.HTTP_400_BAD_REQUEST), error.code)


def check_name(name: str) -> None:
    """Raises 400 with a code the app can explain: bad shape or reserved."""
    try:
        username_sale.check_name(name)
    except UsernameError as error:
        raise _http(error) from None


def _out(row: UzaroUsername, telegram_user_id: int) -> dict[str, Any]:
    fresh = row.contact_expires_at is not None and row.contact_expires_at > datetime.now(UTC)
    return {
        "username": row.username,
        "telegram_user_id": telegram_user_id,
        "contact_token": row.contact_token if fresh else None,
    }


def _linked() -> Any:
    return select(UzaroUsername, TelegramLink.telegram_user_id).join(
        TelegramLink, TelegramLink.customer_id == UzaroUsername.customer_id
    )


@router.get("/me")
async def my_username(current: CustomerDep, db: DbDep) -> dict[str, Any]:
    row = await db.get(UzaroUsername, current.id)
    linked = await db.get(TelegramLink, current.id) is not None
    return {"username": row.username if row else None, "telegram_linked": linked}


class ClaimIn(BaseModel):
    username: Annotated[str, StringConstraints(strip_whitespace=True, max_length=33)]


@router.put("/me")
async def claim(body: ClaimIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    await rate_limit(f"username:{current.id}", limit=10, window_seconds=3600)
    link = await db.get(TelegramLink, current.id)
    if link is None:
        raise forbidden("TELEGRAM_NOT_LINKED")
    name = normalize(body.username)
    check_name(name)
    taken = await db.scalar(select(UzaroUsername).where(UzaroUsername.username == name))
    if taken is not None and taken.customer_id != current.id:
        raise conflict("USERNAME_TAKEN")
    if taken is None and username_sale.is_paid(name):
        # Short names go through POST /buy; the app shows the price from GET /check and asks first.
        raise ApiError(status.HTTP_402_PAYMENT_REQUIRED, "USERNAME_PAID")
    row = await db.get(UzaroUsername, current.id)
    if row is None:
        row = UzaroUsername(customer_id=current.id, username=name)
        db.add(row)
    row.username = name
    try:
        await db.commit()
    except IntegrityError:  # someone claimed it between the check and the commit
        await db.rollback()
        raise conflict("USERNAME_TAKEN") from None
    return _out(row, link.telegram_user_id)


@router.get("/check")
async def check(
    request: Request, db: DbDep, username: Annotated[str, Query(min_length=1, max_length=33)]
) -> dict[str, Any]:
    """Public (the website asks before sending people to the bot): is the name free, for sale and at what price."""
    await rate_limit(f"username-check:{client_ip(request)}", limit=120, window_seconds=3600)
    try:
        offer = await username_sale.quote(db, username)
    except UsernameError as error:
        raise _http(error) from None
    return {"username": offer.username, "status": offer.status, "price_uzs": offer.price_uzs,
            "bot_username": get_settings().gifts_bot_username or None}


@router.post("/buy")
async def buy(body: ClaimIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    """Buys a 2-4 character name for the UZARO balance; it replaces the customer's current name."""
    await rate_limit(f"username:{current.id}", limit=10, window_seconds=3600)
    link = await _link(db, current.id, lock=True)  # serialises this customer's spending
    try:
        row, balance = await username_sale.buy(db, link, body.username, channel="app")
    except UsernameError as error:
        raise _http(error) from None
    return {**_out(row, link.telegram_user_id), "balance_uzs": balance}


@router.delete("/me", status_code=status.HTTP_204_NO_CONTENT)
async def release(current: CustomerDep, db: DbDep) -> None:
    await db.execute(delete(UzaroUsername).where(UzaroUsername.customer_id == current.id))
    await db.commit()


class ContactIn(BaseModel):
    # The t.me path the owner's GetUserLink returned: "contact/<token>" or, with a Telegram username, that username.
    token: Annotated[str, StringConstraints(strip_whitespace=True, pattern=r"^(contact/)?[A-Za-z0-9_-]{4,64}$")]
    expires_in: Annotated[int, Field(gt=0, le=MAX_CONTACT_TTL_SECONDS)]


@router.put("/me/contact", status_code=status.HTTP_204_NO_CONTENT)
async def set_contact(body: ContactIn, current: CustomerDep, db: DbDep) -> None:
    """The owner's app stores its fresh t.me/contact token so people without shared chats can open the profile."""
    await rate_limit(f"username-contact:{current.id}", limit=30, window_seconds=3600)
    row = await db.get(UzaroUsername, current.id)
    if row is None:
        raise not_found("USERNAME_NOT_SET")
    row.contact_token = body.token
    row.contact_expires_at = datetime.now(UTC) + timedelta(seconds=body.expires_in)
    await db.commit()


@router.get("/resolve/{username}")
async def resolve(username: str, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    await rate_limit(f"username-lookup:{current.id}", limit=300, window_seconds=3600)
    found = (await db.execute(_linked().where(UzaroUsername.username == normalize(username)))).first()
    if found is None:
        raise not_found("USERNAME_NOT_FOUND")
    return _out(*found)


@router.get("/search")
async def search(current: CustomerDep, db: DbDep, q: Annotated[str, Query(min_length=2, max_length=33)]) -> dict[str, Any]:
    await rate_limit(f"username-lookup:{current.id}", limit=300, window_seconds=3600)
    prefix = normalize(q)
    if not re.fullmatch(r"[a-z0-9_]{2,32}", prefix):
        return {"items": []}
    rows = await db.execute(
        _linked().where(UzaroUsername.username.startswith(prefix, autoescape=True)).order_by(UzaroUsername.username).limit(SEARCH_LIMIT)
    )
    return {"items": [_out(row, telegram_id) for row, telegram_id in rows]}


@router.get("/of/{telegram_user_id}")
async def username_of(telegram_user_id: TelegramId, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    """The UZARO name shown on a person's profile, if they have one."""
    await rate_limit(f"username-lookup:{current.id}", limit=300, window_seconds=3600)
    found = (await db.execute(_linked().where(TelegramLink.telegram_user_id == telegram_user_id))).first()
    return {"username": found[0].username if found else None}
