"""Web admin panel API: editable settings, admin accounts, dashboard stats, product visibility, APK download, static panel."""

import tempfile
from pathlib import Path

import pytest
from sqlalchemy import select

from app.config import get_settings
from app.models import AdminRole, AdminUser, AuditLog
from app.security import new_secret, sha256_hex

pytestmark = pytest.mark.asyncio(loop_scope="session")

SHOP = {"name": "Andijon Gul", "description": "Gullar", "region": "Andijon", "phone": "+998 90 123 45 67", "telegram": "andijon_gul"}
AD = {"title": "Chegirma", "text": "", "media_type": "image", "media_url": "https://example.com/b.jpg", "regions": ["Andijon"], "days": 2}


@pytest.fixture(autouse=True)
def media_dir(monkeypatch):
    with tempfile.TemporaryDirectory() as tmp:
        monkeypatch.setattr(get_settings(), "media_dir", tmp)
        yield tmp


async def _admin(session_factory, role: AdminRole = AdminRole.OWNER, name: str | None = None) -> dict[str, str]:
    key = new_secret()
    async with session_factory() as db:
        db.add(AdminUser(name=name or f"{role.value}-{key[:6]}", key_hash=sha256_hex(key), role=role))
        await db.commit()
    return {"X-Admin-Key": key}


async def test_settings_start_from_environment_and_owner_overrides_prices(client, new_customer, session_factory):
    owner = await _admin(session_factory)
    resp = await client.get("/v1/admin/settings", headers=owner)
    assert resp.status_code == 200
    assert resp.json()["ad_price_per_region_day_uzs"] == get_settings().ad_price_per_region_day_uzs

    resp = await client.put("/v1/admin/settings", headers=owner, json={"ad_price_per_region_day_uzs": 7000, "ad_payment_card": "8600 1111 2222 3333"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["ad_payment_card"] == "8600 1111 2222 3333"

    c = await new_customer()
    config = (await c.get("/v1/ads/config")).json()
    assert config["price_per_region_day_uzs"] == 7000
    assert config["card_number"] == "8600 1111 2222 3333"
    ad = (await c.post("/v1/ads", json=AD)).json()
    assert ad["price_uzs"] == 1 * 2 * 7000


async def test_only_owner_changes_settings_and_card_is_masked_in_audit(client, session_factory):
    support = await _admin(session_factory, AdminRole.SUPPORT)
    assert (await client.put("/v1/admin/settings", headers=support, json={"shop_free_limit": 5})).status_code == 403
    owner = await _admin(session_factory)
    assert (await client.put("/v1/admin/settings", headers=owner, json={"ad_payment_card": "8600 0000 0000 0001"})).status_code == 200
    async with session_factory() as db:
        row = await db.scalar(select(AuditLog).where(AuditLog.action == "settings_updated"))
    assert row.details["ad_payment_card"] == "***"


async def test_settings_reject_bad_card_and_empty_update(client, session_factory):
    owner = await _admin(session_factory)
    assert (await client.put("/v1/admin/settings", headers=owner, json={"ad_payment_card": "86<script>"})).status_code == 422
    assert (await client.put("/v1/admin/settings", headers=owner, json={})).status_code == 400


async def test_owner_creates_admin_whose_key_works_once_shown(client, session_factory):
    owner = await _admin(session_factory, name="boss")
    resp = await client.post("/v1/admin/admins", headers=owner, json={"name": "moder1", "role": "support"})
    assert resp.status_code == 201, resp.text
    created = resp.json()
    me = await client.get("/v1/admin/me", headers={"X-Admin-Key": created["key"]})
    assert me.json() == {"name": "moder1", "role": "support"}
    listed = (await client.get("/v1/admin/admins", headers=owner)).json()
    assert all("key" not in a and "key_hash" not in a for a in listed)
    assert (await client.post("/v1/admin/admins", headers=owner, json={"name": "moder1", "role": "viewer"})).status_code == 409


async def test_deactivated_admin_is_locked_out_and_owner_cannot_lock_self(client, session_factory):
    owner = await _admin(session_factory, name="boss")
    created = (await client.post("/v1/admin/admins", headers=owner, json={"name": "temp", "role": "viewer"})).json()
    assert (await client.patch(f"/v1/admin/admins/{created['id']}", headers=owner, json={"active": False})).status_code == 200
    assert (await client.get("/v1/admin/me", headers={"X-Admin-Key": created["key"]})).status_code == 401
    me = next(a for a in (await client.get("/v1/admin/admins", headers=owner)).json() if a["name"] == "boss")
    assert (await client.patch(f"/v1/admin/admins/{me['id']}", headers=owner, json={"active": False})).status_code == 409
    assert (await client.patch(f"/v1/admin/admins/{me['id']}", headers=owner, json={"role": "viewer"})).status_code == 409


async def test_admin_management_needs_owner(client, session_factory):
    finance = await _admin(session_factory, AdminRole.FINANCE)
    assert (await client.get("/v1/admin/admins", headers=finance)).status_code == 403
    assert (await client.post("/v1/admin/admins", headers=finance, json={"name": "x1", "role": "owner"})).status_code == 403


async def test_wrong_admin_keys_are_rate_limited(client):
    statuses = [(await client.get("/v1/admin/me", headers={"X-Admin-Key": f"wrong-{i}"})).status_code for i in range(22)]
    assert statuses[:20] == [401] * 20
    assert statuses[-1] == 429


async def test_stats_count_users_shops_and_revenue(client, new_customer, session_factory):
    viewer = await _admin(session_factory, AdminRole.VIEWER)
    c = await new_customer()
    assert (await c.post("/v1/market/me/shops", json=SHOP)).status_code == 201
    stats = (await client.get("/v1/admin/stats", headers=viewer)).json()
    assert stats["users"]["total"] == 1
    assert stats["shops"]["pending"] == 1
    assert stats["revenue_uzs"]["total"] == 0
    assert len(stats["daily"]) == 30
    assert stats["daily"][-1]["new_users"] == 1


async def test_support_hides_a_product_and_sees_shop_detail(client, new_customer, session_factory):
    support = await _admin(session_factory, AdminRole.SUPPORT)
    c = await new_customer()
    shop = (await c.post("/v1/market/me/shops", json=SHOP)).json()
    product = (await c.post(f"/v1/market/me/shops/{shop['id']}/products", json={"title": "Atirgul", "price_uzs": 15000, "category": "flowers"})).json()
    detail = (await client.get(f"/v1/admin/shops/{shop['id']}", headers=support)).json()
    assert [p["id"] for p in detail["products"]] == [product["id"]]

    resp = await client.post(f"/v1/admin/products/{product['id']}/visibility", headers=support, json={"active": False, "reason": "taqiqlangan"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["active"] is False
    assert (await client.post(f"/v1/admin/products/{product['id']}/visibility", headers=support, json={"active": True, "reason": ""})).status_code == 422


async def test_release_and_download_follow_the_uploaded_apk(client, session_factory, media_dir):
    owner = await _admin(session_factory)
    notes = "Musiqa pleeri\nQo'ng'iroqlar <b>tez orada</b>"
    await client.put("/v1/admin/settings", headers=owner, json={"app_version": "1.1.0", "app_build": 2, "app_release_notes": notes})
    release = (await client.get("/v1/app/release")).json()
    assert release["available"] is False and release["version"] == "1.1.0"
    assert (await client.get("/download/UZARO.apk")).status_code == 404

    apk = Path(media_dir) / "release" / "UZARO.apk"
    apk.parent.mkdir(parents=True)
    apk.write_bytes(b"PK\x03\x04apk")
    release = (await client.get("/v1/app/release")).json()
    assert release["available"] is True and release["size_bytes"] == 7
    file = await client.get("/download/UZARO.apk")
    assert file.status_code == 200 and file.headers["content-type"] == "application/vnd.android.package-archive"
    page = await client.get("/download")
    assert page.status_code == 200
    assert "1.1.0" in page.text
    # Release notes are escaped, not rendered as HTML.
    assert "&lt;b&gt;" in page.text and "<b>tez orada</b>" not in page.text


async def test_admin_panel_is_served_with_strict_headers(client):
    resp = await client.get("/admin/")
    assert resp.status_code == 200
    assert "UZARO Admin" in resp.text
    assert "script-src 'self'" in resp.headers["content-security-policy"]
    assert resp.headers["x-frame-options"] == "DENY"


async def test_login_password_gives_a_session_that_logout_ends(client, session_factory):
    owner = await _admin(session_factory, name="boss")
    me = next(a for a in (await client.get("/v1/admin/admins", headers=owner)).json() if a["name"] == "boss")
    resp = await client.put(f"/v1/admin/admins/{me['id']}/credentials", headers=owner, json={"login": "949392250", "password": "949392250"})
    assert resp.status_code == 200, resp.text
    async with session_factory() as db:
        stored = await db.scalar(select(AdminUser.password_hash).where(AdminUser.name == "boss"))
    assert stored.startswith("scrypt$") and "949392250" not in stored

    assert (await client.post("/v1/admin/login", json={"login": "949392250", "password": "wrong"})).status_code == 401
    login = await client.post("/v1/admin/login", json={"login": "949392250", "password": "949392250"})
    assert login.status_code == 200, login.text
    session = {"X-Admin-Key": login.json()["token"]}
    assert (await client.get("/v1/admin/me", headers=session)).json() == {"name": "boss", "role": "owner"}

    assert (await client.post("/v1/admin/logout", headers=session)).status_code == 204
    assert (await client.get("/v1/admin/me", headers=session)).status_code == 401


async def test_password_guessing_is_rate_limited(client, session_factory):
    statuses = [(await client.post("/v1/admin/login", json={"login": "949392250", "password": f"p{i}"})).status_code for i in range(11)]
    assert statuses[:10] == [401] * 10
    assert statuses[-1] == 429


async def test_deactivated_admin_cannot_log_in(client, session_factory):
    owner = await _admin(session_factory, name="boss")
    created = (await client.post("/v1/admin/admins", headers=owner, json={"name": "temp", "role": "viewer"})).json()
    await client.put(f"/v1/admin/admins/{created['id']}/credentials", headers=owner, json={"login": "temp1", "password": "secret-pass"})
    await client.patch(f"/v1/admin/admins/{created['id']}", headers=owner, json={"active": False})
    assert (await client.post("/v1/admin/login", json={"login": "temp1", "password": "secret-pass"})).status_code == 401


async def test_successful_logins_do_not_use_up_attempts_and_phone_spellings_match(client, session_factory):
    owner = await _admin(session_factory, name="boss")
    me = next(a for a in (await client.get("/v1/admin/admins", headers=owner)).json() if a["name"] == "boss")
    await client.put(f"/v1/admin/admins/{me['id']}/credentials", headers=owner, json={"login": "949392250", "password": "949392250"})
    for spelling in ["949392250", "+998 94 939 22 50", "998949392250"] * 5:
        resp = await client.post("/v1/admin/login", json={"login": spelling, "password": "949392250"})
        assert resp.status_code == 200, (spelling, resp.text)


def test_login_candidates_only_widen_phone_numbers():
    from app.routers.admin_auth import login_candidates

    assert "949392250" in login_candidates("+998 (94) 939-22-50")
    assert login_candidates("boss") == ["boss"]
    assert login_candidates("admin949392250") == ["admin949392250"]
