"""Rendered avatar frames from frame_renders/manifest.json into the frame shop.

Each entry becomes (or upgrades) one FrameItem keyed by its id: the profile-size frame with the UZARO plate and the
small chat-list frame are copied to the public media dir. Re-running is safe; price and place are set only when the
frame is new, so an admin's later price and order stay. Packs come from the CLI or the admin panel's upload.
"""

import json
import re
from dataclasses import dataclass
from pathlib import Path

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import FrameItem
from app.services.gift_catalog import KEY, LANGS, MAX_MANIFEST_BYTES, MAX_PRICE_UZS, _check, _publish
from app.uploads import public_dir

MAX_BYTES = {"full": 640 << 10, "small": 256 << 10}
PACK_FILE = re.compile(r"[a-z][a-z0-9_]{1,31}\.webp")


def pack_file_limit(name: str) -> int:
    """Byte cap for a file taken into a frame pack, or 0 when the importer does not take that name."""
    if name == "manifest.json":
        return MAX_MANIFEST_BYTES
    return MAX_BYTES["full"] if PACK_FILE.fullmatch(name) else 0


@dataclass(frozen=True)
class RenderedFrame:
    key: str
    tier: int
    price_uzs: int
    titles: dict[str, str]
    full: Path
    small: Path


def parse_manifest(path: Path) -> list[RenderedFrame]:
    """Validates the whole manifest first; raises ValueError naming the bad entry so nothing is half-imported."""
    data = json.loads(path.read_text(encoding="utf-8"))
    entries = data.get("frames") if isinstance(data, dict) else None
    _check(isinstance(entries, list) and len(entries) > 0, path.name, "no frames list")
    frames: list[RenderedFrame] = []
    for index, entry in enumerate(entries):
        where = f"frame #{index + 1}"
        _check(isinstance(entry, dict), where, "not an object")
        key = entry.get("id")
        _check(isinstance(key, str) and KEY.fullmatch(key) is not None, where, f"bad id {key!r}")
        where = key
        tier, price = entry.get("tier"), entry.get("price_uzs")
        _check(type(tier) is int and 1 <= tier <= 4, where, "tier must be 1-4")
        _check(type(price) is int and 0 < price <= MAX_PRICE_UZS, where, "bad price_uzs")
        titles = entry.get("title") or {}
        _check(all(isinstance(titles.get(lang), str) and 0 < len(titles[lang].strip()) <= 64 for lang in LANGS), where, "needs uz/ru/en title")
        expected = {"full": f"{key}.webp", "small": f"{key}_small.webp"}
        _check(entry.get("files") == expected, where, f"files must be {expected}")
        for kind, name in expected.items():
            file = path.parent / name
            _check(file.is_file(), where, f"missing {name}")
            _check(0 < file.stat().st_size <= MAX_BYTES[kind], where, f"{name} is empty or too big")
        frames.append(RenderedFrame(
            key=key, tier=tier, price_uzs=price, titles={lang: titles[lang].strip() for lang in LANGS},
            full=path.parent / expected["full"], small=path.parent / expected["small"],
        ))
    keys = [f.key for f in frames]
    _check(len(set(keys)) == len(keys), path.name, "duplicate ids")
    return frames


async def import_rendered_frames(db: AsyncSession, frames: list[RenderedFrame]) -> tuple[int, int]:
    """Adds new frames after the existing ones and upgrades existing ones by key, keeping their price and place.
    Returns (added, updated)."""
    public_dir().mkdir(parents=True, exist_ok=True)
    added = updated = 0
    next_sort = (await db.scalar(select(func.max(FrameItem.sort))) or 0) + 1
    for frame in frames:
        row = await db.scalar(select(FrameItem).where(FrameItem.key == frame.key))
        if row is None:
            row = FrameItem(key=frame.key, price_uzs=frame.price_uzs, sort=next_sort, animation="", small="")
            db.add(row)
            added += 1
            next_sort += 1
        else:
            updated += 1
        row.title, row.title_ru, row.title_en = frame.titles["uz"], frame.titles["ru"], frame.titles["en"]
        row.tier = frame.tier
        row.animation = _publish(frame.full, row.animation)
        row.small = _publish(frame.small, row.small)
    await db.flush()
    return added, updated
