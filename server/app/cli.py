"""Operational commands.

    python -m app.cli create-admin <name> <viewer|support|finance|owner> [--key-file PATH]
    python -m app.cli rotate-key <name> [--key-file PATH]   (new permanent key; the old one stops working)
    python -m app.cli revoke-key <name>                     (permanent key stops working; login stays)
    python -m app.cli set-login <name> <login> <password>    (also ends the admin's open panel sessions)
    python -m app.cli list-admins
    python -m app.cli release-expired-reservations
    python -m app.cli import-places [region ...]   (all regions when none given; OpenStreetMap via Overpass)
"""

import asyncio
import os
import sys

from sqlalchemy import select

from app.db import SessionFactory
from app.deps import get_redis, revoke_admin_sessions
from app.market import REGIONS
from app.models import AdminRole, AdminUser
from app.security import hash_password, new_secret, sha256_hex
from app.services import credits, osm_import
from app.services.audit import audit


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


def main() -> None:
    match sys.argv[1:]:
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
