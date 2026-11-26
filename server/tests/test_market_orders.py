"""The market feed and shop orders: prices and stock come from the server, placing takes goods out of the
warehouse, cancelling puts them back, and the seller moves an order only along new → accepted → shipped → delivered."""

import uuid

import pytest

from tests.test_market_ads import SHOP, _admin, _put, _shop, media_dir  # noqa: F401 (autouse fixture)

pytestmark = pytest.mark.asyncio(loop_scope="session")


async def _live_shop(client, session_factory, owner, products: list[dict], **patch) -> tuple[dict, list[dict]]:
    admin = await _admin(session_factory)
    shop = await _shop(owner, **patch)
    made = []
    for product in products:
        resp = await owner.post(f"/v1/market/me/shops/{shop['id']}/products", json=product)
        assert resp.status_code == 201, resp.text
        made.append(resp.json())
    assert (await client.post(f"/v1/admin/shops/{shop['id']}/approve", headers=admin)).status_code == 200
    return shop, made


def _order(shop: dict, *lines: tuple[dict, int], **patch) -> dict:
    return {"shop_id": shop["id"], "items": [{"product_id": p["id"], "quantity": n} for p, n in lines], "delivery": "delivery",
            "name": "Ali Valiyev", "phone": "+998 90 111 22 33", "address": "Andijon, Bobur ko'chasi 5", "comment": ""} | patch


async def test_feed_lists_live_products_with_their_shop_and_sorts(client, session_factory, new_customer):
    owner, buyer = await new_customer(), await new_customer()
    tag = uuid.uuid4().hex[:8]
    shop, (cheap, dear, sale) = await _live_shop(client, session_factory, owner, [
        {"title": f"{tag} arzon", "price_uzs": 10_000, "category": "flowers", "initial_stock": 3},
        {"title": f"{tag} qimmat", "price_uzs": 90_000, "category": "home", "initial_stock": 3},
        {"title": f"{tag} chegirma", "price_uzs": 40_000, "old_price_uzs": 80_000, "category": "flowers", "initial_stock": 3},
    ])
    hidden = await owner.post(f"/v1/market/me/shops/{shop['id']}/products", json={"title": f"{tag} yashirin", "price_uzs": 1, "active": False})
    assert hidden.status_code == 201

    def titles(resp):
        assert resp.status_code == 200, resp.text
        return [p["title"].removeprefix(f"{tag} ") for p in resp.json()]

    feed = lambda **params: buyer.get("/v1/market/feed", params={"region": "Andijon", "q": tag} | params)  # noqa: E731
    assert titles(await feed(sort="cheap")) == ["arzon", "chegirma", "qimmat"]
    assert titles(await feed(sort="expensive")) == ["qimmat", "chegirma", "arzon"]
    assert titles(await feed(sort="discount"))[0] == "chegirma"
    assert titles(await feed(category="flowers", sort="cheap")) == ["arzon", "chegirma"]
    assert titles(await feed(region="Namangan")) == []
    item = (await feed(sort="cheap")).json()[0]
    assert item["shop"] == {"id": shop["id"], "name": SHOP["name"], "logo_url": "", "region": "Andijon"} and "sku" not in item

    # The app's favourites and cart: by id, wherever the shop is.
    by_ids = await buyer.get("/v1/market/feed", params={"ids": [dear["id"], sale["id"], str(uuid.uuid4())]})
    assert sorted(titles(by_ids)) == ["chegirma", "qimmat"]
    assert (await buyer.get("/v1/market/feed")).status_code == 400  # neither a region nor ids

    # A shop under review again drops out of the feed.
    await _put(owner, f"/v1/market/me/shops/{shop['id']}", SHOP | {"name": "Yangi nom"})
    assert titles(await feed()) == []
    assert cheap["id"]


async def test_order_takes_stock_at_the_server_price_and_cancel_puts_it_back(client, session_factory, new_customer):
    owner, buyer, stranger = await new_customer(), await new_customer(), await new_customer()
    shop, (rose, vase) = await _live_shop(client, session_factory, owner, [
        {"title": "Atirgul", "price_uzs": 15_000, "initial_stock": 5},
        {"title": "Guldon", "price_uzs": 40_000, "initial_stock": 1},
    ])
    too_many = await buyer.post("/v1/market/orders", json=_order(shop, (rose, 2), (vase, 2)))
    assert too_many.status_code == 409 and too_many.json()["detail"]["code"] == "STOCK_NOT_ENOUGH"

    placed = await buyer.post("/v1/market/orders", json=_order(shop, (rose, 2), (vase, 1), comment="Kechqurun"))
    assert placed.status_code == 201, placed.text
    order = placed.json()
    assert order["status"] == "new" and order["total_uzs"] == 2 * 15_000 + 40_000
    assert [(i["title"], i["price_uzs"], i["quantity"]) for i in order["items"]] == [("Atirgul", 15_000, 2), ("Guldon", 40_000, 1)]
    assert order["shop"]["name"] == SHOP["name"] and len(order["number"]) == 6

    mine = (await owner.get(f"/v1/market/me/shops/{shop['id']}")).json()["products"]
    assert {p["title"]: p["stock"] for p in mine} == {"Atirgul": 3, "Guldon": 0}
    stats = (await owner.get(f"/v1/market/me/shops/{shop['id']}/stats")).json()
    assert stats["revenue_30d_uzs"] == 70_000 and stats["units_sold_30d"] == 3
    assert (await owner.get("/v1/market/me/shops")).json()["shops"][0]["new_orders"] == 1

    assert [o["id"] for o in (await buyer.get("/v1/market/orders")).json()] == [order["id"]]
    assert (await stranger.get("/v1/market/orders")).json() == []
    assert (await stranger.post(f"/v1/market/orders/{order['id']}/cancel", json={})).status_code == 404

    cancelled = await buyer.post(f"/v1/market/orders/{order['id']}/cancel", json={"reason": "Fikrim o'zgardi"})
    assert cancelled.status_code == 200 and cancelled.json()["status"] == "cancelled"
    mine = (await owner.get(f"/v1/market/me/shops/{shop['id']}")).json()["products"]
    assert {p["title"]: p["stock"] for p in mine} == {"Atirgul": 5, "Guldon": 1}
    assert (await owner.get(f"/v1/market/me/shops/{shop['id']}/stats")).json()["revenue_30d_uzs"] == 0
    assert (await buyer.post(f"/v1/market/orders/{order['id']}/cancel", json={})).status_code == 409


async def test_seller_moves_an_order_along_and_only_their_own(client, session_factory, new_customer):
    owner, buyer, other = await new_customer(), await new_customer(), await new_customer()
    shop, (rose,) = await _live_shop(client, session_factory, owner, [{"title": "Atirgul", "price_uzs": 15_000, "initial_stock": 5}])
    order = (await buyer.post("/v1/market/orders", json=_order(shop, (rose, 1), delivery="pickup", address=""))).json()
    url = f"/v1/market/me/orders/{order['id']}/status"

    active = (await owner.get(f"/v1/market/me/shops/{shop['id']}/orders")).json()
    assert [(o["id"], o["next"]) for o in active] == [(order["id"], ["accepted", "cancelled"])]
    assert (await other.get(f"/v1/market/me/shops/{shop['id']}/orders")).status_code == 404
    assert (await other.post(url, json={"status": "accepted"})).status_code == 404

    assert (await owner.post(url, json={"status": "delivered"})).json()["detail"]["code"] == "ORDER_STATUS_INVALID"
    for step in ("accepted", "shipped", "delivered"):
        resp = await owner.post(url, json={"status": step})
        assert resp.status_code == 200 and resp.json()["status"] == step, resp.text
    assert (await owner.post(url, json={"status": "cancelled", "reason": "x"})).status_code == 409
    assert (await buyer.post(f"/v1/market/orders/{order['id']}/cancel", json={})).status_code == 409
    assert (await owner.get(f"/v1/market/me/shops/{shop['id']}/orders")).json() == []
    assert [o["status"] for o in (await owner.get(f"/v1/market/me/shops/{shop['id']}/orders", params={"state": "done"})).json()] == ["delivered"]

    # A seller's cancel needs a reason and restocks.
    second = (await buyer.post("/v1/market/orders", json=_order(shop, (rose, 2)))).json()
    url = f"/v1/market/me/orders/{second['id']}/status"
    assert (await owner.post(url, json={"status": "cancelled"})).json()["detail"]["code"] == "REASON_REQUIRED"
    cancelled = (await owner.post(url, json={"status": "cancelled", "reason": "Tugab qoldi"})).json()
    assert (cancelled["status"], cancelled["cancel_reason"]) == ("cancelled", "Tugab qoldi")
    assert (await owner.get(f"/v1/market/me/shops/{shop['id']}")).json()["products"][0]["stock"] == 4


@pytest.mark.parametrize("patch", [
    {"items": []},
    {"delivery": "delivery", "address": ""},
    {"phone": "abc"},
    {"name": "A"},
    {"delivery": "drone"},
])
async def test_order_input_is_validated(client, session_factory, new_customer, patch):
    owner, buyer = await new_customer(), await new_customer()
    shop, (rose,) = await _live_shop(client, session_factory, owner, [{"title": "Atirgul", "price_uzs": 15_000, "initial_stock": 5}])
    assert (await buyer.post("/v1/market/orders", json=_order(shop, (rose, 1), **patch))).status_code == 422


async def test_cannot_order_twice_the_same_line_or_from_a_shop_under_review(client, session_factory, new_customer):
    owner, buyer = await new_customer(), await new_customer()
    shop, (rose,) = await _live_shop(client, session_factory, owner, [{"title": "Atirgul", "price_uzs": 15_000, "initial_stock": 5}])
    assert (await buyer.post("/v1/market/orders", json=_order(shop, (rose, 1), (rose, 1)))).status_code == 422
    pending = await _shop(owner)
    assert (await buyer.post("/v1/market/orders", json=_order(pending, (rose, 1)))).json()["detail"]["code"] == "SHOP_NOT_FOUND"
