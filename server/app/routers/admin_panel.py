"""What the web admin panel needs beyond review: dashboard stats, editable settings, admin accounts, shop detail.
Changes are audited like every other admin action."""

import uuid
from datetime import UTC, datetime, timedelta
from typing import Annotated, Any
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, status
from pydantic import BaseModel, Field, StringConstraints
from sqlalchemy import Date, cast, func, literal_column, select

from app.deps import DbDep, require_admin
from app.errors import bad_request, conflict, not_found
from app.market import product_out, profile_out, shop_out
from app.models import (
    AdCampaign,
    AdminRole,
    AdminUser,
    AdStatus,
    AppSetting,
    Customer,
    CustomerProfile,
    ListingStatus,
    Product,
    Shop,
)
from app.security import hash_password, new_secret, sha256_hex
from app.services.audit import audit
from app.services.market_settings import load_market_settings

router = APIRouter(prefix="/v1/admin", tags=["admin"])

Viewer = Annotated[AdminUser, Depends(require_admin(AdminRole.VIEWER))]
Support = Annotated[AdminUser, Depends(require_admin(AdminRole.SUPPORT))]
Owner = Annotated[AdminUser, Depends(require_admin(AdminRole.OWNER))]

STATS_DAYS = 30


TASHKENT = ZoneInfo("Asia/Tashkent")


def _day(column: Any) -> Any:
    """Calendar day in Uzbekistan time, so the daily charts match what admins see on their clocks."""
    # A literal, not a bound parameter: Postgres must see the SELECT and GROUP BY expressions as identical.
    return cast(func.timezone(literal_column("'Asia/Tashkent'"), column), Date)


@router.get("/stats")
async def stats(admin: Viewer, db: DbDep) -> dict[str, Any]:
    """Dashboard numbers: users, shops and ads by status, revenue from approved payments, last 30 days by day."""
    now = datetime.now(UTC)
    since = now - timedelta(days=STATS_DAYS)
    active = Customer.deleted_at.is_(None)
    users_total = await db.scalar(select(func.count()).select_from(Customer).where(active)) or 0
    users_7d = await db.scalar(select(func.count()).select_from(Customer).where(active, Customer.created_at >= now - timedelta(days=7))) or 0
    shops = dict((s.value, n) for s, n in (await db.execute(select(Shop.status, func.count()).group_by(Shop.status))).all())
    ads = dict((s.value, n) for s, n in (await db.execute(select(AdCampaign.status, func.count()).group_by(AdCampaign.status))).all())
    products = await db.scalar(select(func.count()).select_from(Product).where(Product.active.is_(True))) or 0
    ad_revenue = await db.scalar(select(func.coalesce(func.sum(AdCampaign.price_uzs), 0)).where(AdCampaign.status == AdStatus.APPROVED)) or 0
    shop_revenue = await db.scalar(
        select(func.coalesce(func.sum(Shop.price_uzs), 0)).where(Shop.status.in_((ListingStatus.APPROVED, ListingStatus.CLOSED)))
    ) or 0
    live_ads = await db.scalar(
        select(func.count()).select_from(AdCampaign).where(
            AdCampaign.status == AdStatus.APPROVED, AdCampaign.starts_at <= now, AdCampaign.ends_at > now
        )
    ) or 0
    new_users = dict(
        (await db.execute(
            select(_day(Customer.created_at), func.count()).where(active, Customer.created_at >= since).group_by(_day(Customer.created_at))
        )).all()
    )
    ad_income = dict(
        (await db.execute(
            select(_day(AdCampaign.starts_at), func.sum(AdCampaign.price_uzs))
            .where(AdCampaign.status == AdStatus.APPROVED, AdCampaign.starts_at >= since)
            .group_by(_day(AdCampaign.starts_at))
        )).all()
    )
    today = datetime.now(TASHKENT).date()
    days = [today - timedelta(days=i) for i in range(STATS_DAYS - 1, -1, -1)]
    return {
        "users": {"total": users_total, "new_7d": users_7d},
        "shops": shops,
        "ads": ads,
        "products_active": products,
        "ads_live": live_ads,
        "revenue_uzs": {"ads": int(ad_revenue), "shops": int(shop_revenue), "total": int(ad_revenue) + int(shop_revenue)},
        "daily": [{"date": d.isoformat(), "new_users": new_users.get(d, 0), "ad_income_uzs": int(ad_income.get(d) or 0)} for d in days],
    }


# ------------------------------------------------------------------ settings


class SettingsIn(BaseModel):
    ad_price_per_region_day_uzs: Annotated[int, Field(ge=0, le=100_000_000)] | None = None
    ad_payment_card: Annotated[str, StringConstraints(strip_whitespace=True, max_length=32, pattern=r"^[0-9 ]*$")] | None = None
    ad_payment_card_holder: Annotated[str, StringConstraints(strip_whitespace=True, max_length=64)] | None = None
    extra_shop_price_uzs: Annotated[int, Field(ge=0, le=100_000_000)] | None = None
    shop_free_limit: Annotated[int, Field(ge=0, le=50)] | None = None
    app_version: Annotated[str, StringConstraints(strip_whitespace=True, max_length=20, pattern=r"^[0-9A-Za-z.+-]*$")] | None = None
    app_build: Annotated[int, Field(ge=0, le=1_000_000)] | None = None
    app_release_notes: Annotated[str, StringConstraints(strip_whitespace=True, max_length=2000)] | None = None


@router.get("/settings")
async def get_market_settings(admin: Viewer, db: DbDep) -> dict[str, Any]:
    return vars(await load_market_settings(db))


@router.put("/settings")
async def update_market_settings(body: SettingsIn, admin: Owner, db: DbDep) -> dict[str, Any]:
    changes = body.model_dump(exclude_none=True)
    if not changes:
        raise bad_request("NOTHING_TO_UPDATE")
    for key, value in changes.items():
        row = await db.get(AppSetting, key)
        if row is None:
            db.add(AppSetting(key=key, value=str(value), updated_by=admin.name))
        else:
            row.value = str(value)
            row.updated_by = admin.name
    # The card number is personal data: the log keeps only that it changed.
    audit(db, f"admin:{admin.name}", "settings_updated", "app_settings",
          **{k: ("***" if k == "ad_payment_card" else v) for k, v in changes.items()})
    await db.commit()
    return vars(await load_market_settings(db))


# ------------------------------------------------------------------ admin accounts


class AdminIn(BaseModel):
    name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=2, max_length=64, pattern=r"^[A-Za-z0-9._-]+$")]
    role: AdminRole


class AdminPatch(BaseModel):
    role: AdminRole | None = None
    active: bool | None = None


def _admin_out(admin: AdminUser) -> dict[str, Any]:
    return {
        "id": str(admin.id), "name": admin.name, "role": admin.role.value, "active": admin.active,
        "login": admin.login, "created_at": admin.created_at.isoformat(),
    }


class CredentialsIn(BaseModel):
    login: Annotated[str, StringConstraints(strip_whitespace=True, min_length=3, max_length=64, pattern=r"^[A-Za-z0-9._@+-]+$")]
    password: Annotated[str, StringConstraints(min_length=6, max_length=128)]


@router.get("/admins")
async def list_admins(admin: Owner, db: DbDep) -> list[dict[str, Any]]:
    return [_admin_out(a) for a in await db.scalars(select(AdminUser).order_by(AdminUser.created_at))]


@router.post("/admins", status_code=status.HTTP_201_CREATED)
async def create_admin(body: AdminIn, admin: Owner, db: DbDep) -> dict[str, Any]:
    if await db.scalar(select(AdminUser.id).where(AdminUser.name == body.name)) is not None:
        raise conflict("ADMIN_NAME_TAKEN")
    key = new_secret(32)
    created = AdminUser(name=body.name, key_hash=sha256_hex(key), role=body.role)
    db.add(created)
    audit(db, f"admin:{admin.name}", "admin_created", body.name, role=body.role.value)
    await db.commit()
    await db.refresh(created)
    # The key is shown once; only its hash is stored.
    return _admin_out(created) | {"key": key}


@router.patch("/admins/{admin_id}")
async def update_admin(admin_id: uuid.UUID, body: AdminPatch, admin: Owner, db: DbDep) -> dict[str, Any]:
    target = await db.get(AdminUser, admin_id)
    if target is None:
        raise not_found("ADMIN_NOT_FOUND")
    # Nobody locks themselves out or drops their own owner role by accident.
    if target.id == admin.id and (body.active is False or (body.role is not None and body.role != AdminRole.OWNER)):
        raise conflict("CANNOT_CHANGE_OWN_ACCESS")
    if body.role is not None:
        target.role = body.role
    if body.active is not None:
        target.active = body.active
    audit(db, f"admin:{admin.name}", "admin_updated", target.name, role=target.role.value, active=target.active)
    await db.commit()
    return _admin_out(target)


@router.put("/admins/{admin_id}/credentials")
async def set_admin_credentials(admin_id: uuid.UUID, body: CredentialsIn, admin: Owner, db: DbDep) -> dict[str, Any]:
    """Login and password for the web panel; the admin's key keeps working."""
    target = await db.get(AdminUser, admin_id)
    if target is None:
        raise not_found("ADMIN_NOT_FOUND")
    taken = await db.scalar(select(AdminUser.id).where(AdminUser.login == body.login, AdminUser.id != target.id))
    if taken is not None:
        raise conflict("LOGIN_TAKEN")
    target.login = body.login
    target.password_hash = hash_password(body.password)
    audit(db, f"admin:{admin.name}", "admin_credentials_set", target.name, login=body.login)
    await db.commit()
    return _admin_out(target)


# ------------------------------------------------------------------ products


class ProductVisibilityIn(BaseModel):
    active: bool
    reason: Annotated[str, StringConstraints(strip_whitespace=True, min_length=3, max_length=256)]


@router.post("/products/{product_id}/visibility")
async def set_product_visibility(product_id: uuid.UUID, body: ProductVisibilityIn, admin: Support, db: DbDep) -> dict[str, Any]:
    """Takes a single product off sale (or back) without touching the rest of the shop."""
    product = await db.get(Product, product_id)
    if product is None:
        raise not_found("PRODUCT_NOT_FOUND")
    product.active = body.active
    audit(db, f"admin:{admin.name}", "product_shown" if body.active else "product_hidden", str(product.id),
          shop=product.shop_id, reason=body.reason)
    await db.commit()
    return product_out(product, private=True)


# ------------------------------------------------------------------ shop detail


@router.get("/shops/{shop_id}")
async def shop_detail(shop_id: uuid.UUID, admin: Support, db: DbDep) -> dict[str, Any]:
    shop = await db.get(Shop, shop_id)
    if shop is None:
        raise not_found("SHOP_NOT_FOUND")
    owner = await db.get(CustomerProfile, shop.owner_id)
    products = list(await db.scalars(select(Product).where(Product.shop_id == shop.id).order_by(Product.created_at.desc())))
    audit(db, f"admin:{admin.name}", "shop_viewed", str(shop.id))
    await db.commit()
    return shop_out(shop, product_count=len(products), private=True) | {
        "owner": profile_out(owner),
        "products": [product_out(p, private=True) for p in products],
    }
