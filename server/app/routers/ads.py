"""Paid hub banners: the advertiser picks regions and days, pays by card transfer, uploads the receipt,
and the ad is shown in those regions only after an admin approves it. Active ads are ordered per viewer by
interest (app.services.interests); views and taps are counted for the advertiser."""

import uuid
from datetime import UTC, datetime
from typing import Annotated, Any, Literal

from fastapi import APIRouter, File, UploadFile, status
from pydantic import BaseModel, Field, StringConstraints
from sqlalchemy import select, update

from app.deps import CustomerDep, DbDep, get_redis, rate_limit
from app.errors import bad_request, conflict, not_found
from app.market import REGIONS, MediaUrl, OptionalHttpsUrl, Region, ad_out
from app.models import AdCampaign, AdStatus, MediaUpload
from app.services.interests import MAX_AD_TOPICS, TOPICS, clean_topics, guess_topics, load_profile, rank_ads, record_signals
from app.services.market_settings import load_market_settings
from app.uploads import save_receipt

router = APIRouter(prefix="/v1/ads", tags=["ads"])

MAX_DAYS = 30
MAX_ACTIVE_ADS_RETURNED = 10
# Candidates ranked per request; more than the returned page so interest can pull a matching ad forward.
MAX_ACTIVE_ADS_RANKED = 60
# A viewer's repeated views of one ad within this window count once.
VIEW_DEDUP_SECONDS = 6 * 3600

Topic = Literal[TOPICS]  # type: ignore[valid-type]


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
    # Empty: guessed from the title and text.
    topics: Annotated[list[Topic], Field(max_length=MAX_AD_TOPICS)] = []


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
        "topics": list(TOPICS),
        "max_topics": MAX_AD_TOPICS,
    }


@router.get("/active")
async def active_ads(current: CustomerDep, db: DbDep, region: Region) -> list[dict[str, Any]]:
    now = datetime.now(UTC)
    settings = await load_market_settings(db)
    rows = await db.scalars(
        select(AdCampaign)
        .where(
            AdCampaign.status == AdStatus.APPROVED,
            AdCampaign.starts_at <= now,
            AdCampaign.ends_at > now,
            AdCampaign.regions.contains([region]),
        )
        .order_by(AdCampaign.starts_at.desc())
        .limit(MAX_ACTIVE_ADS_RANKED)
    )
    personalized = bool(settings.ads_personalization)
    profile = await load_profile(db, current.id, settings.ads_interest_half_life_days) if personalized else {}
    ranked = rank_ads(list(rows), profile, personalized=personalized, interest_weight_percent=settings.ads_interest_weight)
    return [ad_out(ad) for ad in ranked[:MAX_ACTIVE_ADS_RETURNED]]


async def _live_ad(db: DbDep, ad_id: uuid.UUID) -> AdCampaign:
    ad = await db.get(AdCampaign, ad_id)
    if ad is None or ad.status != AdStatus.APPROVED:
        raise not_found("AD_NOT_FOUND")
    return ad


@router.post("/{ad_id}/view", status_code=status.HTTP_204_NO_CONTENT)
async def ad_viewed(ad_id: uuid.UUID, current: CustomerDep, db: DbDep) -> None:
    """The banner was on screen. Counted once per viewer and ad every VIEW_DEDUP_SECONDS."""
    await rate_limit(f"adview:{current.id}", limit=600, window_seconds=3600)
    await _live_ad(db, ad_id)
    if not await get_redis().set(f"adview:{ad_id}:{current.id}", "1", nx=True, ex=VIEW_DEDUP_SECONDS):
        return
    await db.execute(update(AdCampaign).where(AdCampaign.id == ad_id).values(views=AdCampaign.views + 1))
    await db.commit()


@router.post("/{ad_id}/click", status_code=status.HTTP_204_NO_CONTENT)
async def ad_clicked(ad_id: uuid.UUID, current: CustomerDep, db: DbDep, learn: bool = True) -> None:
    """The viewer tapped the banner: counted for the advertiser and, unless the viewer turned personalised ads
    off (learn=false), a strong interest signal for its topics."""
    await rate_limit(f"adclick:{current.id}", limit=120, window_seconds=3600)
    ad = await _live_ad(db, ad_id)
    if await get_redis().set(f"adclick:{ad_id}:{current.id}", "1", nx=True, ex=VIEW_DEDUP_SECONDS):
        await db.execute(update(AdCampaign).where(AdCampaign.id == ad_id).values(clicks=AdCampaign.clicks + 1))
    settings = await load_market_settings(db)
    if learn and settings.ads_personalization:
        await record_signals(db, current.id, [(t, "ad_click") for t in ad.topics or []], settings.ads_interest_half_life_days)
    await db.commit()


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
        topics=clean_topics(body.topics) or guess_topics(body.title, body.text),
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
