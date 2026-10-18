from functools import lru_cache
from typing import Literal

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Billing service configuration. Every secret comes from the environment; nothing is hardcoded."""

    model_config = SettingsConfigDict(env_prefix="SADO_BILLING_", env_file=".env", extra="ignore")

    environment: Literal["development", "test", "staging", "production"] = "development"
    database_url: str = "postgresql+asyncpg://sado:sado@localhost:5432/sado_billing"
    redis_url: str = "redis://localhost:6379/2"

    jwt_secret: str = Field(min_length=32)
    access_token_ttl_seconds: int = 60 * 30
    link_code_ttl_seconds: int = 300

    # Master switch: no purchase is verified and no entitlement is granted from a store while false.
    payments_enabled: bool = False
    # Providers allowed to verify purchases and receive webhooks, e.g. ["google_play", "app_store"].
    enabled_providers: list[str] = Field(default_factory=list)

    # Mock provider (development and tests only; refused in staging/production).
    mock_webhook_secret: str = ""
    webhook_max_age_seconds: int = 300

    # Google Play (phase B): service account JSON path and package name.
    google_package_name: str = ""
    google_service_account_file: str = ""
    # App Store (phase B): App Store Server API credentials.
    apple_bundle_id: str = ""
    apple_issuer_id: str = ""
    apple_key_id: str = ""
    apple_private_key_file: str = ""

    # AI credits
    ai_reservation_ttl_seconds: int = 120
    ai_monthly_budget_micros: int = 0  # 0 = AI calls disabled; server-wide spend cap per month

    rate_limit_per_minute: int = 30

    # Hub ads, paid by manual card transfer and approved by an admin.
    ad_price_per_region_day_uzs: int = 20_000
    ad_payment_card: str = ""  # card number shown to advertisers, e.g. "8600 1234 5678 9012"
    ad_payment_card_holder: str = ""
    # Uploads: receipts under <media_dir>/receipts are private; product photos/videos under
    # <media_dir>/public are served at /media/<name>.
    media_dir: str = "media"
    max_image_bytes: int = 5 * 1024 * 1024
    max_video_bytes: int = 30 * 1024 * 1024

    # Online shops: the first ones are free, every further shop costs a one-time fee (manual transfer + admin check).
    shop_free_limit: int = 2
    extra_shop_price_uzs: int = 150_000

    @model_validator(mode="after")
    def _mock_only_outside_production(self) -> "Settings":
        if self.environment in ("staging", "production") and "mock" in self.enabled_providers:
            raise ValueError("the mock billing provider must never be enabled in staging or production")
        return self

    @property
    def mock_allowed(self) -> bool:
        return self.environment in ("development", "test") and "mock" in self.enabled_providers


@lru_cache
def get_settings() -> Settings:
    return Settings()
