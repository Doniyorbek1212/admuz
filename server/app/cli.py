"""Operational commands.

    python -m app.cli create-admin <name> <viewer|support|finance|owner>
    python -m app.cli set-login <name> <login> <password>
    python -m app.cli list-admins
    python -m app.cli release-expired-reservations
    python -m app.cli import-places [region ...]   (all regions when none given; OpenStreetMap via Overpass)
"""

import asyncio
import sys

from sqlalchemy import select

from app.db import SessionFactory
from app.market import REGIONS
from app.models import AdminRole, AdminUser
from app.security import hash_password, new_secret, sha256_hex
from app.services import credits, osm_import
from app.services.audit import audit


async def create_admin(name: str, role: str) -> None:
    key = new_secret(32)
    async with SessionFactory() as db:
        db.add(AdminUser(name=name, key_hash=sha256_hex(key), role=AdminRole(role)))
        audit(db, "cli", "admin_created", name, role=role)
        await db.commit()
    # Printed once; only the hash is stored.
    print(f"admin key for {name} ({role}): {key}")


async def set_login(name: str, login: str, password: str) -> None:
    async with SessionFactory() as db:
        admin = await db.scalar(select(AdminUser).where(AdminUser.name == name))
        if admin is None:
            print(f"no admin named {name}")
            sys.exit(1)
        admin.login = login
        admin.password_hash = hash_password(password)
        audit(db, "cli", "admin_credentials_set", name, login=login)
        await db.commit()
    print(f"login set for {name}: {login}")


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
            asyncio.run(create_admin(name, role))
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
