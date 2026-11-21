"""Quick links: admins pin sites/apps to every user's hub row; the app gets the live ones in position order."""

from datetime import timedelta

import pytest

from app.models import AdminRole
from app.routers.quick_links import _today
from tests.test_music import _admin

pytestmark = pytest.mark.asyncio(loop_scope="session")

URL = "/v1/admin/quick-links"
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64


async def test_admin_pins_links_and_the_app_sees_live_ones_in_order(client, session_factory, new_customer):
    admin = await _admin(client, session_factory)
    second = await client.post(URL, headers=admin, data={"title": "Uzum", "url": "uzum.uz", "position": "2",
                                                         "android_package": "uz.uzum.app"})
    assert second.status_code == 201, second.text
    assert second.json()["url"] == "https://uzum.uz" and second.json()["logo_url"] == ""
    first = await client.post(URL, headers=admin, data={"title": "Bank", "url": "https://bank.uz/app", "position": "1",
                                                        "note": "1 oy to'langan"}, files={"logo": ("l.png", PNG, "image/png")})
    assert first.status_code == 201, first.text
    assert first.json()["logo_url"].startswith("/media/") and first.json()["logo_url"].endswith(".png")
    expired = (_today() - timedelta(days=1)).isoformat()
    await client.post(URL, headers=admin, data={"title": "Old", "url": "old.uz", "until": expired})
    await client.post(URL, headers=admin, data={"title": "Off", "url": "off.uz", "active": "false"})
    await client.post(URL, headers=admin, data={"title": "Today", "url": "today.uz", "position": "3", "until": _today().isoformat()})

    customer = await new_customer()
    items = (await customer.get("/v1/quick-links")).json()["items"]
    assert [i["title"] for i in items] == ["Bank", "Uzum", "Today"]  # expired and switched-off ones are hidden
    assert items[1]["android_package"] == "uz.uzum.app"
    assert "note" not in items[0]  # payment notes stay with admins

    listed = (await client.get(URL, headers=admin)).json()
    assert listed["total"] == 5
    assert {i["title"]: i["live"] for i in listed["items"]} == {"Bank": True, "Uzum": True, "Today": True, "Old": False, "Off": False}

    link_id = second.json()["id"]
    moved = await client.put(f"{URL}/{link_id}", headers=admin, data={"title": "Uzum Market", "url": "uzum.uz", "position": "1"},
                             files={"logo": ("l.png", PNG, "image/png")})
    assert moved.status_code == 200, moved.text
    assert moved.json()["logo_url"] and moved.json()["android_package"] == ""
    cleared = await client.put(f"{URL}/{link_id}", headers=admin, data={"title": "Uzum Market", "url": "uzum.uz", "remove_logo": "true"})
    assert cleared.json()["logo_url"] == ""

    assert (await client.delete(f"{URL}/{link_id}", headers=admin)).status_code == 204
    assert (await client.delete(f"{URL}/{link_id}", headers=admin)).status_code == 404
    assert [i["title"] for i in (await customer.get("/v1/quick-links")).json()["items"]] == ["Bank", "Today"]


@pytest.mark.parametrize("data", [
    {"title": " ", "url": "uzum.uz"},
    {"title": "X", "url": "not a link"},
    {"title": "X", "url": "javascript:alert(1)"},
    {"title": "X", "url": "localhost"},
    {"title": "X", "url": "uzum.uz", "android_package": "bad package"},
    {"title": "X", "url": "uzum.uz", "position": "0"},
])
async def test_rejects_bad_links(client, session_factory, data):
    admin = await _admin(client, session_factory)
    response = await client.post(URL, headers=admin, data=data)
    assert response.status_code in (400, 422), response.text


async def test_logo_must_be_an_image(client, session_factory):
    admin = await _admin(client, session_factory)
    response = await client.post(URL, headers=admin, data={"title": "X", "url": "x.uz"}, files={"logo": ("l.txt", b"hello", "text/plain")})
    assert response.status_code == 400


async def test_viewers_and_customers_cannot_change_links(client, session_factory, new_customer):
    viewer = await _admin(client, session_factory, AdminRole.VIEWER)
    assert (await client.post(URL, headers=viewer, data={"title": "X", "url": "x.uz"})).status_code == 403
    assert (await client.get(URL, headers=viewer)).status_code == 200
    assert (await (await new_customer()).get(URL)).status_code in (401, 403)
