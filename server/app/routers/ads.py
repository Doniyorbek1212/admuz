"""Paid hub banners: the advertiser picks regions and days, pays by card transfer, uploads the receipt,
and the ad is shown in those regions only after an admin approves it."""

import uuid
from datetime import UTC, datetime
from typing import Annotated, Any, Literal

from fastapi import APIRouter, File, UploadFile, status
from pydantic import BaseModel, Field, StringConstraints
from sqlalchemy import select

from app.deps import CustomerDep, DbDep, rate_limit
from app.errors import bad_request, conflict, not_found
from app.market import REGIONS, MediaUrl, OptionalHttpsUrl, Region, ad_out
from app.models import AdCampaign, AdStatus, MediaUpload
from app.services.market_settings import load_market_settings
from app.uploads import save_receipt

router = APIRouter(prefix="/v1/ads", tags=["ads"])

MAX_DAYS = 30
MAX_ACTIVE_ADS_RETURNED = 10


def ad_price(regions: int, days: int, price_per_region_day: int) -> int:
    return regions * days * price_per_region_day


class AdIn(BaseModel):
    title: Annotated[str, StringConstraints(strip_whitespace=True, min_length=2, max_length=60)]
    text: Annotated[str, StringConstraints(strip_whitespace=True, max_length=160)] = ""
    media_type: Literal["image", "video"]
    media_url: MediaUrl
    link_url: OptionalHttpsUrl = ""
    regions: Annotated[list[Region], Field(min_length=1, max_length=len(REGIONS))]
    days: Annotated[int, Field(ge=1, le=MAX_DAYS)]


@router.get("/config")
async def ads_config(current: CustomerDep, db: DbDep) -> dict[str, Any]:
    settings = await load_market_settings(db)
    return {
        "regions": list(REGIONS),
        "price_per_region_day_uzs": settings.ad_price_per_region_day_uzs,
        "max_days": MAX_DAYS,
        "card_number": settings.ad_payment_card,
        "card_holder": settings.ad_payment_card_holder,
        "extra_shop_price_uzs": settings.extra_shop_price_uzs,
        "shop_free_limit": settings.shop_free_limit,
    }


@router.get("/active")
async def active_ads(current: CustomerDep, db: DbDep, region: Region) -> list[dict[str, Any]]:
    now = datetime.now(UTC)
    rows = await db.scalars(
        select(AdCampaign)
        .where(
            AdCampaign.status == AdStatus.APPROVED,
            AdCampaign.starts_at <= now,
            AdCampaign.ends_at > now,
            AdCampaign.regions.contains([region]),
        )
        .order_by(AdCampaign.starts_at.desc())
        .limit(MAX_ACTIVE_ADS_RETURNED)
    )
    return [ad_out(ad) for ad in rows]


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_ad(body: AdIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    await rate_limit(f"adcreate:{current.id}", limit=10, window_seconds=3600)
    if body.media_url.startswith("/media/"):
        name = body.media_url.removeprefix("/media/")
        owned = await db.scalar(select(MediaUpload.name).where(MediaUpload.name == name, MediaUpload.customer_id == current.id))
        if owned is None:
            raise bad_request("MEDIA_NOT_FOUND")
    regions = sorted(set(body.regions), key=REGIONS.index)
    ad = AdCampaign(
        customer_id=current.id,
        title=body.title,
        text=body.text,
        media_type=body.media_type,
        media_url=body.media_url,
        link_url=body.link_url,
        regions=regions,
        days=body.days,
        price_uzs=ad_price(len(regions), body.days, (await load_market_settings(db)).ad_price_per_region_day_uzs),
        status=AdStatus.AWAITING_PAYMENT,
    )
    db.add(ad)
    await db.commit()
    await db.refresh(ad)
    return ad_out(ad, private=True)


@router.get("/mine")
async def my_ads(current: CustomerDep, db: DbDep) -> list[dict[str, Any]]:
    rows = await db.scalars(select(AdCampaign).where(AdCampaign.customer_id == current.id).order_by(AdCampaign.created_at.desc()).limit(100))
    return [ad_out(ad, private=True) for ad in rows]


async def _own_ad(db: DbDep, customer_id: uuid.UUID, ad_id: uuid.UUID) -> AdCampaign:
    ad = await db.get(AdCampaign, ad_id)
    if ad is None or ad.customer_id != customer_id:
        raise not_found("AD_NOT_FOUND")
    return ad


@router.post("/{ad_id}/receipt")
async def upload_receipt(ad_id: uuid.UUID, current: CustomerDep, db: DbDep, file: Annotated[UploadFile, File()]) -> dict[str, Any]:
    await rate_limit(f"receipt:{current.id}", limit=20, window_seconds=3600)
    ad = await _own_ad(db, current.id, ad_id)
    if ad.status not in (AdStatus.AWAITING_PAYMENT, AdStatus.PENDING_REVIEW, AdStatus.REJECTED):
        raise conflict("AD_ALREADY_REVIEWED")
    ad.receipt_path = await save_receipt(file)
    ad.status = AdStatus.PENDING_REVIEW
    ad.reject_reason = None
    await db.commit()
    return ad_out(ad, private=True)


@router.delete("/{ad_id}", status_code=status.HTTP_204_NO_CONTENT)
async def cancel_ad(ad_id: uuid.UUID, current: CustomerDep, db: DbDep) -> None:
    ad = await _own_ad(db, current.id, ad_id)
    if ad.status == AdStatus.APPROVED:
        raise conflict("AD_ALREADY_APPROVED")
    await db.delete(ad)
    await db.commit()
