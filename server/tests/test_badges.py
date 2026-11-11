"""UZARO badges: monthly purchase from the balance, extending, changing the emoji, public lookup, expiry."""

from datetime import UTC, datetime, timedelta

import pytest

from app.models import ProfileBadge
from tests.test_gifts import _admin, _link, _top_up, gifts_bot  # noqa: F401  (fixture used by autouse)

pytestmark = pytest.mark.asyncio(loop_scope="session")


async def test_buy_extend_change_and_lookup(client, session_factory, new_customer):
    admin = await _admin(session_factory)
    alice, bob = await new_customer(), await new_customer()

    assert (await alice.post("/v1/badges/buy", json={})).json()["detail"]["code"] == "TELEGRAM_NOT_LINKED"
    await _link(client, alice, 7101)
    await _link(client, bob, 7102)
    me = (await alice.get("/v1/badges/me")).json()
    assert me["badge"] is None and me["price_uzs"] == 15_000 and me["days"] == 30
    assert (await alice.post("/v1/badges/buy", json={})).json()["detail"]["code"] == "INSUFFICIENT_BALANCE"
    assert (await alice.put("/v1/badges/me", json={"emoji_id": 5})).json()["detail"]["code"] == "BADGE_NOT_ACTIVE"

    await _top_up(client, admin, alice, 40_000)
    bought = await alice.post("/v1/badges/buy", json={})
    assert bought.status_code == 200, bought.text
    assert bought.json()["balance_uzs"] == 25_000 and bought.json()["badge"]["emoji_id"] == "0"
    first_expiry = datetime.fromisoformat(bought.json()["badge"]["expires_at"])

    # A second month stacks on the first; the emoji (a custom emoji id beyond 2^53) switches too.
    emoji = 5_368_324_170_671_202_286
    again = (await alice.post("/v1/badges/buy", json={"emoji_id": emoji})).json()
    assert again["balance_uzs"] == 10_000 and again["badge"]["emoji_id"] == str(emoji)
    assert datetime.fromisoformat(again["badge"]["expires_at"]) - first_expiry == timedelta(days=30)

    changed = await alice.put("/v1/badges/me", json={"emoji_id": 0})
    assert changed.json()["badge"]["emoji_id"] == "0"
    assert (await alice.get("/v1/wallet")).json()["balance_uzs"] == 10_000  # changing is free

    seen = (await bob.get("/v1/badges/of", params={"ids": [7101, 7102]})).json()["badges"]
    assert seen == {"7101": "0"}

    # An expired badge disappears everywhere.
    async with session_factory() as db:
        badge = await db.get(ProfileBadge, 7101)
        badge.expires_at = datetime.now(UTC) - timedelta(seconds=1)
        await db.commit()
    assert (await bob.get("/v1/badges/of", params={"ids": [7101]})).json()["badges"] == {}
    assert (await alice.get("/v1/badges/me")).json()["badge"] is None


async def test_lookup_validates_ids(client, new_customer):
    customer = await new_customer()
    assert (await customer.get("/v1/badges/of")).status_code == 422
    assert (await customer.get("/v1/badges/of", params={"ids": list(range(1, 102))})).status_code == 422
    assert (await customer.put("/v1/badges/me", json={"emoji_id": -1})).status_code == 422
