import uuid
from datetime import datetime
from enum import StrEnum

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    DateTime,
    Enum,
    ForeignKey,
    Index,
    Integer,
    String,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


def _enum(enum_cls: type[StrEnum], name: str) -> Enum:
    return Enum(enum_cls, name=name, values_callable=lambda cls: [m.value for m in cls])


class SubscriptionStatus(StrEnum):
    ACTIVE = "active"  # paid (or trial) and auto-renewing
    CANCELLED = "cancelled"  # auto-renew off, access until expires_at
    IN_GRACE = "in_grace"  # renewal payment failing, store grace period: access kept
    BILLING_RETRY = "billing_retry"  # grace over, store still retrying: no access
    PAUSED = "paused"  # Google Play pause: no access
    EXPIRED = "expired"
    REFUNDED = "refunded"
    REVOKED = "revoked"  # e.g. family sharing removed, chargeback


class PurchaseStatus(StrEnum):
    COMPLETED = "completed"
    REFUNDED = "refunded"
    REVOKED = "revoked"


class EventStatus(StrEnum):
    PROCESSED = "processed"
    IGNORED = "ignored"  # stale (out of order) or irrelevant
    FAILED = "failed"


class AdminRole(StrEnum):
    VIEWER = "viewer"  # metrics only
    SUPPORT = "support"  # + customer lookup, entitlement overrides
    FINANCE = "finance"  # + credit adjustments
    OWNER = "owner"  # everything incl. admin management


class Customer(Base):
    """A Sado customer. Independent of Telegram: a Telegram user id is never used as identity."""

    __tablename__ = "customers"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    # Opaque token handed to the stores (Play obfuscatedAccountId / App Store appAccountToken)
    # so store transactions can be tied back to this customer.
    store_account_token: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), unique=True, default=uuid.uuid4)
    region: Mapped[str] = mapped_column(String(2), default="UZ")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Device(Base):
    __tablename__ = "devices"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"), index=True)
    refresh_hash: Mapped[str] = mapped_column(String(64), unique=True)
    platform: Mapped[str] = mapped_column(String(16))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Subscription(Base):
    __tablename__ = "subscriptions"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="RESTRICT"), index=True)
    provider: Mapped[str] = mapped_column(String(32))
    # Stable store identifier: Play purchase token (first in the linked chain) / App Store original_transaction_id.
    external_id: Mapped[str] = mapped_column(String(512))
    product_id: Mapped[str] = mapped_column(String(64))
    status: Mapped[SubscriptionStatus] = mapped_column(_enum(SubscriptionStatus, "subscription_status"))
    is_trial: Mapped[bool] = mapped_column(Boolean, default=False)
    auto_renew: Mapped[bool] = mapped_column(Boolean, default=True)
    period_start: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    grace_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    price_minor: Mapped[int] = mapped_column(BigInteger, default=0)
    currency: Mapped[str] = mapped_column(String(3), default="")
    country: Mapped[str] = mapped_column(String(2), default="")
    # Time of the newest store event applied; older events are ignored (out-of-order protection).
    last_event_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    __table_args__ = (UniqueConstraint("provider", "external_id", name="uq_subscriptions_provider_external"),)


class Purchase(Base):
    """One-time purchase (theme packs, icon packs)."""

    __tablename__ = "purchases"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="RESTRICT"), index=True)
    provider: Mapped[str] = mapped_column(String(32))
    external_id: Mapped[str] = mapped_column(String(512))
    product_id: Mapped[str] = mapped_column(String(64))
    status: Mapped[PurchaseStatus] = mapped_column(_enum(PurchaseStatus, "purchase_status"))
    purchased_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    price_minor: Mapped[int] = mapped_column(BigInteger, default=0)
    currency: Mapped[str] = mapped_column(String(3), default="")
    country: Mapped[str] = mapped_column(String(2), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (UniqueConstraint("provider", "external_id", name="uq_purchases_provider_external"),)


class ProviderEvent(Base):
    """Every webhook/notification received, for idempotency, replay protection and audit."""

    __tablename__ = "provider_events"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    provider: Mapped[str] = mapped_column(String(32))
    event_id: Mapped[str] = mapped_column(String(256))
    event_type: Mapped[str] = mapped_column(String(64))
    external_id: Mapped[str] = mapped_column(String(512))
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    status: Mapped[EventStatus] = mapped_column(_enum(EventStatus, "event_status"))
    detail: Mapped[str] = mapped_column(String(512), default="")

    __table_args__ = (UniqueConstraint("provider", "event_id", name="uq_provider_events_provider_event"),)


class Transaction(Base):
    """Verified money movement reported by a store. Revenue analytics are computed only from this table."""

    __tablename__ = "transactions"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="RESTRICT"), index=True)
    provider: Mapped[str] = mapped_column(String(32))
    external_txn_id: Mapped[str] = mapped_column(String(512))
    kind: Mapped[str] = mapped_column(String(16))  # purchase | renewal | refund
    product_id: Mapped[str] = mapped_column(String(64))
    amount_minor: Mapped[int] = mapped_column(BigInteger)  # negative for refunds
    currency: Mapped[str] = mapped_column(String(3))
    country: Mapped[str] = mapped_column(String(2), default="")
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))

    __table_args__ = (
        UniqueConstraint("provider", "external_txn_id", "kind", name="uq_transactions_provider_txn_kind"),
        Index("ix_transactions_occurred_at", "occurred_at"),
    )


class CreditAccount(Base):
    """Current AI credit balance. Changed only together with a CreditLedger row, in one transaction.

    `allowance` comes with the AI Writer subscription and is reset every billing period.
    `available` holds purchased credits, which never expire (App Store Review Guideline 3.1.1).
    Spending uses the allowance first.
    """

    __tablename__ = "credit_accounts"

    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"), primary_key=True)
    allowance: Mapped[int] = mapped_column(BigInteger, default=0)
    available: Mapped[int] = mapped_column(BigInteger, default=0)
    reserved: Mapped[int] = mapped_column(BigInteger, default=0)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    __table_args__ = (
        CheckConstraint("allowance >= 0", name="ck_credit_allowance_non_negative"),
        CheckConstraint("available >= 0", name="ck_credit_available_non_negative"),
        CheckConstraint("reserved >= 0", name="ck_credit_reserved_non_negative"),
    )


class CreditLedger(Base):
    """Append-only credit journal. (customer, kind, reference) is unique, making every operation idempotent."""

    __tablename__ = "credit_ledger"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"), index=True)
    kind: Mapped[str] = mapped_column(String(16))  # grant | purchase | reserve | settle | release | expire | adjust
    reference: Mapped[str] = mapped_column(String(128))
    delta_allowance: Mapped[int] = mapped_column(BigInteger, default=0)
    delta_available: Mapped[int] = mapped_column(BigInteger, default=0)
    delta_reserved: Mapped[int] = mapped_column(BigInteger, default=0)
    meta: Mapped[dict] = mapped_column(JSONB, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (UniqueConstraint("customer_id", "kind", "reference", name="uq_credit_ledger_idempotency"),)


class CreditReservation(Base):
    __tablename__ = "credit_reservations"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"), index=True)
    idempotency_key: Mapped[str] = mapped_column(String(128))
    amount: Mapped[int] = mapped_column(BigInteger)
    from_allowance: Mapped[int] = mapped_column(BigInteger)
    from_available: Mapped[int] = mapped_column(BigInteger)
    status: Mapped[str] = mapped_column(String(16))  # held | settled | released
    settled_amount: Mapped[int] = mapped_column(BigInteger, default=0)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (
        UniqueConstraint("customer_id", "idempotency_key", name="uq_credit_reservations_idempotency"),
        CheckConstraint("amount > 0", name="ck_reservation_amount_positive"),
    )


class AiUsage(Base):
    """Provider cost per AI request (no prompt or output text is stored)."""

    __tablename__ = "ai_usage"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"), index=True)
    reservation_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True))
    feature: Mapped[str] = mapped_column(String(32))
    model: Mapped[str] = mapped_column(String(64))
    input_tokens: Mapped[int] = mapped_column(Integer, default=0)
    output_tokens: Mapped[int] = mapped_column(Integer, default=0)
    cost_micros: Mapped[int] = mapped_column(BigInteger, default=0)  # USD micro-dollars
    credits: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)


class EntitlementOverride(Base):
    """Admin-granted access (support compensation, testers). Always audited."""

    __tablename__ = "entitlement_overrides"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"), index=True)
    entitlement: Mapped[str] = mapped_column(String(32))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    reason: Mapped[str] = mapped_column(String(256))
    granted_by: Mapped[str] = mapped_column(String(64))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class AdminUser(Base):
    __tablename__ = "admin_users"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String(64), unique=True)
    key_hash: Mapped[str] = mapped_column(String(64), unique=True)
    role: Mapped[AdminRole] = mapped_column(_enum(AdminRole, "admin_role"))
    # Optional login/password for the web panel (scrypt hash); the key keeps working alongside.
    login: Mapped[str | None] = mapped_column(String(64), unique=True)
    password_hash: Mapped[str | None] = mapped_column(String(255))
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class AppSetting(Base):
    """Owner-editable settings (prices, payment card, app release) overriding the environment defaults."""

    __tablename__ = "app_settings"

    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    value: Mapped[str] = mapped_column(String(2000))
    updated_by: Mapped[str] = mapped_column(String(64))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())


class AuditLog(Base):
    """Append-only record of privileged and financial actions (revoked UPDATE/DELETE in migration)."""

    __tablename__ = "audit_log"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    actor: Mapped[str] = mapped_column(String(128))
    action: Mapped[str] = mapped_column(String(64))
    target: Mapped[str] = mapped_column(String(128))
    details: Mapped[dict] = mapped_column(JSONB, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)


# ---------------------------------------------------------------- marketplace and ads


class ListingStatus(StrEnum):
    AWAITING_PAYMENT = "awaiting_payment"  # a paid shop slot (beyond the free ones) without a receipt yet
    PENDING = "pending"  # waiting for an admin
    APPROVED = "approved"  # visible to everyone in its region
    REJECTED = "rejected"  # hidden; reject_reason tells the owner why
    CLOSED = "closed"  # closed by an admin (on the owner's request or for abuse); kept for records


class AdStatus(StrEnum):
    AWAITING_PAYMENT = "awaiting_payment"  # created, no receipt yet
    PENDING_REVIEW = "pending_review"  # receipt uploaded, an admin checks payment and content
    APPROVED = "approved"  # shown from starts_at until ends_at
    REJECTED = "rejected"


class StockKind(StrEnum):
    IN = "in"  # goods received into the warehouse
    SALE = "sale"  # sold; unit_price is the selling price, counted as revenue
    RETURN = "return"  # returned by a buyer
    ADJUST = "adjust"  # stocktaking correction (loss, damage, recount)


class CustomerProfile(Base):
    """Telegram name, username and phone a customer chose to share (consent asked in the app)."""

    __tablename__ = "customer_profiles"

    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"), primary_key=True)
    first_name: Mapped[str] = mapped_column(String(64), default="")
    last_name: Mapped[str] = mapped_column(String(64), default="")
    username: Mapped[str] = mapped_column(String(40), default="", index=True)
    phone: Mapped[str] = mapped_column(String(20), default="", index=True)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())


class MediaUpload(Base):
    """A public product photo or short video uploaded by a customer, served at /media/<name>."""

    __tablename__ = "media_uploads"

    name: Mapped[str] = mapped_column(String(64), primary_key=True)  # "<uuid>.<ext>"
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"), index=True)
    kind: Mapped[str] = mapped_column(String(8))  # image | video
    size_bytes: Mapped[int] = mapped_column(Integer)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class Shop(Base):
    """A customer's online shop. The first ones are free, further ones are paid; every edit is reviewed again."""

    __tablename__ = "shops"
    __table_args__ = (Index("ix_shops_status_region", "status", "region"),)

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    owner_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(80))
    description: Mapped[str] = mapped_column(String(1000), default="")
    region: Mapped[str] = mapped_column(String(40))
    phone: Mapped[str] = mapped_column(String(20), default="")
    telegram: Mapped[str] = mapped_column(String(40), default="")  # username without "@"
    logo_url: Mapped[str] = mapped_column(String(500), default="")
    status: Mapped[ListingStatus] = mapped_column(_enum(ListingStatus, "listing_status"), default=ListingStatus.PENDING)
    reject_reason: Mapped[str | None] = mapped_column(String(256))
    price_uzs: Mapped[int] = mapped_column(BigInteger, default=0)  # fee for this shop slot, 0 when free
    receipt_path: Mapped[str | None] = mapped_column(String(200))
    close_requested_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    close_reason: Mapped[str | None] = mapped_column(String(256))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())


class Product(Base):
    __tablename__ = "products"
    __table_args__ = (
        CheckConstraint("price_uzs >= 0", name="ck_products_price_non_negative"),
        CheckConstraint("stock >= 0", name="ck_products_stock_non_negative"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    shop_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("shops.id", ondelete="CASCADE"), index=True)
    title: Mapped[str] = mapped_column(String(120))
    description: Mapped[str] = mapped_column(String(2000), default="")
    category: Mapped[str] = mapped_column(String(40), default="")
    sku: Mapped[str] = mapped_column(String(40), default="")
    price_uzs: Mapped[int] = mapped_column(BigInteger)
    old_price_uzs: Mapped[int | None] = mapped_column(BigInteger)  # crossed-out price for discounts
    # [{"type": "image" | "video", "url": "/media/<name>" or "https://..."}], first image is the cover
    media: Mapped[list] = mapped_column(JSONB, default=list)
    stock: Mapped[int] = mapped_column(Integer, default=0)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class StockMovement(Base):
    """Warehouse ledger: every change of a product's stock, the source of the shop's accounting."""

    __tablename__ = "stock_movements"
    __table_args__ = (Index("ix_stock_movements_shop_created", "shop_id", "created_at"),)

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    shop_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("shops.id", ondelete="CASCADE"))
    product_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("products.id", ondelete="CASCADE"), index=True)
    kind: Mapped[StockKind] = mapped_column(_enum(StockKind, "stock_kind"))
    quantity: Mapped[int] = mapped_column(Integer)  # signed change of stock
    unit_price_uzs: Mapped[int] = mapped_column(BigInteger, default=0)
    note: Mapped[str] = mapped_column(String(200), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class AdCampaign(Base):
    """A paid banner in the app's hub, shown only in the regions the advertiser picked."""

    __tablename__ = "ad_campaigns"
    __table_args__ = (
        Index("ix_ad_campaigns_status_ends", "status", "ends_at"),
        CheckConstraint("days BETWEEN 1 AND 30", name="ck_ad_campaigns_days"),
        CheckConstraint("media_type IN ('image', 'video')", name="ck_ad_campaigns_media_type"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"), index=True)
    title: Mapped[str] = mapped_column(String(60))
    text: Mapped[str] = mapped_column(String(160), default="")
    media_type: Mapped[str] = mapped_column(String(8))
    media_url: Mapped[str] = mapped_column(String(500))
    link_url: Mapped[str] = mapped_column(String(500), default="")
    regions: Mapped[list] = mapped_column(JSONB)
    days: Mapped[int] = mapped_column(Integer)
    price_uzs: Mapped[int] = mapped_column(BigInteger)
    status: Mapped[AdStatus] = mapped_column(_enum(AdStatus, "ad_status"), default=AdStatus.AWAITING_PAYMENT)
    receipt_path: Mapped[str | None] = mapped_column(String(200))  # relative to the private media dir
    reject_reason: Mapped[str | None] = mapped_column(String(256))
    reviewed_by: Mapped[str | None] = mapped_column(String(64))
    starts_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    ends_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
