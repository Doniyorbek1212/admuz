"""UZARO gifts: bot-proven Telegram id, balance top-up by receipt, sending, profile listing, hiding, admin catalog."""

import uuid

import pytest

from app.config import get_settings
from app.models import AdminRole, AdminUser, GiftItem
from app.routers.gifts import webhook_secret
from app.security import new_secret, sha256_hex

pytestmark = pytest.mark.asyncio(loop_scope="session")

FAKE_WEBP = b"RIFF\x24\x00\x00\x00WEBPVP8X" + b"\x00" * 32
FAKE_PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64


@pytest.fixture(autouse=True)
def gifts_bot(monkeypatch):
    settings = get_settings()
    monkeypatch.setattr(settings, "gifts_bot_token", "123:test-token")
    monkeypatch.setattr(settings, "gifts_bot_username", "uzaro_uzbot")


async def _admin(session_factory, role: AdminRole = AdminRole.SUPPORT) -> dict[str, str]:
    key = new_secret()
    async with session_factory() as db:
        db.add(AdminUser(name=f"gifts-{uuid.uuid4().hex[:6]}", key_hash=sha256_hex(key), role=role))
        await db.commit()
    return {"X-Admin-Key": key}


def _update(user_id: int, text: str) -> dict:
    return {"update_id": 1, "message": {"message_id": 5, "from": {"id": user_id, "is_bot": False},
                                        "chat": {"id": user_id, "type": "private"}, "text": text}}


async def _link(client, customer, telegram_id: int) -> None:
    code = (await customer.post("/v1/telegram/link")).json()["code"]
    reply = await client.post("/v1/telegram/webhook", json=_update(telegram_id, f"/start {code}"),
                              headers={"X-Telegram-Bot-Api-Secret-Token": webhook_secret()})
    assert reply.status_code == 200 and reply.json()["method"] == "sendMessage"


async def _gift(client, admin, title: str = "Atirgul", price: int = 5_000) -> dict:
    created = await client.post("/v1/admin/gifts", headers=admin, files={"file": ("rose.webp", FAKE_WEBP, "image/webp")},
                                data={"title": title, "price_uzs": str(price)})
    assert created.status_code == 201, created.text
    return created.json()


async def _top_up(client, admin, customer, amount: int) -> None:
    topup = await customer.post("/v1/wallet/topups", data={"amount_uzs": str(amount)},
                                files={"receipt": ("chek.png", FAKE_PNG, "image/png")})
    assert topup.status_code == 201, topup.text
    approved = await client.post(f"/v1/admin/gifts/topups/{topup.json()['id']}/approve", headers=admin)
    assert approved.status_code == 200, approved.text


async def test_link_send_list_and_hide(client, session_factory, new_customer):
    admin = await _admin(session_factory)
    rose = await _gift(client, admin)
    alice, bob = await new_customer(), await new_customer()

    assert (await alice.get("/v1/telegram/me")).json()["telegram_user_id"] is None
    send = {"gift_id": rose["id"], "recipient_telegram_id": 222, "text": "Tabriklayman!"}
    assert (await alice.post("/v1/gifts/send", json=send)).json()["detail"]["code"] == "TELEGRAM_NOT_LINKED"

    await _link(client, alice, 111)
    await _link(client, bob, 222)
    assert (await alice.get("/v1/telegram/me")).json()["telegram_user_id"] == 111
    assert (await alice.post("/v1/gifts/send", json=send)).json()["detail"]["code"] == "INSUFFICIENT_BALANCE"

    await _top_up(client, admin, alice, 7_000)
    sent = await alice.post("/v1/gifts/send", json=send)
    assert sent.status_code == 201, sent.text
    assert sent.json()["balance_uzs"] == 2_000
    wallet_now = (await alice.get("/v1/wallet")).json()
    assert wallet_now["balance_uzs"] == 2_000
    # History: the gift charge, then the top-up it was paid from.
    assert [(e["kind"], e["delta_uzs"]) for e in wallet_now["entries"]] == [("gift", -5_000), ("topup", 7_000)]
    assert (await alice.post("/v1/gifts/send", json=send)).json()["detail"]["code"] == "INSUFFICIENT_BALANCE"

    profile = (await alice.get("/v1/gifts/users/222")).json()
    assert profile["total"] == 1
    item = profile["items"][0]
    assert item["sender_telegram_id"] == 111 and item["text"] == "Tabriklayman!" and item["gift"]["title"] == "Atirgul"

    # Only the recipient can hide it; hidden gifts leave the public profile but stay in "received".
    assert (await alice.post(f"/v1/gifts/{item['id']}/visibility", json={"hidden": True})).status_code == 404
    assert (await bob.post(f"/v1/gifts/{item['id']}/visibility", json={"hidden": True})).json()["hidden"] is True
    assert (await alice.get("/v1/gifts/users/222")).json()["total"] == 0
    assert len((await bob.get("/v1/gifts/received")).json()["items"]) == 1

    # A gift that was sent cannot be deleted from the catalog, only hidden.
    assert (await client.delete(f"/v1/admin/gifts/{rose['id']}", headers=admin)).json()["detail"]["code"] == "GIFT_IN_USE"


async def test_gift_bought_for_oneself(client, session_factory, new_customer):
    admin = await _admin(session_factory)
    rose = await _gift(client, admin)
    carol = await new_customer()
    await _link(client, carol, 777)
    await _top_up(client, admin, carol, 5_000)
    mine = await carol.post("/v1/gifts/send", json={"gift_id": rose["id"], "recipient_telegram_id": 777})
    assert mine.status_code == 201, mine.text
    assert mine.json()["balance_uzs"] == 0
    profile = (await carol.get("/v1/gifts/users/777")).json()
    assert profile["total"] == 1 and profile["items"][0]["sender_telegram_id"] == 777

    # Full history: the purchase names the gift and that it was for oneself; filters split money in and out.
    spent = (await carol.get("/v1/wallet/history", params={"direction": "out"})).json()
    assert [(i["kind"], i["title"], i["to_self"]) for i in spent["items"]] == [("gift", "Atirgul", True)]
    assert spent["has_more"] is False
    came_in = (await carol.get("/v1/wallet/history", params={"direction": "in"})).json()["items"]
    assert [(i["kind"], i["method"]) for i in came_in] == [("topup", "card")]
    assert (await carol.get("/v1/wallet/history", params={"limit": 1})).json()["has_more"] is True
    assert (await carol.get("/v1/wallet/history", params={"direction": "x"})).status_code == 422


async def test_group_gifts_and_chat_list_showcase(client, session_factory, new_customer):
    admin = await _admin(session_factory)
    rose = await _gift(client, admin, "Atirgul", 5_000)
    lion = await _gift(client, admin, "Sher", 20_000)
    alice = await new_customer()
    await _link(client, alice, 333)
    await _top_up(client, admin, alice, 60_000)
    group = -1_001_234_567_890  # a supergroup's TDLib chat id
    for gift, recipient in ((rose, group), (rose, group), (lion, group), (rose, 444)):
        sent = await alice.post("/v1/gifts/send", json={"gift_id": gift["id"], "recipient_telegram_id": recipient})
        assert sent.status_code == 201, sent.text
    assert (await alice.post("/v1/gifts/send", json={"gift_id": rose["id"], "recipient_telegram_id": 0})).status_code == 422

    assert (await alice.get(f"/v1/gifts/users/{group}")).json()["total"] == 3
    top = (await alice.get("/v1/gifts/top", params={"ids": [group, 444, 555]})).json()["items"]
    assert set(top) == {str(group), "444"}
    # Dearest first, each gift once, and the full count.
    assert [g["gift"]["title"] for g in top[str(group)]["gifts"]] == ["Sher", "Atirgul"]
    assert top[str(group)]["total"] == 3
    assert (await alice.get("/v1/gifts/top")).status_code == 422


async def test_webhook_needs_secret_and_fresh_code(client, new_customer):
    customer = await new_customer()
    code = (await customer.post("/v1/telegram/link")).json()["code"]
    forged = await client.post("/v1/telegram/webhook", json=_update(999, f"/start {code}"),
                               headers={"X-Telegram-Bot-Api-Secret-Token": "wrong"})
    assert forged.status_code == 401
    assert (await customer.get("/v1/telegram/me")).json()["telegram_user_id"] is None

    secret = {"X-Telegram-Bot-Api-Secret-Token": webhook_secret()}
    await client.post("/v1/telegram/webhook", json=_update(999, f"/start {code}"), headers=secret)
    assert (await customer.get("/v1/telegram/me")).json()["telegram_user_id"] == 999
    # The code is single use: replaying it from another account changes nothing.
    await client.post("/v1/telegram/webhook", json=_update(555, f"/start {code}"), headers=secret)
    assert (await customer.get("/v1/telegram/me")).json()["telegram_user_id"] == 999


async def test_topup_rejection_and_limits(client, session_factory, new_customer):
    admin = await _admin(session_factory)
    customer = await new_customer()
    ids = []
    for _ in range(3):
        r = await customer.post("/v1/wallet/topups", data={"amount_uzs": "10000"}, files={"receipt": ("c.png", FAKE_PNG, "image/png")})
        ids.append(r.json()["id"])
    fourth = await customer.post("/v1/wallet/topups", data={"amount_uzs": "10000"}, files={"receipt": ("c.png", FAKE_PNG, "image/png")})
    assert fourth.json()["detail"]["code"] == "TOO_MANY_PENDING_TOPUPS"

    pending = (await client.get("/v1/admin/gifts/topups", headers=admin)).json()
    assert pending["pending"] == 3
    rejected = await client.post(f"/v1/admin/gifts/topups/{ids[0]}/reject", headers=admin, json={"reason": "Chek noto'g'ri"})
    assert rejected.json()["status"] == "rejected"
    assert (await client.post(f"/v1/admin/gifts/topups/{ids[0]}/approve", headers=admin)).json()["detail"]["code"] == "TOPUP_NOT_PENDING"
    await client.post(f"/v1/admin/gifts/topups/{ids[1]}/approve", headers=admin)
    await client.post(f"/v1/admin/gifts/topups/{ids[1]}/approve", headers=admin)  # twice: credited once
    wallet = (await customer.get("/v1/wallet")).json()
    assert wallet["balance_uzs"] == 10_000
    assert {t["status"] for t in wallet["topups"]} == {"pending", "approved", "rejected"}


async def test_catalog_hides_inactive_and_refuses_non_animation(client, session_factory, new_customer):
    admin = await _admin(session_factory)
    gift = await _gift(client, admin, "Toj", 40_000)
    customer = await new_customer()
    assert [g["title"] for g in (await customer.get("/v1/gifts/catalog")).json()["items"]] == ["Toj"]
    await client.put(f"/v1/admin/gifts/{gift['id']}", headers=admin, json={"title": "Toj", "price_uzs": 40_000, "active": False})
    assert (await customer.get("/v1/gifts/catalog")).json()["items"] == []

    bad = await client.post("/v1/admin/gifts", headers=admin, files={"file": ("x.png", FAKE_PNG, "image/png")},
                            data={"title": "X", "price_uzs": "1"})
    assert bad.json()["detail"]["code"] == "NOT_A_GIFT_ANIMATION"


async def test_profile_gifts_reject_out_of_range_telegram_id(new_customer):
    viewer = await new_customer()
    # Larger than a Postgres bigint: rejected up front instead of failing in the database with a 500.
    # Negative ids are groups/channels (TDLib chat ids), so only zero and out-of-range values are invalid.
    for bad in ("0", str(1 << 63), str(-(1 << 63))):
        assert (await viewer.get(f"/v1/gifts/users/{bad}")).status_code == 422, bad


async def test_profile_background_needs_link_validates_and_clears(client, new_customer):
    alice, viewer = await new_customer(), await new_customer()
    blocked = await alice.put("/v1/profile/background", json={"background": "#ff5c8a"})
    assert blocked.json()["detail"]["code"] == "TELEGRAM_NOT_LINKED"

    await _link(client, alice, 333)
    for bad in ("red", "#FF5C8A", "#ff5c8a,#12", "#ff5c8a;#000000", "#ff5c8a,#000000,#111111"):
        assert (await alice.put("/v1/profile/background", json={"background": bad})).status_code == 422, bad

    assert (await viewer.get("/v1/gifts/users/333")).json()["background"] is None
    assert (await alice.put("/v1/profile/background", json={"background": "#ff5c8a,#8b6cff"})).status_code == 200
    assert (await viewer.get("/v1/gifts/users/333")).json()["background"] == "#ff5c8a,#8b6cff"
    assert (await alice.put("/v1/profile/background", json={"background": "#26c6b0"})).status_code == 200
    assert (await viewer.get("/v1/gifts/users/333")).json()["background"] == "#26c6b0"

    assert (await alice.put("/v1/profile/background", json={"background": None})).status_code == 200
    assert (await viewer.get("/v1/gifts/users/333")).json()["background"] is None


async def test_hide_all_gifts_switch_and_dearest_first(client, session_factory, new_customer):
    admin = await _admin(session_factory)
    heart, crown = await _gift(client, admin, title="Yurak", price=3_000), await _gift(client, admin, title="Toj", price=40_000)
    alice, bob, viewer = await new_customer(), await new_customer(), await new_customer()
    await _link(client, alice, 444)
    await _link(client, bob, 555)
    await _top_up(client, admin, alice, 50_000)
    for gift in (crown, heart):  # the cheap one is the newest
        assert (await alice.post("/v1/gifts/send", json={"gift_id": gift["id"], "recipient_telegram_id": 555})).status_code == 201
    titles = [g["gift"]["title"] for g in (await viewer.get("/v1/gifts/users/555")).json()["items"]]
    assert titles == ["Toj", "Yurak"]

    await bob.put("/v1/profile/background", json={"background": "#26c6b0"})
    assert (await bob.put("/v1/profile/gifts-visibility", json={"hidden": True})).json()["hide_all"] is True
    profile = (await viewer.get("/v1/gifts/users/555")).json()
    assert profile["items"] == [] and profile["total"] == 0 and profile["background"] == "#26c6b0"
    received = (await bob.get("/v1/gifts/received")).json()
    assert received["hide_all"] is True and len(received["items"]) == 2

    # Clearing the background keeps the switch; turning the switch off brings the gifts back.
    await bob.put("/v1/profile/background", json={"background": None})
    assert (await viewer.get("/v1/gifts/users/555")).json()["items"] == []
    assert (await bob.put("/v1/profile/gifts-visibility", json={"hidden": False})).status_code == 200
    profile = (await viewer.get("/v1/gifts/users/555")).json()
    assert profile["total"] == 2 and profile["background"] is None
    assert (await bob.get("/v1/gifts/received")).json()["hide_all"] is False


async def test_premium_gift_carries_its_video(client, session_factory, new_customer):
    admin = await _admin(session_factory)
    fake_mp4 = b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 64
    created = await client.post("/v1/admin/gifts", headers=admin, data={"title": "Sher", "price_uzs": "100000"},
                                files={"file": ("lev.webp", FAKE_WEBP, "image/webp"), "video": ("lev.mp4", fake_mp4, "video/mp4")})
    assert created.status_code == 201, created.text
    assert created.json()["video_url"].endswith(".mp4")
    plain = await _gift(client, admin, title="Yurak")
    assert plain["video_url"] is None and plain["effect"] is None
    async with session_factory() as db:
        db.add(GiftItem(title="Samolyot", price_uzs=50_000, animation="plane.webp", effect="plane"))
        await db.commit()

    not_video = await client.post("/v1/admin/gifts", headers=admin, data={"title": "Soxta", "price_uzs": "1000"},
                                  files={"file": ("a.webp", FAKE_WEBP, "image/webp"), "video": ("a.mp4", FAKE_PNG, "video/mp4")})
    assert not_video.json()["detail"]["code"] == "NOT_A_GIFT_VIDEO"

    catalog = (await (await new_customer()).get("/v1/gifts/catalog")).json()["items"]
    lion = next(g for g in catalog if g["title"] == "Sher")
    assert (await client.get(lion["video_url"])).headers["content-type"] == "video/mp4"
    plane = next(g for g in catalog if g["title"] == "Samolyot")
    assert plane["effect"] == "plane" and plane["video_url"] is None and plane["show_url"] is None


async def test_admin_bonus_credits_the_balance(client, session_factory, new_customer):
    finance = await _admin(session_factory, AdminRole.FINANCE)
    support = await _admin(session_factory)
    dave = await new_customer()
    await _link(client, dave, 7777)
    body = {"telegram_user_id": 7777, "amount_uzs": 15_000, "reason": "Keshbek: aksiya"}

    assert (await client.post("/v1/admin/gifts/credit", headers=support, json=body)).status_code == 403
    missing = await client.post("/v1/admin/gifts/credit", headers=finance, json=body | {"telegram_user_id": 9999})
    assert missing.json()["detail"]["code"] == "TELEGRAM_NOT_LINKED"
    assert (await client.post("/v1/admin/gifts/credit", headers=finance, json=body | {"amount_uzs": -5})).status_code == 422

    credited = await client.post("/v1/admin/gifts/credit", headers=finance, json=body)
    assert credited.status_code == 200, credited.text
    assert credited.json()["balance_uzs"] == 15_000
    # Each credit is its own ledger line, never deduplicated away.
    assert (await client.post("/v1/admin/gifts/credit", headers=finance, json=body)).json()["balance_uzs"] == 30_000

    wallet = (await dave.get("/v1/wallet")).json()
    assert wallet["balance_uzs"] == 30_000
    assert [e["kind"] for e in wallet["entries"]] == ["bonus", "bonus"]
    incoming = (await dave.get("/v1/wallet/history", params={"direction": "in"})).json()["items"]
    assert len(incoming) == 2


async def test_admin_bonus_by_customer_picked_in_the_users_list(client, session_factory, new_customer):
    finance = await _admin(session_factory, AdminRole.FINANCE)
    erin = await new_customer()  # never linked Telegram: the users list still reaches them
    body = {"customer_id": erin.id, "amount_uzs": 5_000, "reason": "Keshbek"}

    both = await client.post("/v1/admin/gifts/credit", headers=finance, json=body | {"telegram_user_id": 1})
    assert both.status_code == 422
    neither = await client.post("/v1/admin/gifts/credit", headers=finance, json={"amount_uzs": 5_000, "reason": "Keshbek"})
    assert neither.status_code == 422
    unknown = await client.post("/v1/admin/gifts/credit", headers=finance, json=body | {"customer_id": str(uuid.uuid4())})
    assert unknown.json()["detail"]["code"] == "CUSTOMER_NOT_FOUND"

    credited = await client.post("/v1/admin/gifts/credit", headers=finance, json=body)
    assert credited.status_code == 200, credited.text
    assert credited.json()["balance_uzs"] == 5_000
    detail = (await client.get(f"/v1/admin/customers/{erin.id}", headers=finance)).json()
    assert detail["wallet_uzs"] == 5_000
