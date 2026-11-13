"""Payme Merchant API: order + checkout link, auth, the create/perform/cancel flow crediting the balance, statement."""

import base64

import pytest
from sqlalchemy import select

from app.config import get_settings
from app.models import WalletEntry

pytestmark = pytest.mark.asyncio(loop_scope="session")

KEY = "test-payme-key"
URL = "/v1/payments/payme"


@pytest.fixture(autouse=True)
def payme(monkeypatch):
    settings = get_settings()
    monkeypatch.setattr(settings, "payme_merchant_id", "merchant123")
    monkeypatch.setattr(settings, "payme_key", KEY)


def _auth(key: str = KEY) -> dict[str, str]:
    return {"Authorization": "Basic " + base64.b64encode(f"Paycom:{key}".encode()).decode()}


async def _rpc(client, method: str, params: dict, key: str = KEY) -> dict:
    response = await client.post(URL, json={"id": 7, "method": method, "params": params}, headers=_auth(key))
    assert response.status_code == 200
    body = response.json()
    assert body["id"] == 7
    return body


async def _order(customer, amount: int = 10_000) -> dict:
    created = await customer.post("/v1/wallet/payme", json={"amount_uzs": amount})
    assert created.status_code == 201, created.text
    return created.json()


async def test_checkout_link_names_merchant_order_and_tiyin(new_customer):
    customer = await new_customer()
    order = await _order(customer, 25_000)
    encoded = order["checkout_url"].rsplit("/", 1)[1]
    params = base64.b64decode(encoded).decode()
    assert f"m=merchant123;ac.order_id={order['order_id']};a=2500000" in params
    assert (await customer.post("/v1/wallet/payme", json={"amount_uzs": 10})).status_code == 422
    assert (await customer.get("/v1/wallet")).json()["payme"] is True


async def test_wrong_key_and_unknown_method(client, new_customer):
    order = await _order(await new_customer())
    account = {"amount": 1_000_000, "account": {"order_id": order["order_id"]}}
    assert (await _rpc(client, "CheckPerformTransaction", account, key="wrong"))["error"]["code"] == -32504
    assert (await client.post(URL, json={"id": 7, "method": "X", "params": {}})).json()["error"]["code"] == -32504
    assert (await _rpc(client, "ChangePassword", {"password": "x"}))["error"]["code"] == -32601


async def test_full_payment_credits_balance_once(client, new_customer):
    customer = await new_customer()
    order = await _order(customer, 10_000)
    account = {"order_id": order["order_id"]}

    assert (await _rpc(client, "CheckPerformTransaction", {"amount": 999, "account": account}))["error"]["code"] == -31001
    missing = {"amount": 1_000_000, "account": {"order_id": "00000000-0000-0000-0000-000000000000"}}
    assert (await _rpc(client, "CheckPerformTransaction", missing))["error"]["code"] == -31050
    assert (await _rpc(client, "CheckPerformTransaction", {"amount": 1_000_000, "account": account}))["result"] == {"allow": True}

    create = {"id": "tx-1", "time": 1_700_000_000_000, "amount": 1_000_000, "account": account}
    created = (await _rpc(client, "CreateTransaction", create))["result"]
    assert created["state"] == 1
    # Same transaction again: the same answer. Another transaction for the same order: busy.
    assert (await _rpc(client, "CreateTransaction", create))["result"] == created
    other = {**create, "id": "tx-2"}
    assert (await _rpc(client, "CreateTransaction", other))["error"]["code"] == -31051

    performed = (await _rpc(client, "PerformTransaction", {"id": "tx-1"}))["result"]
    assert performed["state"] == 2 and performed["perform_time"] > 0
    assert (await _rpc(client, "PerformTransaction", {"id": "tx-1"}))["result"] == performed  # no second credit
    wallet = (await customer.get("/v1/wallet")).json()
    assert wallet["balance_uzs"] == 10_000
    assert [(e["kind"], e["delta_uzs"]) for e in wallet["entries"]] == [("topup", 10_000)]

    checked = (await _rpc(client, "CheckTransaction", {"id": "tx-1"}))["result"]
    assert (checked["state"], checked["transaction"]) == (2, order["order_id"])
    assert (await _rpc(client, "CheckTransaction", {"id": "nope"}))["error"]["code"] == -31003

    statement = (await _rpc(client, "GetStatement", {"from": 1_699_999_999_000, "to": 1_700_000_001_000}))["result"]
    assert [t["id"] for t in statement["transactions"]] == ["tx-1"]
    assert statement["transactions"][0]["amount"] == 1_000_000

    # A refund after performing takes the money back off the balance.
    cancelled = (await _rpc(client, "CancelTransaction", {"id": "tx-1", "reason": 5}))["result"]
    assert cancelled["state"] == -2
    assert (await customer.get("/v1/wallet")).json()["balance_uzs"] == 0


async def test_cancel_before_perform_and_spent_money_cannot_be_refunded(client, new_customer, session_factory):
    customer = await new_customer()
    first = await _order(customer, 5_000)
    create = {"id": "tx-c1", "time": 1_700_000_100_000, "amount": 500_000, "account": {"order_id": first["order_id"]}}
    await _rpc(client, "CreateTransaction", create)
    cancelled = (await _rpc(client, "CancelTransaction", {"id": "tx-c1", "reason": 3}))["result"]
    assert cancelled["state"] == -1
    assert (await _rpc(client, "PerformTransaction", {"id": "tx-c1"}))["error"]["code"] == -31008
    assert (await customer.get("/v1/wallet")).json()["balance_uzs"] == 0

    second = await _order(customer, 5_000)
    create = {"id": "tx-c2", "time": 1_700_000_200_000, "amount": 500_000, "account": {"order_id": second["order_id"]}}
    await _rpc(client, "CreateTransaction", create)
    await _rpc(client, "PerformTransaction", {"id": "tx-c2"})
    # The balance was spent elsewhere: simulated by a manual debit in the ledger.
    async with session_factory() as db:
        entry = await db.scalar(select(WalletEntry).where(WalletEntry.reference == f"payme:{second['order_id']}"))
        db.add(WalletEntry(customer_id=entry.customer_id, delta_uzs=-5_000, kind="gift", reference="spent"))
        await db.commit()
    assert (await _rpc(client, "CancelTransaction", {"id": "tx-c2", "reason": 5}))["error"]["code"] == -31007
