from functools import lru_cache
from typing import Literal

from pydantic import AliasChoices, Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

DEFAULT_DATABASE_URL = "postgresql+asyncpg://sado:sado@localhost:5432/sado_billing"
DEFAULT_REDIS_URL = "redis://localhost:6379/2"


class Settings(BaseSettings):
    """Billing service configuration. Every secret comes from the environment; nothing is hardcoded."""

    model_config = SettingsConfigDict(env_prefix="SADO_BILLING_", env_file=".env", extra="ignore")

    environment: Literal["development", "test", "staging", "production"] = "development"
    database_url: str = DEFAULT_DATABASE_URL
    redis_url: str = DEFAULT_REDIS_URL

    # Reverse proxies whose X-Forwarded-For uvicorn trusts (--proxy-headers). Read from uvicorn's own
    # FORWARDED_ALLOW_IPS so the app can refuse to start when it is missing in staging/production.
    forwarded_allow_ips: str = Field(default="", validation_alias=AliasChoices("FORWARDED_ALLOW_IPS", "forwarded_allow_ips"))

    # Permanent X-Admin-Key keys (CLI-created) alongside login sessions. Set false once every admin
    # signs in with login/password: then logout and session expiry end all panel access.
    admin_permanent_keys: bool = True

    # Whole request body cap, checked before multipart parsing; above the biggest upload plus form overhead.
    max_request_bytes: int = 32 * 1024 * 1024

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

    # Hub movies: an admin uploads a film in chunks, the worker compresses it with ffmpeg and a bot posts it to a
    # public Telegram channel; the app streams it from there, so the server keeps no video once it is published.
    tg_api_id: int = 0
    tg_api_hash: str = ""
    movies_bot_token: str = ""  # the bot must be an admin of the channel with "post messages"
    movies_channel: str = ""  # public channel username without @
    movie_max_upload_bytes: int = 8 * 1024 * 1024 * 1024
    movie_chunk_bytes: int = 16 * 1024 * 1024
    # Uploads are refused when they would leave less free disk than this (the compressed copy needs room too).
    movie_disk_reserve_bytes: int = 10 * 1024 * 1024 * 1024
    movie_max_height: int = 720
    movie_crf: int = 26  # x264 quality: higher = smaller file; 23 near-transparent, 28 visibly soft
    movie_ffmpeg_threads: int = 3  # the VPS is shared with other services

    # Online shops: the first ones are free, every further shop costs a one-time fee (manual transfer + admin check).
    shop_free_limit: int = 2
    extra_shop_price_uzs: int = 150_000

    @model_validator(mode="after")
    def _mock_only_outside_production(self) -> "Settings":
        if self.environment in ("staging", "production") and "mock" in self.enabled_providers:
            raise ValueError("the mock billing provider must never be enabled in staging or production")
        return self

    @model_validator(mode="after")
    def _safe_outside_development(self) -> "Settings":
        """Fail fast on a staging/production deploy that still runs with development defaults."""
        if self.environment not in ("staging", "production"):
            return self
        problems = []
        if self.database_url == DEFAULT_DATABASE_URL or "://sado:sado@" in self.database_url:
            problems.append("SADO_BILLING_DATABASE_URL still uses the development default credentials")
        if self.redis_url == DEFAULT_REDIS_URL:
            problems.append("SADO_BILLING_REDIS_URL is the development default")
        proxies = self.forwarded_allow_ips.strip()
        if not proxies:
            problems.append("FORWARDED_ALLOW_IPS must list the reverse proxy addresses, or per-IP rate limits see only the proxy")
        elif "*" in proxies:
            problems.append("FORWARDED_ALLOW_IPS='*' lets any client forge X-Forwarded-For")
        if self.max_request_bytes < max(self.max_image_bytes, self.max_video_bytes, self.movie_chunk_bytes):
            problems.append("SADO_BILLING_MAX_REQUEST_BYTES is smaller than the biggest allowed upload")
        if problems:
            raise ValueError("unsafe staging/production configuration: " + "; ".join(problems))
        return self

    @property
    def docs_enabled(self) -> bool:
        return self.environment in ("development", "test")

    @property
    def movies_configured(self) -> bool:
        return bool(self.tg_api_id and self.tg_api_hash and self.movies_bot_token and self.movies_channel)

    @property
    def mock_allowed(self) -> bool:
        return self.environment in ("development", "test") and "mock" in self.enabled_providers


@lru_cache
def get_settings() -> Settings:
    return Settings()
