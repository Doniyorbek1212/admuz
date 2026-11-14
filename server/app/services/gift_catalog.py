"""Rendered premium gifts from gift_renders/manifest.json into the existing gift catalog.

Each manifest entry becomes (or upgrades) one GiftItem keyed by its id: the full-screen show, the looping icon and
the sound are copied to the public media dir. Re-running is safe. A price is set only when the gift is new: an
existing gift (such as the older drawn lion, plane and helicopter) keeps the price it has.
"""

import io
import json
import re
import shutil
import uuid
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import GiftItem
from app.uploads import public_dir

KEY = re.compile(r"[a-z][a-z0-9_]{1,31}")
LANGS = ("uz", "ru", "en")
MAX_PRICE_UZS = 50_000_000
MAX_BYTES = {"show": 8 << 20, "icon": 300 << 10, "sound": 2 << 20}
SORT_BASE = 2000  # after the starter and older premium gifts


@dataclass(frozen=True)
class RenderedGift:
    key: str
    tier: int
    price_uzs: int
    duration_ms: int
    titles: dict[str, str]
    show: Path
    icon: Path
    sound: Path


def _check(ok: bool, where: str, problem: str) -> None:
    if not ok:
        raise ValueError(f"{where}: {problem}")


def parse_manifest(path: Path) -> list[RenderedGift]:
    """Validates the whole manifest first; raises ValueError naming the bad entry so nothing is half-imported."""
    data = json.loads(path.read_text(encoding="utf-8"))
    entries = data.get("gifts") if isinstance(data, dict) else None
    _check(isinstance(entries, list) and len(entries) > 0, path.name, "no gifts list")
    gifts: list[RenderedGift] = []
    for index, entry in enumerate(entries):
        where = f"gift #{index + 1}"
        _check(isinstance(entry, dict), where, "not an object")
        key = entry.get("id")
        _check(isinstance(key, str) and KEY.fullmatch(key) is not None, where, f"bad id {key!r}")
        where = key
        tier, price, duration = entry.get("tier"), entry.get("price_uzs"), entry.get("duration_ms")
        _check(type(tier) is int and 1 <= tier <= 4, where, "tier must be 1-4")
        _check(type(price) is int and 0 < price <= MAX_PRICE_UZS, where, "bad price_uzs")
        _check(type(duration) is int and 1000 <= duration <= 15000, where, "duration_ms must be 1000-15000")
        titles = entry.get("title") or {}
        _check(all(isinstance(titles.get(lang), str) and 0 < len(titles[lang].strip()) <= 64 for lang in LANGS), where, "needs uz/ru/en title")
        files = entry.get("files") or {}
        # Only these exact names are taken from the folder (never source/, previews or anything else).
        expected = {"show": f"{key}.webp", "icon": f"{key}_icon.webp", "sound": f"{key}.mp3"}
        _check(files == expected, where, f"files must be {expected}")
        for kind, name in expected.items():
            file = path.parent / name
            _check(file.is_file(), where, f"missing {name}")
            _check(0 < file.stat().st_size <= MAX_BYTES[kind], where, f"{name} is empty or too big")
        gifts.append(RenderedGift(
            key=key, tier=tier, price_uzs=price, duration_ms=duration, titles={lang: titles[lang].strip() for lang in LANGS},
            show=path.parent / expected["show"], icon=path.parent / expected["icon"], sound=path.parent / expected["sound"],
        ))
    keys = [g.key for g in gifts]
    _check(len(set(keys)) == len(keys), path.name, "duplicate ids")
    return gifts


PACK_FILE = re.compile(r"[a-z][a-z0-9_]{1,31}(_icon)?\.(webp|mp3)")
MAX_MANIFEST_BYTES = 256 << 10
MAX_PACK_ENTRIES = 400


def extract_pack(data: bytes, dest: Path) -> list[RenderedGift]:
    """A ZIP of one rendered-gifts folder (manifest.json plus the files it names) unpacked into [dest] and validated.

    Only manifest.json and files named like gift files are taken, by base name, so paths inside the ZIP cannot
    escape [dest]; previews, Blender sources and anything else in the folder are skipped.
    """
    try:
        archive = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile as exc:
        raise ValueError("not a ZIP file") from exc
    with archive:
        entries = [e for e in archive.infolist() if not e.is_dir() and "__MACOSX" not in e.filename]
        _check(len(entries) <= MAX_PACK_ENTRIES, "ZIP", "too many files")
        paths = {e.filename: PurePosixPath(e.filename.replace("\\", "/")) for e in entries}
        manifests = [e for e in entries if paths[e.filename].name == "manifest.json"]
        _check(len(manifests) == 1, "ZIP", "needs exactly one manifest.json")
        root = paths[manifests[0].filename].parent
        for entry in entries:
            path = paths[entry.filename]
            limit = pack_file_limit(path.name)
            if path.parent != root or limit == 0:
                continue
            _check(entry.file_size <= limit, path.name, "too big")
            with archive.open(entry) as source:
                save_pack_file(dest, path.name, source.read(limit + 1))
    return parse_manifest(dest / "manifest.json")


def pack_file_limit(name: str) -> int:
    """Byte cap for a file taken into a pack, or 0 when the name is not one the importer takes."""
    if name == "manifest.json":
        return MAX_MANIFEST_BYTES
    return MAX_BYTES["show"] if PACK_FILE.fullmatch(name) else 0


def save_pack_file(dest: Path, name: str, body: bytes) -> None:
    """Writes one pack file flat into [dest] by base name; [name] must already pass pack_file_limit."""
    _check(len(body) <= pack_file_limit(name), name, "too big")
    (dest / name).write_bytes(body)


def _publish(source: Path, current: str) -> str:
    """Copies [source] to public media under a fresh name; keeps [current] when it already has the same bytes."""
    media = public_dir()
    if current and (media / current).is_file() and (media / current).read_bytes() == source.read_bytes():
        return current
    name = f"{uuid.uuid4()}{source.suffix}"
    shutil.copyfile(source, media / name)
    if current:
        (media / current).unlink(missing_ok=True)
    return name


async def import_rendered_gifts(db: AsyncSession, gifts: list[RenderedGift]) -> tuple[int, int]:
    """Adds new gifts and upgrades existing ones (by key, else an older drawn gift with that effect). Returns (added, updated)."""
    public_dir().mkdir(parents=True, exist_ok=True)
    added = updated = 0
    for index, gift in enumerate(gifts):
        row = await db.scalar(select(GiftItem).where(GiftItem.key == gift.key))
        if row is None:
            row = await db.scalar(select(GiftItem).where(GiftItem.key.is_(None), GiftItem.effect == gift.key))
        if row is None:
            row = GiftItem(price_uzs=gift.price_uzs, sort=SORT_BASE + index, animation="")
            db.add(row)
            added += 1
        else:
            updated += 1
        row.key, row.effect, row.video = gift.key, gift.key, ""
        row.title, row.title_ru, row.title_en = gift.titles["uz"], gift.titles["ru"], gift.titles["en"]
        row.tier, row.duration_ms = gift.tier, gift.duration_ms
        row.show = _publish(gift.show, row.show)
        row.animation = _publish(gift.icon, row.animation)
        row.sound = _publish(gift.sound, row.sound)
    await db.flush()
    return added, updated
