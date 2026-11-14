"""Store wallet top-up: a verified Play or App Store purchase credits its pack once, only to the buyer."""

import pytest

from app.config import get_settings
from app.services import app_store, google_play
from app.services.app_store import AppStoreError, AppStorePurchase
from app.services.google_play import ProductPurchase

pytestmark = pytest.mark.asyncio(loop_scope="session")

PLAY_URL = "/v1/wallet/google-play"
APPLE_URL = "/v1/wallet/app-store"
TOKEN = "purchase-token-123456"
SIGNED = "header.payload.signature"


@pytest.fixture
def play(monkeypatch):
    settings = get_settings()
    monkeypatch.setattr(settings, "google_package_name", "uz.uzaro.app")
    monkeypatch.setattr(settings, "google_service_account_file", "/nonexistent/key.json")
    state = {"purchase": None, "consumed": []}

    async def get_purchase(product_id: str, token: str) -> ProductPurchase:
        return state["purchase"]

    async def consume(product_id: str, token: str) -> None:
        state["consumed"].append((product_id, token))

    monkeypatch.setattr(google_play, "get_purchase", get_purchase)
    monkeypatch.setattr(google_play, "consume", consume)
    return state


@pytest.fixture
def apple(monkeypatch):
    settings = get_settings()
    monkeypatch.setattr(settings, "apple_bundle_id", "uz.uzaro.app")
    monkeypatch.setattr(settings, "apple_app_id", 1234567890)
    state: dict = {"purchase": None}

    def verify(signed: str) -> AppStorePurchase:
        if isinstance(state["purchase"], Exception):
            raise state["purchase"]
        return state["purchase"]

    monkeypatch.setattr(app_store, "verify", verify)
    return state


def _play(account: str, *, state: int = google_play.PURCHASED, is_test: bool = False, order: str = "GPA.1") -> ProductPurchase:
    return ProductPurchase(order_id=order, state=state, consumed=False, account_id=account, quantity=1, is_test=is_test)


def _apple(account: str, *, product: str = "uzaro_topup_1000000", revoked: bool = False, is_test: bool = False) -> AppStorePurchase:
    return AppStorePurchase(
        transaction_id="2000000123", product_id=product, account_id=account, quantity=1, revoked=revoked, is_test=is_test
    )


async def _buy(customer, product: str = "uzaro_topup_50000"):
    return await customer.post(PLAY_URL, json={"product_id": product, "purchase_token": TOKEN})


async def test_packs_list_the_eight_amounts_and_the_account(play, new_customer):
    customer = await new_customer()
    body = (await customer.get("/v1/wallet/store-packs")).json()
    assert body["google_play"] is True
    assert body["account"] == customer.account_token
    assert [p["amount_uzs"] for p in body["products"]] == [5_000, 50_000, 100_000, 250_000, 400_000, 1_000_000, 5_000_000, 12_000_000]


async def test_play_purchase_credits_once_and_is_consumed(play, new_customer):
    customer = await new_customer()
    play["purchase"] = _play(customer.account_token)

    first = await _buy(customer)
    assert first.status_code == 200, first.text
    assert first.json() == {"state": "credited", "amount_uzs": 50_000, "balance_uzs": 50_000}
    again = (await _buy(customer)).json()
    assert again["state"] == "already_credited" and again["balance_uzs"] == 50_000
    assert play["consumed"][0] == ("uzaro_topup_50000", TOKEN)

    history = (await customer.get("/v1/wallet/history")).json()["items"]
    assert history[0]["method"] == "google_play" and history[0]["delta_uzs"] == 50_000


async def test_another_accounts_purchase_is_refused(play, new_customer):
    buyer, other = await new_customer(), await new_customer()
    play["purchase"] = _play(buyer.account_token)
    response = await _buy(other)
    assert response.status_code == 403 and response.json()["detail"]["code"] == "PURCHASE_OTHER_ACCOUNT"
    assert (await other.get("/v1/wallet")).json()["balance_uzs"] == 0


async def test_pending_credits_nothing_and_test_purchases_need_the_switch(play, new_customer, monkeypatch):
    customer = await new_customer()
    play["purchase"] = _play(customer.account_token, state=google_play.PENDING)
    assert (await _buy(customer)).json()["state"] == "pending"

    play["purchase"] = _play(customer.account_token, is_test=True, order="GPA.test")
    assert (await _buy(customer)).status_code == 403
    monkeypatch.setattr(get_settings(), "store_test_purchases", True)
    assert (await _buy(customer)).json()["state"] == "credited"


async def test_unknown_product_and_unconfigured_server(play, new_customer, monkeypatch):
    customer = await new_customer()
    assert (await _buy(customer, "uzaro_topup_7")).status_code == 400
    monkeypatch.setattr(get_settings(), "google_package_name", "")
    assert (await _buy(customer)).status_code == 503


async def test_app_store_transaction_credits_once_for_its_buyer(apple, new_customer):
    buyer, other = await new_customer("ios"), await new_customer("ios")
    apple["purchase"] = _apple(buyer.account_token)

    assert (await other.post(APPLE_URL, json={"signed_transaction": SIGNED})).status_code == 403
    first = (await buyer.post(APPLE_URL, json={"signed_transaction": SIGNED})).json()
    assert first == {"state": "credited", "amount_uzs": 1_000_000, "balance_uzs": 1_000_000}
    assert (await buyer.post(APPLE_URL, json={"signed_transaction": SIGNED})).json()["state"] == "already_credited"
    assert (await buyer.get("/v1/wallet/history")).json()["items"][0]["method"] == "app_store"


async def test_app_store_refuses_bad_revoked_unknown_and_sandbox(apple, new_customer):
    customer = await new_customer("ios")
    post = lambda: customer.post(APPLE_URL, json={"signed_transaction": SIGNED})  # noqa: E731

    apple["purchase"] = AppStoreError("PURCHASE_INVALID")
    assert (await post()).json()["detail"]["code"] == "PURCHASE_INVALID"
    apple["purchase"] = _apple(customer.account_token, revoked=True)
    assert (await post()).json()["detail"]["code"] == "PURCHASE_CANCELLED"
    apple["purchase"] = _apple(customer.account_token, product="uzaro_topup_7")
    assert (await post()).json()["detail"]["code"] == "PRODUCT_UNKNOWN"
    apple["purchase"] = _apple(customer.account_token, is_test=True)
    assert (await post()).json()["detail"]["code"] == "TEST_PURCHASE"
    assert (await customer.get("/v1/wallet")).json()["balance_uzs"] == 0


async def test_sandbox_purchases_are_marked_and_capped_per_account(apple, new_customer, monkeypatch):
    monkeypatch.setattr(get_settings(), "store_test_purchases", True)
    customer = await new_customer("ios")
    apple["purchase"] = _apple(customer.account_token, product="uzaro_topup_400000", is_test=True)
    assert (await customer.post(APPLE_URL, json={"signed_transaction": SIGNED})).json()["state"] == "credited"
    assert (await customer.get("/v1/wallet/history")).json()["items"][0]["method"] == "app_store"

    # 400 000 is under the 500 000 cap, so one more goes through; after that the account is over it.
    apple["purchase"] = AppStorePurchase(
        transaction_id="2000000999", product_id="uzaro_topup_400000", account_id=customer.account_token,
        quantity=1, revoked=False, is_test=True,
    )
    assert (await customer.post(APPLE_URL, json={"signed_transaction": SIGNED})).json()["state"] == "credited"
    apple["purchase"] = AppStorePurchase(
        transaction_id="2000001000", product_id="uzaro_topup_5000", account_id=customer.account_token,
        quantity=1, revoked=False, is_test=True,
    )
    refused = await customer.post(APPLE_URL, json={"signed_transaction": SIGNED})
    assert refused.status_code == 403 and refused.json()["detail"]["code"] == "TEST_PURCHASE_LIMIT"
    assert (await customer.get("/v1/wallet")).json()["balance_uzs"] == 800_000


async def test_real_verifier_rejects_a_forged_transaction(monkeypatch):
    roots = list(app_store.ROOTS_DIR.glob("*.cer"))
    assert [p.name for p in roots] == ["AppleRootCA-G3.cer"]
    monkeypatch.setattr(get_settings(), "apple_bundle_id", "uz.uzaro.app")
    monkeypatch.setattr(get_settings(), "apple_app_id", 1234567890)
    with pytest.raises(AppStoreError):
        app_store.verify("eyJhbGciOiJFUzI1NiJ9.eyJidW5kbGVJZCI6InV6LnV6YXJvLmFwcCJ9.c2ln")
