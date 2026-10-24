"""Prices, payment card and app release info: environment defaults, overridden by what the owner saves in the admin panel."""

from dataclasses import dataclass, fields, replace

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.models import AppSetting


@dataclass(frozen=True)
class MarketSettings:
    ad_price_per_region_day_uzs: int
    ad_payment_card: str
    ad_payment_card_holder: str
    extra_shop_price_uzs: int
    shop_free_limit: int
    app_version: str = ""
    app_build: int = 0
    app_release_notes: str = ""


EDITABLE = tuple(f.name for f in fields(MarketSettings))


def defaults() -> MarketSettings:
    env = get_settings()
    return MarketSettings(
        ad_price_per_region_day_uzs=env.ad_price_per_region_day_uzs,
        ad_payment_card=env.ad_payment_card,
        ad_payment_card_holder=env.ad_payment_card_holder,
        extra_shop_price_uzs=env.extra_shop_price_uzs,
        shop_free_limit=env.shop_free_limit,
    )


def _parse(name: str, raw: str) -> int | str:
    kind = next(f.type for f in fields(MarketSettings) if f.name == name)
    return int(raw) if kind in (int, "int") else raw


async def load_market_settings(db: AsyncSession) -> MarketSettings:
    rows = await db.scalars(select(AppSetting).where(AppSetting.key.in_(EDITABLE)))
    overrides = {row.key: _parse(row.key, row.value) for row in rows}
    return replace(defaults(), **overrides)
