"""Hub music: an admin uploads songs to the server by category, the app lists and streams them, delete removes the file."""

import uuid

import pytest

from app.models import AdminRole, AdminUser
from app.security import new_secret, sha256_hex
from app.uploads import public_dir

pytestmark = pytest.mark.asyncio(loop_scope="session")

FAKE_MP3 = b"ID3\x04\x00\x00\x00\x00\x00\x00" + b"\xff\xfb\x90\x00" * 200


async def _admin(client, session_factory, role: AdminRole = AdminRole.SUPPORT) -> dict[str, str]:
    key = new_secret()
    async with session_factory() as db:
        db.add(AdminUser(name=f"music-{uuid.uuid4().hex[:6]}", key_hash=sha256_hex(key), role=role))
        await db.commit()
    return {"X-Admin-Key": key}


async def _upload(client, admin, category: str, title: str, artist: str = "", data: bytes = FAKE_MP3):
    return await client.post("/v1/admin/music", headers=admin, files={"file": ("song.mp3", data, "audio/mpeg")},
                             data={"category": category, "title": title, "artist": artist, "duration_seconds": "215"})


async def test_upload_list_stream_and_delete(client, session_factory, new_customer):
    admin = await _admin(client, session_factory)
    car = await _upload(client, admin, "car", "Yo'l qo'shig'i", "Sevara")
    assert car.status_code == 201, car.text
    await _upload(client, admin, "uz_old", "Bahor", "Yulduz")
    customer = await new_customer()

    everything = (await customer.get("/v1/music")).json()
    assert everything["total"] == 2
    only_car = (await customer.get("/v1/music", params={"category": "car"})).json()
    assert [t["title"] for t in only_car["items"]] == ["Yo'l qo'shig'i"]
    assert only_car["items"][0]["duration_seconds"] == 215
    assert (await customer.get("/v1/music", params={"q": "yulduz"})).json()["total"] == 1

    audio = await client.get(only_car["items"][0]["audio_url"], headers={"Range": "bytes=0-9"})
    assert audio.status_code == 206 and audio.headers["content-type"] == "audio/mpeg"

    track_id = car.json()["id"]
    hidden = await client.put(f"/v1/admin/music/{track_id}", headers=admin, json={"category": "world", "title": "Yo'l", "active": False})
    assert hidden.status_code == 200 and hidden.json()["category"] == "world"
    assert (await customer.get("/v1/music")).json()["total"] == 1  # hidden songs leave the app
    listed = (await client.get("/v1/admin/music", headers=admin)).json()
    assert listed["total"] == 2 and listed["counts"]["world"] == 1

    path = public_dir() / car.json()["audio_url"].rsplit("/", 1)[1]
    assert path.exists()
    assert (await client.delete(f"/v1/admin/music/{track_id}", headers=admin)).status_code == 204
    assert not path.exists()


async def test_upload_refuses_non_audio_and_viewers(client, session_factory):
    admin = await _admin(client, session_factory)
    not_audio = await _upload(client, admin, "world", "Rasm", data=b"\x89PNG\r\n\x1a\n" + b"\x00" * 100)
    assert not_audio.status_code == 400 and not_audio.json()["detail"]["code"] == "NOT_AN_AUDIO"
    assert (await _upload(client, admin, "jazz", "Noto'g'ri bo'lim")).status_code == 422
    assert (await _upload(client, admin, "world", "   ")).status_code == 400
    viewer = await _admin(client, session_factory, AdminRole.VIEWER)
    assert (await _upload(client, viewer, "world", "Ruxsatsiz")).status_code == 403
