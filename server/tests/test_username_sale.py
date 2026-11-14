"""Short (2-4 character) UZARO usernames: priced by the admin, bought for the UZARO balance in the app or the bot."""

import pytest

from app.models import AppSetting
from app.routers.gifts import webhook_secret
from tests.test_gifts import _admin, _link, _top_up, _update, gifts_bot  # noqa: F401 (autouse fixture)

pytestmark = pytest.mark.asyncio(loop_scope="session")


async def _prices(session_factory, **prices: int) -> None:
    async with session_factory() as db:
        for length, price in prices.items():
            db.add(AppSetting(key=f"username_price_{length[1:]}_uzs", value=str(price), updated_by="test"))
        await db.commit()


async def _bot(client, telegram_id: int, text: str) -> str:
    reply = await client.post("/v1/telegram/webhook", json=_update(telegram_id, text),
                              headers={"X-Telegram-Bot-Api-Secret-Token": webhook_secret()})
    assert reply.status_code == 200, reply.text
    return reply.json()["text"]


async def test_public_check_reports_price_and_state(client, session_factory, new_customer):
    await _prices(session_factory, l2=500_000, l3=200_000)
    check = lambda name: client.get("/v1/usernames/check", params={"username": name})  # noqa: E731
    assert (await check("@Ab")).json() == {"username": "ab", "status": "for_sale", "price_uzs": 500_000,
                                           "bot_username": "uzaro_uzbot"}
    assert (await check("abc")).json()["price_uzs"] == 200_000
    assert (await check("abcd")).json()["status"] == "closed"  # no price set for 4 characters
    assert (await check("abcde")).json()["status"] == "free"
    assert (await check("uzaro")).json()["detail"]["code"] == "USERNAME_RESERVED"
    assert (await check("a")).json()["detail"]["code"] == "USERNAME_INVALID"


async def test_buy_in_app_charges_the_balance(client, session_factory, new_customer):
    await _prices(session_factory, l2=50_000, l4=10_000)
    admin = await _admin(session_factory)
    alice, bob = await new_customer(), await new_customer()
    await _link(client, alice, 7301)
    await _link(client, bob, 7302)

    assert (await alice.put("/v1/usernames/me", json={"username": "ab"})).status_code == 402
    assert (await alice.post("/v1/usernames/buy", json={"username": "ab"})).json()["detail"]["code"] == "INSUFFICIENT_BALANCE"
    await _top_up(client, admin, alice, 55_000)
    bought = await alice.post("/v1/usernames/buy", json={"username": "AB"})
    assert bought.status_code == 200, bought.text
    assert (bought.json()["username"], bought.json()["balance_uzs"]) == ("ab", 5_000)
    assert (await bob.get("/v1/usernames/resolve/ab")).json()["telegram_user_id"] == 7301
    # Owning it already costs nothing; others cannot have it; lengths without a price and free names are refused.
    assert (await alice.post("/v1/usernames/buy", json={"username": "ab"})).json()["balance_uzs"] == 5_000
    assert (await alice.put("/v1/usernames/me", json={"username": "ab"})).status_code == 200
    await _top_up(client, admin, bob, 100_000)
    assert (await bob.post("/v1/usernames/buy", json={"username": "ab"})).json()["detail"]["code"] == "USERNAME_TAKEN"
    assert (await bob.post("/v1/usernames/buy", json={"username": "abc"})).json()["detail"]["code"] == "USERNAME_SALE_CLOSED"
    assert (await bob.post("/v1/usernames/buy", json={"username": "abcde"})).json()["detail"]["code"] == "USERNAME_FREE"
    assert (await client.get("/v1/usernames/check", params={"username": "ab"})).json()["status"] == "taken"


async def test_buy_through_the_bot(client, session_factory, new_customer):
    await _prices(session_factory, l3=20_000)
    admin = await _admin(session_factory)
    stranger = await _bot(client, 7400, "/start buy_xyz")
    assert "20 000 so'm" in stranger and "tasdiqlang" in stranger  # not linked: price, then how to link

    buyer = await new_customer()
    await _link(client, buyer, 7401)
    assert "Balans yetarli emas" in await _bot(client, 7401, "/nom @xyz")
    await _top_up(client, admin, buyer, 25_000)
    offer = await _bot(client, 7401, "/start buy_xyz")
    assert "/buy_xyz" in offer
    assert "endi sizniki" in await _bot(client, 7401, "/buy_xyz")
    assert (await buyer.get("/v1/usernames/me")).json()["username"] == "xyz"
    assert (await buyer.get("/v1/wallet")).json()["balance_uzs"] == 5_000
    assert "allaqachon sizniki" in await _bot(client, 7401, "/nom xyz")
    assert "band" in await _bot(client, 7400, "/nom xyz")
    assert "ajratilgan" in await _bot(client, 7401, "/nom adminbot")
    assert "/nom ab" in await _bot(client, 7401, "/nom")
