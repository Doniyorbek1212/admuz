"""UZARO usernames: claim needs a proven Telegram id, names are unique, short/reserved ones are held back."""

import pytest

from app.config import get_settings
from tests.test_gifts import _link

pytestmark = pytest.mark.asyncio(loop_scope="session")


@pytest.fixture(autouse=True)
def gifts_bot(monkeypatch):
    settings = get_settings()
    monkeypatch.setattr(settings, "gifts_bot_token", "123:test-token")
    monkeypatch.setattr(settings, "gifts_bot_username", "uzaro_uzbot")


async def test_claim_resolve_search_and_release(client, new_customer):
    alice, bob = await new_customer(), await new_customer()
    assert (await alice.put("/v1/usernames/me", json={"username": "aliya"})).json()["detail"]["code"] == "TELEGRAM_NOT_LINKED"

    await _link(client, alice, 7001)
    await _link(client, bob, 7002)
    claimed = await alice.put("/v1/usernames/me", json={"username": "@Aliya_Uz"})
    assert claimed.status_code == 200, claimed.text
    assert claimed.json() == {"username": "aliya_uz", "telegram_user_id": 7001, "contact_token": None}
    assert (await bob.put("/v1/usernames/me", json={"username": "ALIYA_UZ"})).json()["detail"]["code"] == "USERNAME_TAKEN"

    assert (await bob.get("/v1/usernames/resolve/aliya_uz")).json()["telegram_user_id"] == 7001
    assert [i["username"] for i in (await bob.get("/v1/usernames/search", params={"q": "ali"})).json()["items"]] == ["aliya_uz"]
    assert (await bob.get("/v1/usernames/of/7001")).json()["username"] == "aliya_uz"

    # The contact token is only handed out while fresh.
    contact = {"token": "contact/AbCdEf123456", "expires_in": 3600}
    assert (await alice.put("/v1/usernames/me/contact", json=contact)).status_code == 204
    assert (await bob.get("/v1/usernames/resolve/aliya_uz")).json()["contact_token"] == "contact/AbCdEf123456"
    bad = {"token": "https://evil.example/x", "expires_in": 3600}
    assert (await alice.put("/v1/usernames/me/contact", json=bad)).status_code == 422

    # Renaming frees the old name; releasing frees the new one.
    assert (await alice.put("/v1/usernames/me", json={"username": "aliya2"})).status_code == 200
    assert (await bob.get("/v1/usernames/resolve/aliya_uz")).status_code == 404
    assert (await alice.delete("/v1/usernames/me")).status_code == 204
    assert (await bob.put("/v1/usernames/me", json={"username": "aliya2"})).status_code == 200


@pytest.mark.parametrize(
    ("name", "code"),
    [
        ("uz", "USERNAME_PAID"),
        ("abcd", "USERNAME_PAID"),
        ("u", "USERNAME_INVALID"),
        ("1abc", "USERNAME_INVALID"),
        ("ab__cd", "USERNAME_INVALID"),
        ("abcd_", "USERNAME_INVALID"),
        ("uzaro_team", "USERNAME_RESERVED"),
        ("shopbot", "USERNAME_RESERVED"),
        ("support", "USERNAME_RESERVED"),
    ],
)
async def test_rejected_names(client, new_customer, name, code):
    customer = await new_customer()
    await _link(client, customer, 7100 + len(name))
    assert (await customer.put("/v1/usernames/me", json={"username": name})).json()["detail"]["code"] == code
