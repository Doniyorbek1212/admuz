"""Avatar frames: the manifest import, buying once from the balance, wearing one at a time, the public lookup."""

import json

import pytest
from sqlalchemy import delete

from app.models import FrameItem, OwnedFrame
from app.services.frame_catalog import import_rendered_frames, parse_manifest
from app.uploads import public_dir
from tests.test_gifts import _admin, _link, _top_up, gifts_bot  # noqa: F401  (fixture used by autouse)

pytestmark = pytest.mark.asyncio(loop_scope="session")


def _entry(key: str, price: int = 20_000, tier: int = 1) -> dict:
    return {"id": key, "tier": tier, "price_uzs": price, "title": {"uz": f"{key} uz", "ru": f"{key} ru", "en": f"{key} en"},
            "files": {"full": f"{key}.webp", "small": f"{key}_small.webp"}}


def _folder(tmp_path, entries: list[dict], *, skip_file: str = "", size: int = 12):
    for entry in entries:
        for name in entry["files"].values():
            if name != skip_file and "/" not in name:
                (tmp_path / name).write_bytes(b"RIFF....WEBP" + bytes(max(0, size - 12)))
    (tmp_path / "manifest.json").write_text(json.dumps({"frames": entries}), encoding="utf-8")
    return tmp_path / "manifest.json"


async def _frames(session_factory, *items: tuple[str, int]) -> None:
    async with session_factory() as db:
        await db.execute(delete(FrameItem).where(FrameItem.key.in_([k for k, _ in items])))
        for index, (key, price) in enumerate(items):
            db.add(FrameItem(key=key, title=key, title_ru="", title_en="", tier=1, price_uzs=price,
                             animation=f"{key}.webp", small=f"{key}_s.webp", sort=index, active=True))
        await db.commit()


def test_parses_a_valid_manifest(tmp_path):
    frames = parse_manifest(_folder(tmp_path, [_entry("gold_laurel"), _entry("cosmic", 75_000, 4)]))
    assert [(f.key, f.tier, f.price_uzs) for f in frames] == [("gold_laurel", 1, 20_000), ("cosmic", 4, 75_000)]
    assert frames[0].titles == {"uz": "gold_laurel uz", "ru": "gold_laurel ru", "en": "gold_laurel en"}


@pytest.mark.parametrize(("change", "problem"), [
    (lambda e: e.update(tier=0), "tier"),
    (lambda e: e.update(price_uzs=-1), "price"),
    (lambda e: e["title"].pop("en"), "title"),
    (lambda e: e.update(id="../x"), "bad id"),
    (lambda e: e["files"].update(full="source/gold.webp"), "files must be"),
])
def test_rejects_bad_entries(tmp_path, change, problem):
    entry = _entry("gold_laurel")
    change(entry)
    with pytest.raises(ValueError, match=problem):
        parse_manifest(_folder(tmp_path, [entry]))


def test_rejects_missing_oversized_and_duplicate_files(tmp_path):
    with pytest.raises(ValueError, match="missing gold_laurel_small.webp"):
        parse_manifest(_folder(tmp_path, [_entry("gold_laurel")], skip_file="gold_laurel_small.webp"))
    with pytest.raises(ValueError, match="too big"):
        parse_manifest(_folder(tmp_path, [_entry("gold_laurel")], size=700 << 10))
    with pytest.raises(ValueError, match="duplicate"):
        parse_manifest(_folder(tmp_path, [_entry("sakura"), _entry("sakura")]))


async def test_import_adds_then_upgrades_and_keeps_the_price(tmp_path, session_factory):
    frames = parse_manifest(_folder(tmp_path, [_entry("imp_frame", 30_000)]))
    async with session_factory() as db:
        await db.execute(delete(FrameItem).where(FrameItem.key == "imp_frame"))
        assert await import_rendered_frames(db, frames) == (1, 0)
        await db.commit()
        row = await db.get(FrameItem, "imp_frame")
        row.price_uzs = 45_000  # an admin's later price
        await db.commit()
    again = parse_manifest(_folder(tmp_path, [_entry("imp_frame", 30_000) | {"title": {"uz": "Yangi", "ru": "Новая", "en": "New"}}]))
    async with session_factory() as db:
        assert await import_rendered_frames(db, again) == (0, 1)
        await db.commit()
        row = await db.get(FrameItem, "imp_frame")
        assert (row.price_uzs, row.title, row.title_en) == (45_000, "Yangi", "New")
        assert (public_dir() / row.animation).is_file() and (public_dir() / row.small).is_file()


async def test_buy_wear_switch_and_lookup(client, session_factory, new_customer):
    admin = await _admin(session_factory)
    await _frames(session_factory, ("frame_a", 20_000), ("frame_b", 15_000))
    alice, bob = await new_customer(), await new_customer()

    catalog = (await alice.get("/v1/frames/catalog")).json()
    assert catalog["linked"] is False and catalog["owned"] == [] and catalog["equipped"] is None
    item = next(i for i in catalog["items"] if i["key"] == "frame_a")
    assert item["animation_url"] == "/media/frame_a.webp" and item["small_url"] == "/media/frame_a_s.webp"
    assert (await alice.post("/v1/frames/buy", json={"key": "frame_a"})).json()["detail"]["code"] == "TELEGRAM_NOT_LINKED"

    await _link(client, alice, 7201)
    await _link(client, bob, 7202)
    assert (await alice.post("/v1/frames/buy", json={"key": "frame_a"})).json()["detail"]["code"] == "INSUFFICIENT_BALANCE"
    assert (await alice.post("/v1/frames/buy", json={"key": "nope_frame"})).json()["detail"]["code"] == "FRAME_NOT_FOUND"

    await _top_up(client, admin, alice, 40_000)
    bought = await alice.post("/v1/frames/buy", json={"key": "frame_a"})
    assert bought.status_code == 200, bought.text
    assert bought.json() == {"linked": True, "owned": ["frame_a"], "equipped": "frame_a", "balance_uzs": 20_000}
    assert (await alice.post("/v1/frames/buy", json={"key": "frame_a"})).json()["detail"]["code"] == "FRAME_OWNED"

    # A second frame is worn right away; the first stays owned.
    second = (await alice.post("/v1/frames/buy", json={"key": "frame_b"})).json()
    assert second["owned"] == ["frame_a", "frame_b"] and second["equipped"] == "frame_b" and second["balance_uzs"] == 5_000
    spent = [i for i in (await alice.get("/v1/wallet/history")).json()["items"] if i["kind"] == "frame"]
    assert [(i["delta_uzs"], i["title"]) for i in spent] == [(-15_000, "frame_b"), (-20_000, "frame_a")]

    seen = (await bob.get("/v1/frames/of", params={"ids": [7201, 7202]})).json()["frames"]
    assert seen == {"7201": "frame_b"}

    # Switching and taking it off are free; only owned frames can be worn.
    assert (await alice.put("/v1/frames/me", json={"key": "frame_a"})).json()["equipped"] == "frame_a"
    assert (await bob.put("/v1/frames/me", json={"key": "frame_a"})).json()["detail"]["code"] == "FRAME_NOT_OWNED"
    off = (await alice.put("/v1/frames/me", json={"key": None})).json()
    assert off["equipped"] is None and off["balance_uzs"] == 5_000
    assert (await bob.get("/v1/frames/of", params={"ids": [7201]})).json()["frames"] == {}

    # A frame taken off sale can no longer be bought, but owners keep it.
    async with session_factory() as db:
        (await db.get(FrameItem, "frame_a")).active = False
        await db.commit()
    await _top_up(client, admin, bob, 40_000)
    assert (await bob.post("/v1/frames/buy", json={"key": "frame_a"})).json()["detail"]["code"] == "FRAME_NOT_FOUND"
    assert (await alice.put("/v1/frames/me", json={"key": "frame_a"})).json()["equipped"] == "frame_a"
    async with session_factory() as db:
        assert await db.get(OwnedFrame, (7201, "frame_a")) is not None


async def test_requests_are_validated(client, new_customer):
    customer = await new_customer()
    assert (await customer.get("/v1/frames/of")).status_code == 422
    assert (await customer.get("/v1/frames/of", params={"ids": list(range(1, 102))})).status_code == 422
    assert (await customer.post("/v1/frames/buy", json={"key": "Bad Key"})).status_code == 422
    assert (await customer.put("/v1/frames/me", json={"key": "x" * 40})).status_code == 422
