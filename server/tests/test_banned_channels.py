"""Banned channels: admins add, edit and delete them; the app gets usernames, plus titles of entries without one."""

import re
from pathlib import Path

import pytest

from tests.test_music import _admin

pytestmark = pytest.mark.asyncio(loop_scope="session")

URL = "/v1/admin/banned-channels"


async def test_admin_crud_and_app_list(client, session_factory, new_customer):
    admin = await _admin(client, session_factory)
    by_link = await client.post(URL, headers=admin, json={"title": "Nashiды", "username": "https://t.me/Some_Channel/93", "note": "№1"})
    assert by_link.status_code == 201, by_link.text
    assert by_link.json()["username"] == "Some_Channel"
    by_title = await client.post(URL, headers=admin, json={"title": "Jannatga Oshiqlar"})
    assert by_title.status_code == 201
    invite = await client.post(URL, headers=admin, json={"username": "t.me/+OhDKQIjAJMo30DUy"})
    assert invite.json()["username"] == "+OhDKQIjAJMo30DUy"

    customer = await new_customer()
    app_list = (await customer.get("/v1/banned-channels")).json()
    # A username entry is matched by its username only, so its (generic) title is not sent.
    assert app_list == {"usernames": ["+ohdkqijajmo30duy", "some_channel"], "titles": ["Jannatga Oshiqlar"]}

    channel_id = by_title.json()["id"]
    off = await client.put(f"{URL}/{channel_id}", headers=admin, json={"title": "Jannatga Oshiqlar", "active": False})
    assert off.status_code == 200 and off.json()["active"] is False
    assert (await customer.get("/v1/banned-channels")).json()["titles"] == []
    assert (await client.get(URL, headers=admin, params={"q": "jannat"})).json()["total"] == 1

    assert (await client.delete(f"{URL}/{channel_id}", headers=admin)).status_code == 204
    assert (await client.get(URL, headers=admin)).json()["total"] == 2
    assert (await client.delete(f"{URL}/{channel_id}", headers=admin)).status_code == 404


@pytest.mark.parametrize("body", [{}, {"title": "  "}, {"username": "bad name!"}, {"username": "abc"}])
async def test_rejects_empty_or_bad_entries(client, session_factory, body):
    admin = await _admin(client, session_factory)
    assert (await client.post(URL, headers=admin, json=body)).status_code == 422


async def test_viewers_cannot_change_the_list(client, session_factory, new_customer):
    from app.models import AdminRole

    viewer = await _admin(client, session_factory, AdminRole.VIEWER)
    assert (await client.post(URL, headers=viewer, json={"title": "X kanal"})).status_code == 403
    assert (await client.get(URL, headers=viewer)).status_code == 200
    assert (await (await new_customer()).get(URL)).status_code in (401, 403)


def test_seed_file_is_well_formed():
    seed = Path(__file__).parents[1] / "alembic" / "versions" / "0015_banned_channels.tsv"
    rows = [line.split("\t") for line in seed.read_text(encoding="utf-8").splitlines()]
    assert len(rows) > 800
    for title, username, note in rows:
        assert title or username
        assert not username or re.fullmatch(r"\+?[A-Za-z0-9_-]{4,64}", username)
        assert len(title) <= 300 and note.startswith("Oliy sud")
