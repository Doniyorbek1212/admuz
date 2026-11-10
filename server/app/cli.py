"""Operational commands.

    python -m app.cli create-admin <name> <viewer|support|finance|owner> [--key-file PATH]
    python -m app.cli rotate-key <name> [--key-file PATH]   (new permanent key; the old one stops working)
    python -m app.cli revoke-key <name>                     (permanent key stops working; login stays)
    python -m app.cli set-login <name> <login> <password>    (also ends the admin's open panel sessions)
    python -m app.cli list-admins
    python -m app.cli release-expired-reservations
    python -m app.cli import-places [region ...]   (all regions when none given; OpenStreetMap via Overpass)
    python -m app.cli seed-gifts                    (starter gift catalog, only while the catalog is empty)
    python -m app.cli seed-premium-gifts            (drawn gifts: Samolyot, Vertolyot, Sher; adds or upgrades)
    python -m app.cli set-gifts-webhook <https://host>   (points the gifts bot at <host>/v1/telegram/webhook)
    python -m app.cli import-gift-renders <folder>  (rendered gifts from <folder>/manifest.json; adds or upgrades, keeps prices)
"""

import asyncio
import json
import os
import shutil
import sys
import urllib.request
import uuid
from pathlib import Path

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import SessionFactory
from app.deps import get_redis, revoke_admin_sessions
from app.market import REGIONS
from app.models import AdminRole, AdminUser, GiftItem
from app.routers.gifts import webhook_secret
from app.security import hash_password, new_secret, sha256_hex
from app.services import credits, gift_catalog, osm_import
from app.services.audit import audit
from app.uploads import public_dir


def _hand_over_key(name: str, key: str, key_file: str | None) -> None:
    """Gives a new permanent key to the operator once; only its hash is stored."""
    if key_file:
        # Owner-only file instead of the terminal, so the key stays out of scrollback and CI logs.
        fd = os.open(key_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(key + "\n")
        print(f"admin key for {name} written to {key_file}; read it once, then delete the file")
        return
    print("warning: the key is printed to this terminal; prefer --key-file", file=sys.stderr)
    print(f"admin key for {name}: {key}")


async def _admin(db, name: str) -> AdminUser:
    admin = await db.scalar(select(AdminUser).where(AdminUser.name == name))
    if admin is None:
        print(f"no admin named {name}")
        sys.exit(1)
    return admin


async def create_admin(name: str, role: str, key_file: str | None) -> None:
    key = new_secret(32)
    async with SessionFactory() as db:
        db.add(AdminUser(name=name, key_hash=sha256_hex(key), role=AdminRole(role)))
        audit(db, "cli", "admin_created", name, role=role)
        await db.commit()
    _hand_over_key(name, key, key_file)


async def rotate_key(name: str, key_file: str | None) -> None:
    key = new_secret(32)
    async with SessionFactory() as db:
        admin = await _admin(db, name)
        admin.key_hash = sha256_hex(key)
        audit(db, "cli", "admin_key_rotated", name)
        await db.commit()
    _hand_over_key(name, key, key_file)


async def revoke_key(name: str) -> None:
    async with SessionFactory() as db:
        admin = await _admin(db, name)
        # The column is unique and required: a hash of a secret nobody knows disables the key.
        admin.key_hash = sha256_hex(new_secret(32))
        audit(db, "cli", "admin_key_revoked", name)
        await db.commit()
    print(f"permanent key of {name} revoked")


async def set_login(name: str, login: str, password: str) -> None:
    from pydantic import ValidationError

    from app.routers.admin_panel import CredentialsIn

    try:
        CredentialsIn(login=login, password=password)  # same rules as the panel: 10+ characters, not the login
    except ValidationError as exc:
        print(f"refused: {exc.errors()[0]['msg']}")
        sys.exit(1)
    async with SessionFactory() as db:
        admin = await _admin(db, name)
        admin.login = login
        admin.password_hash = hash_password(password)
        audit(db, "cli", "admin_credentials_set", name, login=login)
        await db.commit()
        ended = await revoke_admin_sessions(admin.id)
    await get_redis().aclose()
    print(f"login set for {name}: {login}; {ended} open session(s) ended")


async def list_admins() -> None:
    async with SessionFactory() as db:
        for admin in await db.scalars(select(AdminUser).order_by(AdminUser.created_at)):
            print(f"{admin.name}	{admin.role.value}	active={admin.active}	login={admin.login or '-'}")


async def release_expired() -> None:
    async with SessionFactory() as db:
        released = await credits.release_expired(db)
    print(f"released {released} expired reservations")


async def import_places(regions: list[str]) -> None:
    unknown = [r for r in regions if r not in REGIONS]
    if unknown:
        print(f"unknown regions: {', '.join(unknown)}")
        sys.exit(1)
    for region in regions or REGIONS:
        async with SessionFactory() as db:
            count = await osm_import.import_region(db, region)
        print(f"{region}: {count} places")
        # Overpass is a shared public service: pause between regions.
        await asyncio.sleep(5)


# Noto Animated Emoji by Google (CC BY 4.0), resized to 256 px: file in app/gift_seed, title, price in so'm.
STARTER_GIFTS = (
    ("2764_fe0f.webp", "Yurak", 3_000),
    ("1f525.webp", "Olov", 3_000),
    ("2b50.webp", "Yulduz", 4_000),
    ("1f339.webp", "Atirgul", 5_000),
    ("1f389.webp", "Bayram", 6_000),
    ("1f381.webp", "Sovg'a qutisi", 7_000),
    ("1f496.webp", "Sevgi", 8_000),
    ("1f490.webp", "Guldasta", 10_000),
    ("1f382.webp", "Tort", 12_000),
    ("1f308.webp", "Kamalak", 15_000),
    ("1f3c6.webp", "Kubok", 25_000),
    ("1f680.webp", "Raketa", 30_000),
    ("1f451.webp", "Toj", 40_000),
    ("1f48e.webp", "Olmos", 50_000),
    ("1f48d.webp", "Uzuk", 60_000),
)
GIFT_SEED_DIR = Path(__file__).resolve().parent / "gift_seed"


async def seed_gifts() -> None:
    async with SessionFactory() as db:
        if await db.scalar(select(func.count()).select_from(GiftItem)):
            print("gift catalog is not empty; nothing seeded")
            return
        public_dir().mkdir(parents=True, exist_ok=True)
        for sort, (file, title, price) in enumerate(STARTER_GIFTS):
            name = f"{uuid.uuid4()}.webp"
            shutil.copyfile(GIFT_SEED_DIR / file, public_dir() / name)
            db.add(GiftItem(title=title, price_uzs=price, animation=name, sort=sort * 10))
        await db.commit()
    print(f"seeded {len(STARTER_GIFTS)} gifts")


# Premium gifts the app draws over the screen (GiftItem.effect): (animation, effect, title, price in so'm).
# Noto Animated Emoji by Google (CC BY 4.0), 192 px.
PREMIUM_GIFTS = (
    ("2708_fe0f.webp", "plane", "Samolyot", 50_000),
    ("1f681.webp", "helicopter", "Vertolyot", 70_000),
    ("1f981.webp", "lion", "Sher", 100_000),
)


async def seed_premium_gifts() -> None:
    async with SessionFactory() as db:
        public_dir().mkdir(parents=True, exist_ok=True)
        changed = 0
        for index, (animation, effect, title, price) in enumerate(PREMIUM_GIFTS):
            gift = await db.scalar(select(GiftItem).where(GiftItem.title == title))
            if gift is not None and gift.effect:
                continue
            name = f"{uuid.uuid4()}.webp"
            shutil.copyfile(GIFT_SEED_DIR / animation, public_dir() / name)
            sort = 1000 + index * 10
            if gift is None:
                db.add(GiftItem(title=title, price_uzs=price, animation=name, effect=effect, sort=sort))
            else:
                # An older video gift of the same name becomes the drawn one; copies already sent follow it.
                gift.animation, gift.effect, gift.video, gift.sort = name, effect, "", sort
            changed += 1
        await db.flush()
        changed += await _attach_shows(db)
        await db.commit()
    print(f"premium gifts added or updated: {changed}")


# Rendered shows: gift_seed/shows/<effect>.webp (full screen, transparent) and <effect>_icon.webp (shop and bubbles).
SHOWS_DIR = GIFT_SEED_DIR / "shows"


async def _attach_shows(db: AsyncSession) -> int:
    """Gives each effect gift without a show its rendered one, and the render's icon as its picture."""
    attached = 0
    for gift in await db.scalars(select(GiftItem).where(GiftItem.effect != "", GiftItem.show == "")):
        show = SHOWS_DIR / f"{gift.effect}.webp"
        if not show.is_file():
            continue
        gift.show = f"{uuid.uuid4()}.webp"
        shutil.copyfile(show, public_dir() / gift.show)
        icon = SHOWS_DIR / f"{gift.effect}_icon.webp"
        if icon.is_file():
            gift.animation = f"{uuid.uuid4()}.webp"
            shutil.copyfile(icon, public_dir() / gift.animation)
        attached += 1
    return attached


async def import_gift_renders(folder: Path) -> None:
    gifts = gift_catalog.parse_manifest(folder / "manifest.json")
    async with SessionFactory() as db:
        added, updated = await gift_catalog.import_rendered_gifts(db, gifts)
        audit(db, "cli", "gift_renders_imported", folder.name, added=added, updated=updated)
        await db.commit()
    print(f"rendered gifts: {added} added, {updated} updated")


def set_gifts_webhook(host: str) -> None:
    token = get_settings().gifts_bot_token
    if not token or not host.startswith("https://"):
        print("needs SADO_BILLING_GIFTS_BOT_TOKEN and an https:// host")
        sys.exit(1)
    body = json.dumps({
        "url": f"{host.rstrip('/')}/v1/telegram/webhook",
        "secret_token": webhook_secret(),
        "allowed_updates": ["message"],
        "drop_pending_updates": True,
    }).encode()
    request = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/setWebhook", data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        print(json.loads(response.read()).get("description", "done"))


def main() -> None:
    match sys.argv[1:]:
        case ["seed-gifts"]:
            asyncio.run(seed_gifts())
        case ["seed-premium-gifts"]:
            asyncio.run(seed_premium_gifts())
        case ["set-gifts-webhook", host]:
            set_gifts_webhook(host)
        case ["import-gift-renders", folder]:
            asyncio.run(import_gift_renders(Path(folder)))
        case ["create-admin", name, role]:
            asyncio.run(create_admin(name, role, None))
        case ["create-admin", name, role, "--key-file", path]:
            asyncio.run(create_admin(name, role, path))
        case ["rotate-key", name]:
            asyncio.run(rotate_key(name, None))
        case ["rotate-key", name, "--key-file", path]:
            asyncio.run(rotate_key(name, path))
        case ["revoke-key", name]:
            asyncio.run(revoke_key(name))
        case ["set-login", name, login, password]:
            asyncio.run(set_login(name, login, password))
        case ["list-admins"]:
            asyncio.run(list_admins())
        case ["release-expired-reservations"]:
            asyncio.run(release_expired())
        case ["import-places", *regions]:
            asyncio.run(import_places(regions))
        case _:
            print(__doc__)
            sys.exit(2)


if __name__ == "__main__":
    main()
