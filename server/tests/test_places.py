"""The hub's "Region" directory: listing, district scope, search, nearest-first order and admin editing."""

import pytest

from app.models import AdminRole, AdminUser, Place, PlaceCategory
from app.security import new_secret, sha256_hex

pytestmark = pytest.mark.asyncio(loop_scope="session")


async def _seed(session_factory) -> None:
    async with session_factory() as db:
        db.add_all([
            Place(category=PlaceCategory.FOOD, region="Namangan", district="Chust tumani", name="Oltin baliq", subcategory="Restoran",
                  latitude=41.003, longitude=71.236, is_24h=True, source_ref="osm:node/1"),
            Place(category=PlaceCategory.DOCTOR, region="Namangan", district="Chust tumani", name="Apeks davolash markazi",
                  subcategory="Shifoxona", latitude=41.02, longitude=71.25),
            Place(category=PlaceCategory.TAXI, region="Namangan", district=None, name="Namangan taksi 1050", phones=["1050"]),
            Place(category=PlaceCategory.FOOD, region="Namangan", district="Pop tumani", name="Pop oshxonasi", latitude=40.87, longitude=71.1),
            Place(category=PlaceCategory.FOOD, region="Andijon", district="Asaka tumani", name="Asaka kafe"),
            Place(category=PlaceCategory.BANK, region="Namangan", district="Chust tumani", name="Yopilgan bank", active=False),
        ])
        await db.commit()


async def test_district_view_includes_region_wide_places_and_counts(new_customer, session_factory):
    await _seed(session_factory)
    customer = await new_customer()
    resp = await customer.get("/v1/places", params={"region": "Namangan", "district": "Chust tumani"})
    assert resp.status_code == 200, resp.text
    names = {p["name"] for p in resp.json()["items"]}
    assert names == {"Oltin baliq", "Apeks davolash markazi", "Namangan taksi 1050"}  # no Pop, no hidden bank, no Andijon

    summary = (await customer.get("/v1/places/summary", params={"region": "Namangan", "district": "Chust tumani"})).json()
    assert summary == {"counts": {"food": 1, "doctor": 1, "taxi": 1}, "total": 3}


async def test_category_search_and_nearest_order(new_customer, session_factory):
    await _seed(session_factory)
    customer = await new_customer()
    food = (await customer.get("/v1/places", params={"region": "Namangan", "category": "food"})).json()["items"]
    assert {p["name"] for p in food} == {"Oltin baliq", "Pop oshxonasi"}

    found = (await customer.get("/v1/places", params={"region": "Namangan", "q": "davolash"})).json()["items"]
    assert [p["name"] for p in found] == ["Apeks davolash markazi"]

    near = (await customer.get("/v1/places", params={"region": "Namangan", "lat": 41.0, "lon": 71.23})).json()["items"]
    assert near[0]["name"] == "Oltin baliq" and 0 < near[0]["distance_m"] < 1500
    assert near[-1]["name"] == "Namangan taksi 1050"  # no coordinates: last
    assert "distance_m" not in near[-1]


async def test_validation_and_auth(new_customer, client):
    customer = await new_customer()
    assert (await customer.get("/v1/places", params={"region": "Atlantis"})).status_code == 422
    assert (await customer.get("/v1/places", params={"region": "Namangan", "district": "Asaka tumani"})).status_code == 400
    assert (await client.get("/v1/places", params={"region": "Namangan"})).status_code == 401
    regions = (await customer.get("/v1/places/regions")).json()
    assert any(r["name"] == "Namangan" and "Chust tumani" in r["districts"] for r in regions)


async def test_admin_adds_edits_and_hides_places(new_customer, client, session_factory):
    key = new_secret()
    async with session_factory() as db:
        db.add(AdminUser(name="support-places", key_hash=sha256_hex(key), role=AdminRole.SUPPORT))
        await db.commit()
    admin = {"X-Admin-Key": key}
    body = {"category": "pharmacy", "region": "Namangan", "district": "Chust tumani", "name": "Shifo dorixona",
            "phones": ["+998 69 123 45 67"], "is_24h": True}
    created = await client.post("/v1/admin/places", json=body, headers=admin)
    assert created.status_code == 201, created.text
    place_id = created.json()["id"]

    bad = await client.post("/v1/admin/places", json=body | {"district": "Asaka tumani"}, headers=admin)
    assert bad.status_code == 422

    customer = await new_customer()
    detail = (await customer.get(f"/v1/places/{place_id}")).json()
    assert detail["name"] == "Shifo dorixona" and detail["is_24h"] is True

    hidden = await client.put(f"/v1/admin/places/{place_id}", json=body | {"active": False}, headers=admin)
    assert hidden.status_code == 200
    assert (await customer.get(f"/v1/places/{place_id}")).status_code == 404

    assert (await client.delete(f"/v1/admin/places/{place_id}", headers=admin)).status_code == 204
    listed = (await client.get("/v1/admin/places", params={"region": "Namangan"}, headers=admin)).json()
    assert listed["total"] == 0
