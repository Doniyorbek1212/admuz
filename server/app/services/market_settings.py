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
    # Interest-based ads ("AI reklama"): 1 on, 0 plain rotation; how much the match counts vs. random rotation (%);
    # after how many days an interest counts half as much.
    ads_personalization: int = 1
    ads_interest_weight: int = 70
    ads_interest_half_life_days: int = 14
    # "Kimlarga ko'rsatilsin" in the app's new-ad form: 1 the advertiser picks topics, 0 hidden (guessed from the text).
    ads_topic_picker: int = 1
    # Short UZARO usernames by length, in so'm; 0 = that length is not on sale (5+ characters are always free).
    username_price_2_uzs: int = 0
    username_price_3_uzs: int = 0
    username_price_4_uzs: int = 0
    # UZARO badge next to the name (checkmark or custom emoji), per 30 days, in so'm; 0 = not on sale.
    badge_price_uzs: int = 15_000
    # Pay bot rates: so'm one Telegram Star buys, so'm one TON buys, and the TON wallet receiving payments;
    # 0 or empty switches that method off.
    stars_uzs_per_star: int = 0
    ton_uzs_per_ton: int = 0
    ton_wallet: str = ""
    # So'm put on the balance once per Telegram account when it is first linked; 0 stops new grants.
    welcome_bonus_uzs: int = 100_000


EDITABLE = tuple(f.name for f in fields(MarketSettings))


def defaults() -> MarketSettings:
    env = get_settings()
    return MarketSettings(
        ad_price_per_region_day_uzs=env.ad_price_per_region_day_uzs,
        ad_payment_card=env.ad_payment_card,
        ad_payment_card_holder=env.ad_payment_card_holder,
        extra_shop_price_uzs=env.extra_shop_price_uzs,
        shop_free_limit=env.shop_free_limit,
        welcome_bonus_uzs=env.welcome_bonus_uzs,
    )


def _parse(name: str, raw: str) -> int | str:
    kind = next(f.type for f in fields(MarketSettings) if f.name == name)
    return int(raw) if kind in (int, "int") else raw


async def load_market_settings(db: AsyncSession) -> MarketSettings:
    rows = await db.scalars(select(AppSetting).where(AppSetting.key.in_(EDITABLE)))
    overrides = {row.key: _parse(row.key, row.value) for row in rows}
    return replace(defaults(), **overrides)
