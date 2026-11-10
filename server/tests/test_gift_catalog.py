"""Rendered gifts: the manifest is validated, imported into the one gift catalog, prices stay server-side."""

import json

import pytest
from sqlalchemy import func, select

from app.models import GiftItem
from app.services.gift_catalog import import_rendered_gifts, parse_manifest
from app.uploads import public_dir
from tests.test_gifts import _admin, _link, _top_up, gifts_bot  # noqa: F401 (autouse fixture)

pytestmark = pytest.mark.asyncio(loop_scope="session")


def _entry(key: str, price: int = 5_000, tier: int = 1) -> dict:
    return {"id": key, "tier": tier, "price_uzs": price, "duration_ms": 3500, "title": {"uz": f"{key} uz", "ru": f"{key} ru", "en": f"{key} en"},
            "files": {"show": f"{key}.webp", "icon": f"{key}_icon.webp", "sound": f"{key}.mp3"}}


def _folder(tmp_path, entries: list[dict], *, skip_file: str = ""):
    for entry in entries:
        for name in entry["files"].values():
            if name != skip_file and "/" not in name:
                (tmp_path / name).write_bytes(b"RIFF....WEBP" if name.endswith(".webp") else b"ID3\x04" + bytes(64))
    (tmp_path / "manifest.json").write_text(json.dumps({"gifts": entries}), encoding="utf-8")
    return tmp_path / "manifest.json"


def test_parses_a_valid_manifest(tmp_path):
    gifts = parse_manifest(_folder(tmp_path, [_entry("rose_bloom"), _entry("universe", 1_000_000, 4)]))
    assert [(g.key, g.tier, g.price_uzs, g.duration_ms) for g in gifts] == [("rose_bloom", 1, 5000, 3500), ("universe", 4, 1_000_000, 3500)]
    assert gifts[0].titles == {"uz": "rose_bloom uz", "ru": "rose_bloom ru", "en": "rose_bloom en"}


@pytest.mark.parametrize(("change", "problem"), [
    (lambda e: e.update(tier=5), "tier"),
    (lambda e: e.update(price_uzs=0), "price"),
    (lambda e: e.update(price_uzs="5000"), "price"),
    (lambda e: e.update(duration_ms=60_000), "duration"),
    (lambda e: e["title"].pop("ru"), "title"),
    (lambda e: e.update(id="Bad Id"), "bad id"),
    (lambda e: e["files"].update(show="source/rose.webp"), "files must be"),
])
def test_rejects_bad_entries(tmp_path, change, problem):
    entry = _entry("rose_bloom")
    change(entry)
    with pytest.raises(ValueError, match=problem):
        parse_manifest(_folder(tmp_path, [entry]))


def test_rejects_missing_files_and_duplicates(tmp_path):
    with pytest.raises(ValueError, match="missing rose_bloom.mp3"):
        parse_manifest(_folder(tmp_path, [_entry("rose_bloom")], skip_file="rose_bloom.mp3"))
    with pytest.raises(ValueError, match="duplicate"):
        parse_manifest(_folder(tmp_path, [_entry("kitten"), _entry("kitten")]))


async def test_import_adds_new_upgrades_old_and_keeps_prices(tmp_path, session_factory):
    async with session_factory() as db:
        db.add(GiftItem(title="Sher", price_uzs=100_000, animation="old-lion.webp", effect="lion", sort=1020))
        await db.commit()
    gifts = parse_manifest(_folder(tmp_path, [_entry("rose_bloom"), _entry("lion", 300_000, 3)]))

    async with session_factory() as db:
        assert await import_rendered_gifts(db, gifts) == (1, 1)
        await db.commit()
    async with session_factory() as db:
        assert await import_rendered_gifts(db, gifts) == (0, 2)  # running it again changes nothing
        await db.commit()
        rows = {g.key: g for g in await db.scalars(select(GiftItem))}
        assert await db.scalar(select(func.count()).select_from(GiftItem)) == 2

    lion, rose = rows["lion"], rows["rose_bloom"]
    assert lion.price_uzs == 100_000 and lion.sort == 1020  # the older gift keeps its price and place
    assert lion.title_en == "lion en" and lion.tier == 3 and lion.effect == "lion"
    assert rose.price_uzs == 5_000 and rose.duration_ms == 3500
    for name in (rose.show, rose.animation, rose.sound, lion.show, lion.sound):
        assert (public_dir() / name).is_file()


async def test_catalog_and_send_use_the_server_price(tmp_path, client, session_factory, new_customer):
    async with session_factory() as db:
        await import_rendered_gifts(db, parse_manifest(_folder(tmp_path, [_entry("universe", 1_000_000, 4)])))
        await db.commit()
    admin = await _admin(session_factory)
    customer = await new_customer()
    await _link(client, customer, 777_001)
    gift = (await customer.get("/v1/gifts/catalog")).json()["items"][0]
    assert gift["tier"] == 4 and gift["duration_ms"] == 3500 and gift["titles"]["ru"] == "universe ru"
    assert gift["sound_url"].endswith(".mp3") and gift["show_url"].endswith(".webp")

    await _top_up(client, admin, customer, 999_000)
    short = await customer.post("/v1/gifts/send", json={"gift_id": gift["id"], "recipient_telegram_id": 42, "price_uzs": 1})
    assert short.status_code == 409  # a price sent by the app is ignored
    await _top_up(client, admin, customer, 1_000)
    sent = await customer.post("/v1/gifts/send", json={"gift_id": gift["id"], "recipient_telegram_id": 42})
    assert sent.status_code == 201 and sent.json()["balance_uzs"] == 0
    unknown = await customer.post("/v1/gifts/send", json={"gift_id": "00000000-0000-0000-0000-000000000000", "recipient_telegram_id": 42})
    assert unknown.status_code == 404
