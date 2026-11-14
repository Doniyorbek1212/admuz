"""Quick links: sites and apps admins pin to every user's hub "Tezkor" row (paid placement), before the user's own."""

import re
import uuid
from datetime import date, datetime
from pathlib import Path
from typing import Annotated, Any
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, File, Form, UploadFile, status
from sqlalchemy import or_, select

from app.deps import CustomerDep, DbDep, require_admin
from app.errors import bad_request, not_found
from app.models import AdminRole, AdminUser, QuickLink
from app.services.audit import audit
from app.uploads import public_dir, save_public_image

router = APIRouter(prefix="/v1/quick-links", tags=["hub"])
admin_router = APIRouter(prefix="/v1/admin/quick-links", tags=["admin"])

Viewer = Annotated[AdminUser, Depends(require_admin(AdminRole.VIEWER))]
Support = Annotated[AdminUser, Depends(require_admin(AdminRole.SUPPORT))]

TASHKENT = ZoneInfo("Asia/Tashkent")
URL = re.compile(r"^https?://[^\s/?#]+\.[^\s/?#]+(?:[/?#]\S*)?$", re.IGNORECASE)
PACKAGE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$")


def _today() -> date:
    return datetime.now(TASHKENT).date()


def _out(row: QuickLink) -> dict[str, Any]:
    return {"id": str(row.id), "title": row.title, "url": row.url, "logo_url": f"/media/{row.logo}" if row.logo else "",
            "android_package": row.android_package}


def _admin_out(row: QuickLink) -> dict[str, Any]:
    return _out(row) | {"position": row.position, "active": row.active, "until": row.until.isoformat() if row.until else None,
                        "note": row.note, "live": row.active and (row.until is None or row.until >= _today()),
                        "created_at": row.created_at.isoformat()}


def _clean(title: str, url: str, android_package: str) -> tuple[str, str, str]:
    title, url, android_package = title.strip(), url.strip(), android_package.strip()
    if not title:
        raise bad_request("TITLE_REQUIRED")
    if "://" not in url:
        url = f"https://{url}"
    if not URL.fullmatch(url):
        raise bad_request("URL_INVALID")
    if android_package and not PACKAGE.fullmatch(android_package):
        raise bad_request("PACKAGE_INVALID")
    return title, url, android_package


def _drop_logo(name: str) -> None:
    if name:
        (public_dir() / Path(name).name).unlink(missing_ok=True)


@router.get("")
async def live_links(current: CustomerDep, db: DbDep) -> dict[str, Any]:
    """Links every user sees, in the order admins pinned them."""
    rows = await db.scalars(
        select(QuickLink)
        .where(QuickLink.active.is_(True), or_(QuickLink.until.is_(None), QuickLink.until >= _today()))
        .order_by(QuickLink.position, QuickLink.created_at)
    )
    return {"items": [_out(r) for r in rows]}


async def _row(db: DbDep, link_id: uuid.UUID) -> QuickLink:
    row = await db.get(QuickLink, link_id)
    if row is None:
        raise not_found("QUICK_LINK_NOT_FOUND")
    return row


Title = Annotated[str, Form(max_length=40)]
Url = Annotated[str, Form(max_length=500)]
Package = Annotated[str, Form(max_length=150)]
Position = Annotated[int, Form(ge=1, le=99)]
Note = Annotated[str, Form(max_length=300)]
Logo = Annotated[UploadFile | None, File()]


@admin_router.get("")
async def list_links(admin: Viewer, db: DbDep) -> dict[str, Any]:
    rows = list(await db.scalars(select(QuickLink).order_by(QuickLink.position, QuickLink.created_at)))
    return {"items": [_admin_out(r) for r in rows], "total": len(rows)}


@admin_router.post("", status_code=status.HTTP_201_CREATED)
async def add_link(admin: Support, db: DbDep, title: Title, url: Url, android_package: Package = "", position: Position = 1,
                   active: Annotated[bool, Form()] = True, until: Annotated[date | None, Form()] = None, note: Note = "",
                   logo: Logo = None) -> dict[str, Any]:
    title, url, android_package = _clean(title, url, android_package)
    row = QuickLink(title=title, url=url, android_package=android_package, position=position, active=active, until=until,
                    note=note.strip(), logo=await save_public_image(logo) if logo is not None else "")
    db.add(row)
    await db.flush()
    audit(db, admin.name, "quick_link_added", str(row.id), title=row.title, url=row.url, position=row.position)
    await db.commit()
    await db.refresh(row)
    return _admin_out(row)


@admin_router.put("/{link_id}")
async def update_link(link_id: uuid.UUID, admin: Support, db: DbDep, title: Title, url: Url, android_package: Package = "",
                      position: Position = 1, active: Annotated[bool, Form()] = True, until: Annotated[date | None, Form()] = None,
                      note: Note = "", logo: Logo = None,
                      remove_logo: Annotated[bool, Form()] = False) -> dict[str, Any]:
    row = await _row(db, link_id)
    row.title, row.url, row.android_package = _clean(title, url, android_package)
    row.position, row.active, row.until, row.note = position, active, until, note.strip()
    old_logo = ""
    if logo is not None or remove_logo:
        old_logo = row.logo
        row.logo = await save_public_image(logo) if logo is not None else ""
    audit(db, admin.name, "quick_link_updated", str(row.id), title=row.title, url=row.url, position=row.position,
          active=row.active, until=row.until.isoformat() if row.until else None)
    await db.commit()
    # Only once the row no longer points at it: a failed commit keeps the old logo working.
    _drop_logo(old_logo)
    await db.refresh(row)
    return _admin_out(row)


@admin_router.delete("/{link_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_link(link_id: uuid.UUID, admin: Support, db: DbDep) -> None:
    row = await _row(db, link_id)
    audit(db, admin.name, "quick_link_deleted", str(row.id), title=row.title, url=row.url)
    logo = row.logo
    await db.delete(row)
    await db.commit()
    _drop_logo(logo)
