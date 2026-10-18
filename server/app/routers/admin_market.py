"""Admin review of hub ads and online shops (payment receipts, content, closing) and the customer list.
Every decision and every look at personal data is audited."""

import uuid
from datetime import UTC, datetime, timedelta
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, Query
from fastapi.responses import FileResponse
from pydantic import BaseModel, StringConstraints
from sqlalchemy import func, or_, select

from app.deps import DbDep, require_admin
from app.errors import conflict, not_found
from app.market import ad_out, profile_out, shop_out
from app.models import AdCampaign, AdminRole, AdminUser, AdStatus, Customer, CustomerProfile, Device, ListingStatus, Product, Shop
from app.services.audit import audit
from app.uploads import private_file

router = APIRouter(prefix="/v1/admin", tags=["admin"])

Viewer = Annotated[AdminUser, Depends(require_admin(AdminRole.VIEWER))]
Support = Annotated[AdminUser, Depends(require_admin(AdminRole.SUPPORT))]

ShopFilter = Literal["pending", "awaiting_payment", "approved", "rejected", "closed", "close_requested"]


class ReasonIn(BaseModel):
    reason: Annotated[str, StringConstraints(strip_whitespace=True, min_length=3, max_length=256)]


@router.get("/me")
async def whoami(admin: Viewer) -> dict[str, str]:
    return {"name": admin.name, "role": admin.role.value}


@router.get("/review/summary")
async def review_summary(admin: Viewer, db: DbDep) -> dict[str, int]:
    ads = await db.scalar(select(func.count()).select_from(AdCampaign).where(AdCampaign.status == AdStatus.PENDING_REVIEW))
    shops = await db.scalar(select(func.count()).select_from(Shop).where(Shop.status == ListingStatus.PENDING))
    closing = await db.scalar(
        select(func.count()).select_from(Shop).where(Shop.close_requested_at.is_not(None), Shop.status != ListingStatus.CLOSED)
    )
    users = await db.scalar(select(func.count()).select_from(Customer).where(Customer.deleted_at.is_(None)))
    return {"ads_pending": ads or 0, "shops_pending": shops or 0, "shops_closing": closing or 0, "users": users or 0}


# ------------------------------------------------------------------ ads


@router.get("/ads")
async def list_ads(
    admin: Viewer,
    db: DbDep,
    status: AdStatus = AdStatus.PENDING_REVIEW,
    limit: Annotated[int, Query(ge=1, le=200)] = 100,
) -> list[dict[str, Any]]:
    rows = await db.scalars(select(AdCampaign).where(AdCampaign.status == status).order_by(AdCampaign.created_at).limit(limit))
    return [ad_out(ad, private=True) for ad in rows]


async def _ad(db: DbDep, ad_id: uuid.UUID) -> AdCampaign:
    ad = await db.get(AdCampaign, ad_id)
    if ad is None:
        raise not_found("AD_NOT_FOUND")
    return ad


def _receipt_response(relative: str | None) -> FileResponse:
    path = private_file(relative) if relative else None
    if path is None:
        raise not_found("RECEIPT_NOT_FOUND")
    return FileResponse(path)


@router.get("/ads/{ad_id}/receipt")
async def ad_receipt(ad_id: uuid.UUID, admin: Support, db: DbDep) -> FileResponse:
    return _receipt_response((await _ad(db, ad_id)).receipt_path)


@router.post("/ads/{ad_id}/approve")
async def approve_ad(ad_id: uuid.UUID, admin: Support, db: DbDep) -> dict[str, Any]:
    ad = await _ad(db, ad_id)
    if ad.status != AdStatus.PENDING_REVIEW:
        raise conflict("AD_NOT_PENDING_REVIEW")
    now = datetime.now(UTC)
    ad.status = AdStatus.APPROVED
    ad.starts_at = now
    ad.ends_at = now + timedelta(days=ad.days)
    ad.reviewed_by = admin.name
    audit(db, f"admin:{admin.name}", "ad_approved", str(ad.id), price_uzs=ad.price_uzs, regions=",".join(ad.regions), days=ad.days)
    await db.commit()
    return ad_out(ad, private=True)


@router.post("/ads/{ad_id}/reject")
async def reject_ad(ad_id: uuid.UUID, body: ReasonIn, admin: Support, db: DbDep) -> dict[str, Any]:
    ad = await _ad(db, ad_id)
    if ad.status not in (AdStatus.PENDING_REVIEW, AdStatus.APPROVED):
        raise conflict("AD_NOT_REVIEWABLE")
    ad.status = AdStatus.REJECTED
    ad.reject_reason = body.reason
    ad.reviewed_by = admin.name
    ad.ends_at = None
    audit(db, f"admin:{admin.name}", "ad_rejected", str(ad.id), reason=body.reason)
    await db.commit()
    return ad_out(ad, private=True)


# ------------------------------------------------------------------ shops


@router.get("/shops")
async def list_shops(
    admin: Viewer,
    db: DbDep,
    status: ShopFilter = "pending",
    limit: Annotated[int, Query(ge=1, le=200)] = 100,
) -> list[dict[str, Any]]:
    counts = select(Product.shop_id, func.count().label("n")).group_by(Product.shop_id).subquery()
    stmt = select(Shop, func.coalesce(counts.c.n, 0), CustomerProfile).outerjoin(counts, counts.c.shop_id == Shop.id)
    stmt = stmt.outerjoin(CustomerProfile, CustomerProfile.customer_id == Shop.owner_id)
    if status == "close_requested":
        stmt = stmt.where(Shop.close_requested_at.is_not(None), Shop.status != ListingStatus.CLOSED)
    else:
        stmt = stmt.where(Shop.status == ListingStatus(status))
    rows = await db.execute(stmt.order_by(Shop.updated_at).limit(limit))
    return [shop_out(shop, product_count=n, private=True) | {"owner": profile_out(profile)} for shop, n, profile in rows.all()]


async def _shop(db: DbDep, shop_id: uuid.UUID) -> Shop:
    shop = await db.get(Shop, shop_id)
    if shop is None:
        raise not_found("SHOP_NOT_FOUND")
    return shop


@router.get("/shops/{shop_id}/receipt")
async def shop_receipt(shop_id: uuid.UUID, admin: Support, db: DbDep) -> FileResponse:
    return _receipt_response((await _shop(db, shop_id)).receipt_path)


@router.post("/shops/{shop_id}/approve")
async def approve_shop(shop_id: uuid.UUID, admin: Support, db: DbDep) -> dict[str, Any]:
    shop = await _shop(db, shop_id)
    if shop.status in (ListingStatus.CLOSED, ListingStatus.AWAITING_PAYMENT):
        raise conflict("SHOP_NOT_REVIEWABLE")
    if shop.price_uzs and shop.receipt_path is None:
        raise conflict("RECEIPT_REQUIRED")
    shop.status = ListingStatus.APPROVED
    shop.reject_reason = None
    audit(db, f"admin:{admin.name}", "shop_approved", str(shop.id), price_uzs=shop.price_uzs)
    await db.commit()
    return shop_out(shop, private=True)


@router.post("/shops/{shop_id}/reject")
async def reject_shop(shop_id: uuid.UUID, body: ReasonIn, admin: Support, db: DbDep) -> dict[str, Any]:
    shop = await _shop(db, shop_id)
    if shop.status == ListingStatus.CLOSED:
        raise conflict("SHOP_NOT_REVIEWABLE")
    shop.status = ListingStatus.REJECTED
    shop.reject_reason = body.reason
    audit(db, f"admin:{admin.name}", "shop_rejected", str(shop.id), reason=body.reason)
    await db.commit()
    return shop_out(shop, private=True)


@router.post("/shops/{shop_id}/close")
async def close_shop(shop_id: uuid.UUID, admin: Support, db: DbDep) -> dict[str, Any]:
    """Closes a shop for good (the owner's request or abuse). Its products disappear from the app."""
    shop = await _shop(db, shop_id)
    if shop.status == ListingStatus.CLOSED:
        raise conflict("SHOP_ALREADY_CLOSED")
    shop.status = ListingStatus.CLOSED
    audit(db, f"admin:{admin.name}", "shop_closed", str(shop.id), requested=shop.close_requested_at is not None, reason=shop.close_reason or "")
    await db.commit()
    return shop_out(shop, private=True)


@router.post("/shops/{shop_id}/keep")
async def keep_shop(shop_id: uuid.UUID, admin: Support, db: DbDep) -> dict[str, Any]:
    """Declines the owner's close request; the shop stays as it was."""
    shop = await _shop(db, shop_id)
    if shop.close_requested_at is None:
        raise conflict("NO_CLOSE_REQUEST")
    shop.close_requested_at = None
    shop.close_reason = None
    audit(db, f"admin:{admin.name}", "shop_close_declined", str(shop.id))
    await db.commit()
    return shop_out(shop, private=True)


# ------------------------------------------------------------------ customers


@router.get("/users")
async def list_users(
    admin: Support,
    db: DbDep,
    q: Annotated[str, StringConstraints(strip_whitespace=True, max_length=60)] = "",
    offset: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
) -> dict[str, Any]:
    shops = select(Shop.owner_id, func.count().label("n")).where(Shop.status != ListingStatus.CLOSED).group_by(Shop.owner_id).subquery()
    ads = select(AdCampaign.customer_id, func.count().label("n")).group_by(AdCampaign.customer_id).subquery()
    platform = select(Device.customer_id, func.max(Device.platform).label("platform")).group_by(Device.customer_id).subquery()
    stmt = (
        select(Customer, CustomerProfile, func.coalesce(shops.c.n, 0), func.coalesce(ads.c.n, 0), platform.c.platform)
        .outerjoin(CustomerProfile, CustomerProfile.customer_id == Customer.id)
        .outerjoin(shops, shops.c.owner_id == Customer.id)
        .outerjoin(ads, ads.c.customer_id == Customer.id)
        .outerjoin(platform, platform.c.customer_id == Customer.id)
        .where(Customer.deleted_at.is_(None))
    )
    if q:
        like = f"%{q.lstrip('@').replace('%', '').replace('_', '')}%"
        stmt = stmt.where(
            or_(
                CustomerProfile.phone.ilike(like),
                CustomerProfile.username.ilike(like),
                CustomerProfile.first_name.ilike(like),
                CustomerProfile.last_name.ilike(like),
            )
        )
    total = await db.scalar(select(func.count()).select_from(stmt.subquery()))
    rows = await db.execute(stmt.order_by(Customer.created_at.desc()).offset(offset).limit(limit))
    audit(db, f"admin:{admin.name}", "users_listed", "customers", query=q, offset=offset)
    await db.commit()
    return {
        "total": total or 0,
        "users": [
            {
                "id": str(c.id),
                "created_at": c.created_at.isoformat(),
                "platform": plat,
                "profile": profile_out(p),
                "shops": n_shops,
                "ads": n_ads,
            }
            for c, p, n_shops, n_ads, plat in rows.all()
        ],
    }
