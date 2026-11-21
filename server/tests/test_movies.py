"""Hub movies: admin creates a title, uploads a video in resumable chunks, the pipeline publishes it, the app lists it."""

import uuid

import pytest

from app.config import get_settings
from app.models import AdminRole, AdminUser
from app.security import new_secret, sha256_hex
from app.services import movies

pytestmark = pytest.mark.asyncio(loop_scope="session")

FAKE_MP4 = b"\x00\x00\x00\x20ftypisom" + b"\x00" * 500


async def _admin(client, session_factory) -> dict[str, str]:
    key = new_secret()
    async with session_factory() as db:
        db.add(AdminUser(name=f"movies-{uuid.uuid4().hex[:6]}", key_hash=sha256_hex(key), role=AdminRole.SUPPORT))
        await db.commit()
    return {"X-Admin-Key": key}


@pytest.fixture
def telegram(monkeypatch):
    """Pipeline without ffmpeg or Telegram: 'compression' halves the file, the post gets message id 77."""
    settings = get_settings()
    for name, value in {"tg_api_id": 1, "tg_api_hash": "h", "movies_bot_token": "1:t", "movies_channel": "uzaro_kino"}.items():
        monkeypatch.setattr(settings, name, value)
    info = movies.VideoInfo(duration=5400, width=1280, height=720)

    async def compress(video_id, src, dst, _info):
        dst.write_bytes(src.read_bytes()[: src.stat().st_size // 2])
        return info

    async def probe(_path):
        return info

    async def thumb(*_args):
        return None

    posted = []

    async def post(video_id, path, thumb_path, video_info, caption):
        posted.append(caption)
        return 77

    monkeypatch.setattr(movies, "compress", compress)
    monkeypatch.setattr(movies, "probe", probe)
    monkeypatch.setattr(movies, "make_thumb", thumb)
    monkeypatch.setattr(movies, "post_to_channel", post)
    return posted


async def test_chunked_upload_publish_and_listing(client, session_factory, new_customer, telegram):
    admin = await _admin(client, session_factory)
    title = (await client.post("/v1/admin/movies", json={"kind": "series", "title": "Mehr", "year": 2024, "genres": "drama"}, headers=admin)).json()
    data = FAKE_MP4 * 4
    started = await client.post(f"/v1/admin/movies/{title['id']}/videos",
                                json={"season": 1, "episode": 2, "file_name": "mehr.mkv", "size_bytes": len(data)}, headers=admin)
    assert started.status_code == 201, started.text
    video_id = started.json()["id"]
    url = f"/v1/admin/movies/videos/{video_id}/content"

    half = len(data) // 2
    first = await client.put(url, params={"offset": 0}, content=data[:half], headers=admin)
    assert first.status_code == 200 and first.json()["status"] == "uploading"
    # A resumed upload with a stale offset is told where the server is.
    stale = await client.put(url, params={"offset": 0}, content=data[:half], headers=admin)
    assert stale.status_code == 409
    done = await client.put(url, params={"offset": half}, content=data[half:], headers=admin)
    assert done.json()["status"] == "queued" and done.json()["uploaded_bytes"] == len(data)

    customer = await new_customer()
    assert (await customer.get("/v1/movies")).json()["total"] == 0  # nothing published yet

    claimed = await movies._claim_next()
    assert str(claimed) == video_id
    await movies.process(claimed)
    assert telegram == ["Mehr · 1-fasl 2-qism"]
    assert not movies.source_path(claimed).exists()  # local copy gone once it is on Telegram

    listed = (await customer.get("/v1/movies", params={"kind": "series"})).json()
    assert [t["title"] for t in listed["items"]] == ["Mehr"]
    detail = (await customer.get(f"/v1/movies/{title['id']}")).json()
    assert detail["videos"][0]["channel"] == "uzaro_kino"
    assert detail["videos"][0]["message_id"] == 77 and detail["videos"][0]["duration_seconds"] == 5400

    assert (await customer.get("/v1/movies/categories")).json() == [{"name": "drama", "count": 1}]
    for params, total in (({"category": "Drama"}, 1), ({"category": "dram"}, 0), ({"q": "2024"}, 1), ({"q": "mehr drama"}, 1), ({"q": "komediya"}, 0)):
        assert (await customer.get("/v1/movies", params=params)).json()["total"] == total, params

    stats = (await client.get("/v1/admin/movies/stats", headers=admin)).json()
    assert stats["videos"]["ready"] == 1 and stats["ready_original_bytes"] == len(data) and stats["ready_compressed_bytes"] == half


async def test_upload_guards(client, session_factory, telegram):
    admin = await _admin(client, session_factory)
    title = (await client.post("/v1/admin/movies", json={"kind": "movie", "title": "Sinov"}, headers=admin)).json()
    too_big = await client.post(f"/v1/admin/movies/{title['id']}/videos", json={"size_bytes": 10**13}, headers=admin)
    assert too_big.status_code == 400

    video = (await client.post(f"/v1/admin/movies/{title['id']}/videos", json={"size_bytes": 1000}, headers=admin)).json()
    not_video = await client.put(f"/v1/admin/movies/videos/{video['id']}/content", params={"offset": 0}, content=b"<html>" * 100, headers=admin)
    assert not_video.status_code == 400 and not_video.json()["detail"]["code"] == "NOT_A_VIDEO"
    assert (await client.post(f"/v1/admin/movies/{title['id']}/videos", json={"size_bytes": 10}, headers={"X-Admin-Key": "nope"})).status_code == 401


async def test_failure_keeps_original_for_retry(client, session_factory, telegram, monkeypatch):
    admin = await _admin(client, session_factory)
    title = (await client.post("/v1/admin/movies", json={"kind": "movie", "title": "Uzun kino"}, headers=admin)).json()
    video = (await client.post(f"/v1/admin/movies/{title['id']}/videos", json={"size_bytes": len(FAKE_MP4)}, headers=admin)).json()
    await client.put(f"/v1/admin/movies/videos/{video['id']}/content", params={"offset": 0}, content=FAKE_MP4, headers=admin)

    async def broken(*_args):
        raise movies.MovieError("Siqishda xato: test")

    monkeypatch.setattr(movies, "compress", broken)
    await movies.process(await movies._claim_next())
    failed = (await client.get(f"/v1/admin/movies/videos/{video['id']}", headers=admin)).json()
    assert failed["status"] == "failed" and "test" in failed["error"]
    assert movies.source_path(uuid.UUID(video["id"])).exists()

    retried = await client.post(f"/v1/admin/movies/videos/{video['id']}/retry", headers=admin)
    assert retried.json()["status"] == "queued"
    assert (await client.delete(f"/v1/admin/movies/{title['id']}", headers=admin)).status_code == 204
    assert not movies.source_path(uuid.UUID(video["id"])).exists()


async def test_activity_counts_distinct_users_per_period(client, session_factory, new_customer):
    admin = await _admin(client, session_factory)
    first, second = await new_customer(), await new_customer()
    for customer, event in ((first, "app_open"), (first, "app_open"), (first, "hub_open"), (second, "app_open"), (second, "movies_open")):
        assert (await customer.post("/v1/activity", json={"event": event})).status_code == 204
    assert (await first.post("/v1/activity", json={"event": "hack"})).status_code == 422
    stats = (await client.get("/v1/admin/activity", headers=admin)).json()
    assert stats["totals"]["app_open"] == {"day": 2, "week": 2, "month": 2, "year": 2}
    assert stats["totals"]["hub_open"]["day"] == 1 and stats["totals"]["movies_open"]["year"] == 1
    assert len(stats["daily"]) == 30 and stats["daily"][-1]["app_open"] == 2
