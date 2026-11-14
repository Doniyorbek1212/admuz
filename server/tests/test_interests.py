"""Interest-based hub ads: topic guessing, learning from hub signals and ad taps, per-viewer ranking,
view/click counters, the customer's opt-out, admin controls; and locating a position's region and district."""

import random
import uuid
from types import SimpleNamespace

import pytest

from app.models import AdminRole, AdminUser, Place, PlaceCategory
from app.security import new_secret, sha256_hex
from app.services.interests import affinity, clean_topics, guess_topics, rank_ads

pytestmark = pytest.mark.asyncio(loop_scope="session")

AD = {"text": "", "media_type": "image", "media_url": "https://example.com/b.jpg", "regions": ["Namangan"], "days": 3}


async def _admin(session_factory, role: AdminRole) -> dict[str, str]:
    key = new_secret()
    async with session_factory() as db:
        db.add(AdminUser(name=f"{role.value}-{key[:6]}", key_hash=sha256_hex(key), role=role))
        await db.commit()
    return {"X-Admin-Key": key}


async def _live_ad(client, customer, support: dict[str, str], **fields) -> dict:
    resp = await customer.post("/v1/ads", json=AD | fields)
    assert resp.status_code == 201, resp.text
    ad = resp.json()
    receipt = await customer.post(f"/v1/ads/{ad['id']}/receipt", files={"file": ("c.png", b"\x89PNG\r\n\x1a\n" + b"\x00" * 64, "image/png")})
    assert receipt.status_code == 200, receipt.text
    approved = await client.post(f"/v1/admin/ads/{ad['id']}/approve", headers=support)
    assert approved.status_code == 200, approved.text
    return approved.json()


# ------------------------------------------------------------------ pure logic


def test_topics_are_guessed_from_ad_text():
    assert guess_topics("Lavash va pizza yetkazib berish", "Chust kafe")[0] == "food"
    assert "tech" in guess_topics("iPhone 15 Pro chegirmada", "")
    assert guess_topics("Скидки на смартфоны Samsung", "")[0] == "tech"
    assert guess_topics("Salom", "") == []
    assert len(guess_topics("taksi kafe dorixona mehmonxona bank", "")) == 3


def test_clean_topics_drops_unknown_and_duplicates():
    assert clean_topics(["food", "hack", "food", "tech"]) == ["food", "tech"]


def test_ranking_prefers_matching_topic_but_keeps_rotating():
    food = SimpleNamespace(topics=["food"])
    tech = SimpleNamespace(topics=["tech"])
    profile = {"food": 8.0, "tech": 1.0}
    assert affinity(["food"], profile) == 1.0 and affinity([], profile) == 0.0
    firsts = [rank_ads([tech, food], profile, personalized=True, interest_weight_percent=70, rng=random.Random(i))[0] for i in range(200)]
    # Weights 1.0 vs 0.3: the matching ad leads ~77% of the time, the other paid ad still ~23%.
    assert 130 < firsts.count(food) < 180
    assert firsts.count(tech) > 20
    plain = [rank_ads([tech, food], profile, personalized=False, interest_weight_percent=70, rng=random.Random(i))[0] for i in range(200)]
    assert 60 < plain.count(food) < 140  # personalisation off: fair rotation


# ------------------------------------------------------------------ API


async def test_ad_topics_are_guessed_or_taken_from_the_advertiser(new_customer):
    c = await new_customer()
    guessed = (await c.post("/v1/ads", json=AD | {"title": "Pizza va burger yetkazib berish"})).json()
    assert guessed["topics"] == ["food"]
    picked = (await c.post("/v1/ads", json=AD | {"title": "Pizza", "topics": ["gifts", "kids"]})).json()
    assert picked["topics"] == ["gifts", "kids"]
    assert (await c.post("/v1/ads", json=AD | {"title": "Pizza", "topics": ["hack"]})).status_code == 422
    config = (await c.get("/v1/ads/config")).json()
    assert "food" in config["topics"] and config["max_topics"] == 3


async def test_active_ads_follow_the_viewers_interests(client, new_customer, session_factory):
    support = await _admin(session_factory, AdminRole.SUPPORT)
    advertiser = await new_customer()
    tech = await _live_ad(client, advertiser, support, title="Smartfonlar", topics=["tech"])
    food = await _live_ad(client, advertiser, support, title="Osh markazi", topics=["food"])
    viewer = await new_customer()
    signals = [{"topic": "food", "kind": "open"}] * 10
    assert (await viewer.post("/v1/interests", json={"signals": signals})).status_code == 204
    firsts = [(await viewer.get("/v1/ads/active", params={"region": "Namangan"})).json()[0]["id"] for _ in range(40)]
    assert firsts.count(food["id"]) > firsts.count(tech["id"])  # ~77% vs ~23%; equal would be 4 sigma off
    assert (await viewer.post("/v1/interests", json={"signals": [{"topic": "hack", "kind": "open"}]})).status_code == 422


async def test_views_and_clicks_are_counted_once_per_viewer(client, new_customer, session_factory):
    support = await _admin(session_factory, AdminRole.SUPPORT)
    advertiser = await new_customer()
    ad = await _live_ad(client, advertiser, support, title="Smartfonlar", topics=["tech"])
    viewer = await new_customer()
    for _ in range(3):
        assert (await viewer.post(f"/v1/ads/{ad['id']}/view")).status_code == 204
    assert (await viewer.post(f"/v1/ads/{ad['id']}/click")).status_code == 204
    assert (await viewer.post(f"/v1/ads/{uuid.uuid4()}/view")).status_code == 404
    mine = (await advertiser.get("/v1/ads/mine")).json()[0]
    assert (mine["views"], mine["clicks"]) == (1, 1)
    overview = (await client.get("/v1/admin/interests", headers=support)).json()
    tech_row = next(t for t in overview["topics"] if t["topic"] == "tech")
    assert tech_row["users"] == 1 and tech_row["clicks"] == 1 and tech_row["ctr"] == 100.0  # the tap taught "tech"
    assert overview["profiled_users"] == 1
    opted_out = await new_customer()
    assert (await opted_out.post(f"/v1/ads/{ad['id']}/click", params={"learn": "false"})).status_code == 204
    after = (await client.get("/v1/admin/interests", headers=support)).json()
    assert after["profiled_users"] == 1  # counted as a tap, nothing learnt about the opted-out viewer
    assert next(t for t in after["topics"] if t["topic"] == "tech")["clicks"] == 2


async def test_customer_can_wipe_learnt_interests(client, new_customer, session_factory):
    viewer = await new_customer()
    await viewer.post("/v1/interests", json={"signals": [{"topic": "music", "kind": "open"}]})
    assert (await viewer.delete("/v1/interests")).status_code == 204
    support = await _admin(session_factory, AdminRole.SUPPORT)
    assert (await client.get("/v1/admin/interests", headers=support)).json()["profiled_users"] == 0


async def test_admin_controls_personalisation_and_ad_topics(client, new_customer, session_factory):
    owner = await _admin(session_factory, AdminRole.OWNER)
    support = await _admin(session_factory, AdminRole.SUPPORT)
    saved = await client.put("/v1/admin/settings", headers=owner, json={"ads_personalization": 0, "ads_interest_weight": 40, "ads_interest_half_life_days": 7})
    assert saved.status_code == 200, saved.text
    assert (saved.json()["ads_personalization"], saved.json()["ads_interest_weight"]) == (0, 40)
    assert (await client.put("/v1/admin/settings", headers=owner, json={"ads_interest_weight": 101})).status_code == 422
    assert (await client.put("/v1/admin/settings", headers=support, json={"ads_personalization": 1})).status_code == 403

    viewer = await new_customer()
    await viewer.post("/v1/interests", json={"signals": [{"topic": "music", "kind": "open"}]})
    assert (await client.get("/v1/admin/interests", headers=support)).json()["profiled_users"] == 0  # off: nothing learnt

    ad = await _live_ad(client, await new_customer(), support, title="Kafe")
    fixed = await client.put(f"/v1/admin/ads/{ad['id']}/topics", headers=support, json={"topics": ["sport", "kids"]})
    assert fixed.status_code == 200 and fixed.json()["topics"] == ["sport", "kids"]
    assert (await client.put(f"/v1/admin/ads/{ad['id']}/topics", headers=support, json={"topics": ["x"]})).status_code == 422


async def test_admin_hides_the_topic_picker(client, new_customer, session_factory):
    owner = await _admin(session_factory, AdminRole.OWNER)
    c = await new_customer()
    assert (await c.get("/v1/ads/config")).json()["topics_enabled"] is True
    assert (await client.put("/v1/admin/settings", headers=owner, json={"ads_topic_picker": 0})).status_code == 200
    assert (await c.get("/v1/ads/config")).json()["topics_enabled"] is False
    # An older app still sends its picks: ignored, topics come from the text.
    ad = (await c.post("/v1/ads", json=AD | {"title": "Pizza va burger yetkazib berish", "topics": ["gifts"]})).json()
    assert ad["topics"] == ["food"]
    assert (await client.put("/v1/admin/settings", headers=owner, json={"ads_topic_picker": 2})).status_code == 422


async def test_locate_picks_region_and_district_of_the_nearest_places(new_customer, session_factory):
    async with session_factory() as db:
        db.add_all([
            Place(category=PlaceCategory.FOOD, region="Namangan", district="Chust tumani", name="A", latitude=41.003, longitude=71.237),
            Place(category=PlaceCategory.BANK, region="Namangan", district="Chust tumani", name="B", latitude=41.010, longitude=71.230),
            Place(category=PlaceCategory.FOOD, region="Namangan", district="Pop tumani", name="C", latitude=40.873, longitude=71.110),
        ])
        await db.commit()
    c = await new_customer()
    here = (await c.get("/v1/places/locate", params={"lat": 41.005, "lon": 71.235})).json()
    assert (here["region"], here["district"]) == ("Namangan", "Chust tumani") and here["nearest_m"] < 1000
    pop = (await c.get("/v1/places/locate", params={"lat": 40.870, "lon": 71.108})).json()
    assert pop["district"] == "Pop tumani"
    far = (await c.get("/v1/places/locate", params={"lat": 39.65, "lon": 66.97})).json()
    assert far == {"region": None, "district": None, "nearest_m": None}
    assert (await c.get("/v1/places/locate", params={"lat": 100, "lon": 0})).status_code == 422
