"""Online shops (multi-shop, paid slots, closing, warehouse, accounting), media uploads, hub ads,
customer profiles and their admin review."""

import io
import os
import tempfile

import pytest
from sqlalchemy import select

from app.config import get_settings
from app.models import AdminRole, AdminUser, AuditLog
from app.security import new_secret, sha256_hex

pytestmark = pytest.mark.asyncio(loop_scope="session")

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
MP4 = b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 64

AD = {
    "title": "Chegirma 50%",
    "text": "Faqat shu hafta",
    "media_type": "image",
    "media_url": "https://example.com/banner.jpg",
    "link_url": "https://t.me/example_shop",
    "regions": ["Andijon", "Toshkent"],
    "days": 3,
}

SHOP = {"name": "Andijon Gul", "description": "Gullar", "region": "Andijon", "phone": "+998 90 123 45 67", "telegram": "andijon_gul"}
PRODUCT = {"title": "Atirgul", "price_uzs": 15000, "category": "flowers"}


@pytest.fixture(autouse=True)
def media_dir(monkeypatch):
    with tempfile.TemporaryDirectory() as tmp:
        monkeypatch.setattr(get_settings(), "media_dir", tmp)
        yield tmp


async def _admin(session_factory, role: AdminRole = AdminRole.SUPPORT) -> dict[str, str]:
    key = new_secret()
    async with session_factory() as db:
        db.add(AdminUser(name=f"{role.value}-{key[:6]}", key_hash=sha256_hex(key), role=role))
        await db.commit()
    return {"X-Admin-Key": key}


async def _upload(customer, path: str, data: bytes = PNG, name: str = "file.png"):
    return await customer.post(path, files={"file": (name, io.BytesIO(data), "application/octet-stream")})


async def _shop(customer, **patch) -> dict:
    resp = await customer.post("/v1/market/me/shops", json=SHOP | patch)
    assert resp.status_code == 201, resp.text
    return resp.json()


async def _put(customer, path: str, json: dict):
    return await customer.client.put(path, headers=customer.headers, json=json)


# ------------------------------------------------------------------ ads


async def test_ad_price_is_regions_times_days(new_customer):
    c = await new_customer()
    resp = await c.post("/v1/ads", json=AD)
    assert resp.status_code == 201, resp.text
    ad = resp.json()
    assert ad["status"] == "awaiting_payment"
    assert ad["price_uzs"] == 2 * 3 * get_settings().ad_price_per_region_day_uzs
    assert ad["regions"] == ["Toshkent", "Andijon"]


@pytest.mark.parametrize(
    "patch",
    [
        {"regions": ["Moskva"]},
        {"regions": []},
        {"days": 0},
        {"days": 31},
        {"media_url": "http://example.com/a.jpg"},
        {"media_url": "javascript:alert(1)"},
        {"media_url": "/media/../../etc/passwd"},
        {"link_url": "ftp://example.com"},
        {"media_type": "gif"},
    ],
)
async def test_ad_input_is_validated(new_customer, patch):
    c = await new_customer()
    resp = await c.post("/v1/ads", json=AD | patch)
    assert resp.status_code == 422, resp.text


async def test_ad_shown_only_after_approval_and_only_in_its_regions(new_customer, client, session_factory):
    advertiser, viewer = await new_customer(), await new_customer()
    admin = await _admin(session_factory)
    ad_id = (await advertiser.post("/v1/ads", json=AD)).json()["id"]

    assert (await viewer.get("/v1/ads/active", params={"region": "Andijon"})).json() == []
    resp = await _upload(advertiser, f"/v1/ads/{ad_id}/receipt")
    assert resp.json()["status"] == "pending_review"
    assert (await viewer.get("/v1/ads/active", params={"region": "Andijon"})).json() == []

    pending = (await client.get("/v1/admin/ads", headers=admin)).json()
    assert [a["id"] for a in pending] == [ad_id]
    receipt = await client.get(f"/v1/admin/ads/{ad_id}/receipt", headers=admin)
    assert receipt.status_code == 200 and receipt.content == PNG

    approved = (await client.post(f"/v1/admin/ads/{ad_id}/approve", headers=admin)).json()
    assert approved["status"] == "approved" and approved["ends_at"]

    andijon = (await viewer.get("/v1/ads/active", params={"region": "Andijon"})).json()
    assert [a["id"] for a in andijon] == [ad_id]
    assert "price_uzs" not in andijon[0] and "status" not in andijon[0]
    assert (await viewer.get("/v1/ads/active", params={"region": "Xorazm"})).json() == []

    async with session_factory() as db:
        actions = list(await db.scalars(select(AuditLog.action)))
    assert "ad_approved" in actions


async def test_ad_can_use_own_uploaded_video_only(new_customer):
    owner, other = await new_customer(), await new_customer()
    url = (await _upload(owner, "/v1/media", MP4, "clip.mp4")).json()["url"]
    assert (await owner.post("/v1/ads", json=AD | {"media_type": "video", "media_url": url})).status_code == 201
    assert (await other.post("/v1/ads", json=AD | {"media_type": "video", "media_url": url})).status_code == 400


async def test_rejected_ad_can_be_resubmitted_with_new_receipt(new_customer, client, session_factory):
    c = await new_customer()
    admin = await _admin(session_factory)
    ad_id = (await c.post("/v1/ads", json=AD)).json()["id"]
    await _upload(c, f"/v1/ads/{ad_id}/receipt")
    rejected = await client.post(f"/v1/admin/ads/{ad_id}/reject", headers=admin, json={"reason": "To'lov topilmadi"})
    assert rejected.json()["status"] == "rejected"
    assert (await c.get("/v1/ads/mine")).json()[0]["reject_reason"] == "To'lov topilmadi"
    assert (await _upload(c, f"/v1/ads/{ad_id}/receipt")).json()["status"] == "pending_review"


async def test_receipt_must_be_an_image_and_owned(new_customer):
    owner, other = await new_customer(), await new_customer()
    ad_id = (await owner.post("/v1/ads", json=AD)).json()["id"]
    assert (await _upload(owner, f"/v1/ads/{ad_id}/receipt", b"%PDF-1.4 not an image")).status_code == 400
    assert (await _upload(owner, f"/v1/ads/{ad_id}/receipt", MP4)).status_code == 400
    assert (await _upload(other, f"/v1/ads/{ad_id}/receipt")).status_code == 404


async def test_approved_ad_cannot_be_cancelled_or_reapproved(new_customer, client, session_factory):
    c = await new_customer()
    admin = await _admin(session_factory)
    ad_id = (await c.post("/v1/ads", json=AD)).json()["id"]
    assert (await client.post(f"/v1/admin/ads/{ad_id}/approve", headers=admin)).status_code == 409
    await _upload(c, f"/v1/ads/{ad_id}/receipt")
    await client.post(f"/v1/admin/ads/{ad_id}/approve", headers=admin)
    assert (await c.delete(f"/v1/ads/{ad_id}")).status_code == 409
    assert (await client.post(f"/v1/admin/ads/{ad_id}/approve", headers=admin)).status_code == 409


async def test_viewer_admin_cannot_approve_or_see_users(new_customer, client, session_factory):
    c = await new_customer()
    viewer = await _admin(session_factory, AdminRole.VIEWER)
    ad_id = (await c.post("/v1/ads", json=AD)).json()["id"]
    await _upload(c, f"/v1/ads/{ad_id}/receipt")
    assert (await client.post(f"/v1/admin/ads/{ad_id}/approve", headers=viewer)).status_code == 403
    assert (await client.get(f"/v1/admin/ads/{ad_id}/receipt", headers=viewer)).status_code == 403
    assert (await client.get("/v1/admin/users", headers=viewer)).status_code == 403
    assert (await client.get("/v1/admin/ads")).status_code == 401


# ------------------------------------------------------------------ shops


async def test_shop_goes_live_after_approval_and_edit_needs_review_again(new_customer, client, session_factory):
    owner, buyer = await new_customer(), await new_customer()
    admin = await _admin(session_factory)
    shop = await _shop(owner)
    assert shop["status"] == "pending" and shop["price_uzs"] == 0
    product = await owner.post(f"/v1/market/me/shops/{shop['id']}/products", json=PRODUCT | {"initial_stock": 5})
    assert product.status_code == 201, product.text
    assert product.json()["stock"] == 5

    assert (await buyer.get("/v1/market/shops", params={"region": "Andijon"})).json() == []
    assert (await buyer.get(f"/v1/market/shops/{shop['id']}")).status_code == 404

    await client.post(f"/v1/admin/shops/{shop['id']}/approve", headers=admin)
    listed = (await buyer.get("/v1/market/shops", params={"region": "Andijon"})).json()
    assert [(s["id"], s["product_count"]) for s in listed] == [(shop["id"], 1)]
    detail = (await buyer.get(f"/v1/market/shops/{shop['id']}")).json()
    assert [p["title"] for p in detail["products"]] == ["Atirgul"]
    assert "sku" not in detail["products"][0]
    assert (await buyer.get("/v1/market/shops", params={"region": "Namangan"})).json() == []

    await _put(owner, f"/v1/market/me/shops/{shop['id']}", SHOP | {"name": "Andijon Gullari"})
    assert (await buyer.get("/v1/market/shops", params={"region": "Andijon"})).json() == []


async def test_two_shops_are_free_the_third_needs_a_paid_receipt(new_customer, client, session_factory):
    owner = await new_customer()
    admin = await _admin(session_factory)
    first, second = await _shop(owner), await _shop(owner, name="Ikkinchi")
    assert first["price_uzs"] == second["price_uzs"] == 0
    assert (await owner.get("/v1/market/me/shops")).json()["next_shop_price_uzs"] == get_settings().extra_shop_price_uzs

    third = await _shop(owner, name="Uchinchi")
    assert third["status"] == "awaiting_payment" and third["price_uzs"] == 150_000
    assert (await client.post(f"/v1/admin/shops/{third['id']}/approve", headers=admin)).status_code == 409

    paid = (await _upload(owner, f"/v1/market/me/shops/{third['id']}/receipt")).json()
    assert paid["status"] == "pending" and paid["has_receipt"]
    receipt = await client.get(f"/v1/admin/shops/{third['id']}/receipt", headers=admin)
    assert receipt.content == PNG
    assert (await client.post(f"/v1/admin/shops/{third['id']}/approve", headers=admin)).json()["status"] == "approved"
    # Free shops have nothing to pay.
    assert (await _upload(owner, f"/v1/market/me/shops/{first['id']}/receipt")).status_code == 409


async def test_shop_closes_only_with_admin_approval(new_customer, client, session_factory):
    owner, buyer = await new_customer(), await new_customer()
    admin = await _admin(session_factory)
    shop = await _shop(owner)
    await client.post(f"/v1/admin/shops/{shop['id']}/approve", headers=admin)

    requested = (await owner.post(f"/v1/market/me/shops/{shop['id']}/close-request", json={"reason": "Biznes yopildi"})).json()
    assert requested["close_requested"] is True
    # Still open until an admin decides.
    assert len((await buyer.get("/v1/market/shops", params={"region": "Andijon"})).json()) == 1
    queue = (await client.get("/v1/admin/shops", headers=admin, params={"status": "close_requested"})).json()
    assert [s["id"] for s in queue] == [shop["id"]]

    await client.post(f"/v1/admin/shops/{shop['id']}/keep", headers=admin)
    assert (await owner.get(f"/v1/market/me/shops/{shop['id']}")).json()["close_requested"] is False

    await owner.post(f"/v1/market/me/shops/{shop['id']}/close-request", json={"reason": "Biznes yopildi"})
    assert (await client.post(f"/v1/admin/shops/{shop['id']}/close", headers=admin)).json()["status"] == "closed"
    assert (await buyer.get("/v1/market/shops", params={"region": "Andijon"})).json() == []
    assert (await owner.get("/v1/market/me/shops")).json()["shops"] == []
    assert (await owner.get(f"/v1/market/me/shops/{shop['id']}")).status_code == 404


async def test_products_are_private_to_their_shop_owner(new_customer):
    owner, other = await new_customer(), await new_customer()
    shop = await _shop(owner)
    pid = (await owner.post(f"/v1/market/me/shops/{shop['id']}/products", json=PRODUCT)).json()["id"]
    assert (await other.delete(f"/v1/market/me/products/{pid}")).status_code == 404
    assert (await other.post(f"/v1/market/me/shops/{shop['id']}/products", json=PRODUCT)).status_code == 404
    assert (await other.post(f"/v1/market/me/products/{pid}/stock", json={"kind": "in", "quantity": 1})).status_code == 404
    assert (await owner.delete(f"/v1/market/me/products/{pid}")).status_code == 204


async def test_shop_input_is_validated(new_customer):
    c = await new_customer()
    for patch in ({"region": "Paris"}, {"logo_url": "http://x.com/a.png"}, {"telegram": "@bad name"}, {"name": "x"}):
        resp = await c.post("/v1/market/me/shops", json=SHOP | patch)
        assert resp.status_code == 422, (patch, resp.text)


# ------------------------------------------------------------------ media, warehouse, accounting


async def test_product_gallery_uses_own_uploads_only(new_customer, client):
    owner, other = await new_customer(), await new_customer()
    shop = await _shop(owner)
    image = (await _upload(owner, "/v1/media")).json()
    video = (await _upload(owner, "/v1/media", MP4, "clip.mp4")).json()
    assert image["type"] == "image" and video["type"] == "video"

    media = [{"type": "image", "url": image["url"]}, {"type": "video", "url": video["url"]}]
    product = (await owner.post(f"/v1/market/me/shops/{shop['id']}/products", json=PRODUCT | {"media": media})).json()
    assert product["media"] == media and product["image_url"] == image["url"]
    served = await client.get(image["url"])
    assert served.status_code == 200 and served.content == PNG and "immutable" in served.headers["cache-control"]

    other_shop = await _shop(other)
    stolen = await other.post(f"/v1/market/me/shops/{other_shop['id']}/products", json=PRODUCT | {"media": media})
    assert stolen.status_code == 400
    assert (await _upload(owner, "/v1/media", b"MZ\x90\x00 an exe", "x.exe")).status_code == 400
    assert (await client.get("/media/..%2F..%2Fsecret.png")).status_code == 404


async def test_discount_must_be_higher_than_price(new_customer):
    owner = await new_customer()
    shop = await _shop(owner)
    sale = (await owner.post(f"/v1/market/me/shops/{shop['id']}/products", json=PRODUCT | {"old_price_uzs": 20000})).json()
    assert sale["old_price_uzs"] == 20000
    odd = (await owner.post(f"/v1/market/me/shops/{shop['id']}/products", json=PRODUCT | {"old_price_uzs": 10000})).json()
    assert odd["old_price_uzs"] is None


async def test_warehouse_ledger_and_accounting(new_customer):
    owner = await new_customer()
    shop = await _shop(owner)
    sid = shop["id"]
    pid = (await owner.post(f"/v1/market/me/shops/{sid}/products", json=PRODUCT | {"initial_stock": 10})).json()["id"]

    async def move(**body):
        return await owner.post(f"/v1/market/me/products/{pid}/stock", json=body)

    assert (await move(kind="sale", quantity=3)).json()["stock"] == 7  # sold at the list price
    assert (await move(kind="sale", quantity=1, unit_price_uzs=12000)).json()["stock"] == 6
    assert (await move(kind="return", quantity=1)).json()["stock"] == 7
    assert (await move(kind="adjust", quantity=2, direction=-1, note="singan")).json()["stock"] == 5
    assert (await move(kind="in", quantity=20)).json()["stock"] == 25
    assert (await move(kind="sale", quantity=100)).status_code == 400  # never below zero

    stats = (await owner.get(f"/v1/market/me/shops/{sid}/stats")).json()
    assert stats["stock_units"] == 25
    assert stats["stock_value_uzs"] == 25 * 15000
    assert stats["units_sold_total"] == 3  # 3 + 1 sold, 1 returned
    assert stats["revenue_total_uzs"] == 3 * 15000 + 12000 - 15000
    assert stats["revenue_30d_uzs"] == stats["revenue_total_uzs"]

    history = (await owner.get(f"/v1/market/me/shops/{sid}/stock")).json()
    assert [h["kind"] for h in history] == ["in", "adjust", "return", "sale", "sale", "in"]
    assert history[1]["quantity"] == -2 and history[1]["note"] == "singan"

    await move(kind="sale", quantity=24)
    low = (await owner.get(f"/v1/market/me/shops/{sid}/stats")).json()["low_stock"]
    assert [p["stock"] for p in low] == [1]


async def test_files_stay_inside_media_dir(new_customer, media_dir):
    c = await new_customer()
    ad_id = (await c.post("/v1/ads", json=AD)).json()["id"]
    await _upload(c, f"/v1/ads/{ad_id}/receipt")
    await _upload(c, "/v1/media")
    files = [os.path.join(root, f) for root, _, names in os.walk(media_dir) for f in names]
    assert len(files) == 2 and all(f.startswith(media_dir) for f in files)


# ------------------------------------------------------------------ customers


async def test_admin_sees_shared_profiles_and_counts(new_customer, client, session_factory):
    seller, anonymous = await new_customer(), await new_customer()
    admin = await _admin(session_factory)
    profile = {"first_name": "Doniyor", "last_name": "A", "username": "seller_uz", "phone": "998901112233"}
    assert (await _put(seller, "/v1/customers/me/profile", profile)).status_code == 200
    await _shop(seller)
    await seller.post("/v1/ads", json=AD)

    found = (await client.get("/v1/admin/users", headers=admin, params={"q": "@seller"})).json()
    assert found["total"] == 1
    user = found["users"][0]
    assert user["profile"]["phone"] == "998901112233" and user["shops"] == 1 and user["ads"] == 1
    everyone = (await client.get("/v1/admin/users", headers=admin)).json()
    assert everyone["total"] == 2
    assert {u["id"]: u["profile"] for u in everyone["users"]}[anonymous.id] is None

    assert (await seller.delete("/v1/customers/me/profile")).status_code == 204
    assert (await client.get("/v1/admin/users", headers=admin, params={"q": "seller"})).json()["total"] == 0
    async with session_factory() as db:
        assert "users_listed" in set(await db.scalars(select(AuditLog.action)))


async def test_profile_input_is_validated(new_customer):
    c = await new_customer()
    for patch in ({"phone": "abc"}, {"username": "a b"}, {"first_name": "x" * 65}):
        assert (await _put(c, "/v1/customers/me/profile", patch)).status_code == 422
