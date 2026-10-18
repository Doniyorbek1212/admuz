"""marketplace: shops, products with media and stock ledger, customer profiles, hub ads

Revision ID: 0002
Revises: 0001
Create Date: 2026-10-18 09:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = '0002'
down_revision: str | Sequence[str] | None = '0001'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

listing_status = postgresql.ENUM('awaiting_payment', 'pending', 'approved', 'rejected', 'closed', name='listing_status', create_type=False)
ad_status = postgresql.ENUM('awaiting_payment', 'pending_review', 'approved', 'rejected', name='ad_status', create_type=False)
stock_kind = postgresql.ENUM('in', 'sale', 'return', 'adjust', name='stock_kind', create_type=False)

_created = sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False)


def upgrade() -> None:
    bind = op.get_bind()
    for enum in (listing_status, ad_status, stock_kind):
        enum.create(bind, checkfirst=True)

    op.create_table(
        'customer_profiles',
        sa.Column('customer_id', sa.UUID(), nullable=False),
        sa.Column('first_name', sa.String(length=64), nullable=False),
        sa.Column('last_name', sa.String(length=64), nullable=False),
        sa.Column('username', sa.String(length=40), nullable=False),
        sa.Column('phone', sa.String(length=20), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.ForeignKeyConstraint(['customer_id'], ['customers.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('customer_id'),
    )
    op.create_index(op.f('ix_customer_profiles_username'), 'customer_profiles', ['username'])
    op.create_index(op.f('ix_customer_profiles_phone'), 'customer_profiles', ['phone'])

    op.create_table(
        'media_uploads',
        sa.Column('name', sa.String(length=64), nullable=False),
        sa.Column('customer_id', sa.UUID(), nullable=False),
        sa.Column('kind', sa.String(length=8), nullable=False),
        sa.Column('size_bytes', sa.Integer(), nullable=False),
        _created.copy(),
        sa.ForeignKeyConstraint(['customer_id'], ['customers.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('name'),
    )
    op.create_index(op.f('ix_media_uploads_customer_id'), 'media_uploads', ['customer_id'])

    op.create_table(
        'shops',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('owner_id', sa.UUID(), nullable=False),
        sa.Column('name', sa.String(length=80), nullable=False),
        sa.Column('description', sa.String(length=1000), nullable=False),
        sa.Column('region', sa.String(length=40), nullable=False),
        sa.Column('phone', sa.String(length=20), nullable=False),
        sa.Column('telegram', sa.String(length=40), nullable=False),
        sa.Column('logo_url', sa.String(length=500), nullable=False),
        sa.Column('status', listing_status, nullable=False),
        sa.Column('reject_reason', sa.String(length=256), nullable=True),
        sa.Column('price_uzs', sa.BigInteger(), nullable=False),
        sa.Column('receipt_path', sa.String(length=200), nullable=True),
        sa.Column('close_requested_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('close_reason', sa.String(length=256), nullable=True),
        _created.copy(),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.ForeignKeyConstraint(['owner_id'], ['customers.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(op.f('ix_shops_owner_id'), 'shops', ['owner_id'])
    op.create_index('ix_shops_status_region', 'shops', ['status', 'region'])

    op.create_table(
        'products',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('shop_id', sa.UUID(), nullable=False),
        sa.Column('title', sa.String(length=120), nullable=False),
        sa.Column('description', sa.String(length=2000), nullable=False),
        sa.Column('category', sa.String(length=40), nullable=False),
        sa.Column('sku', sa.String(length=40), nullable=False),
        sa.Column('price_uzs', sa.BigInteger(), nullable=False),
        sa.Column('old_price_uzs', sa.BigInteger(), nullable=True),
        sa.Column('media', postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column('stock', sa.Integer(), nullable=False),
        sa.Column('active', sa.Boolean(), nullable=False),
        _created.copy(),
        sa.CheckConstraint('price_uzs >= 0', name='ck_products_price_non_negative'),
        sa.CheckConstraint('stock >= 0', name='ck_products_stock_non_negative'),
        sa.ForeignKeyConstraint(['shop_id'], ['shops.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(op.f('ix_products_shop_id'), 'products', ['shop_id'])

    op.create_table(
        'stock_movements',
        sa.Column('id', sa.BigInteger(), nullable=False),
        sa.Column('shop_id', sa.UUID(), nullable=False),
        sa.Column('product_id', sa.UUID(), nullable=False),
        sa.Column('kind', stock_kind, nullable=False),
        sa.Column('quantity', sa.Integer(), nullable=False),
        sa.Column('unit_price_uzs', sa.BigInteger(), nullable=False),
        sa.Column('note', sa.String(length=200), nullable=False),
        _created.copy(),
        sa.ForeignKeyConstraint(['product_id'], ['products.id'], ondelete='CASCADE'),
        sa.ForeignKeyConstraint(['shop_id'], ['shops.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(op.f('ix_stock_movements_product_id'), 'stock_movements', ['product_id'])
    op.create_index('ix_stock_movements_shop_created', 'stock_movements', ['shop_id', 'created_at'])

    op.create_table(
        'ad_campaigns',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('customer_id', sa.UUID(), nullable=False),
        sa.Column('title', sa.String(length=60), nullable=False),
        sa.Column('text', sa.String(length=160), nullable=False),
        sa.Column('media_type', sa.String(length=8), nullable=False),
        sa.Column('media_url', sa.String(length=500), nullable=False),
        sa.Column('link_url', sa.String(length=500), nullable=False),
        sa.Column('regions', postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column('days', sa.Integer(), nullable=False),
        sa.Column('price_uzs', sa.BigInteger(), nullable=False),
        sa.Column('status', ad_status, nullable=False),
        sa.Column('receipt_path', sa.String(length=200), nullable=True),
        sa.Column('reject_reason', sa.String(length=256), nullable=True),
        sa.Column('reviewed_by', sa.String(length=64), nullable=True),
        sa.Column('starts_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('ends_at', sa.DateTime(timezone=True), nullable=True),
        _created.copy(),
        sa.CheckConstraint('days BETWEEN 1 AND 30', name='ck_ad_campaigns_days'),
        sa.CheckConstraint("media_type IN ('image', 'video')", name='ck_ad_campaigns_media_type'),
        sa.ForeignKeyConstraint(['customer_id'], ['customers.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(op.f('ix_ad_campaigns_customer_id'), 'ad_campaigns', ['customer_id'])
    op.create_index('ix_ad_campaigns_status_ends', 'ad_campaigns', ['status', 'ends_at'])


def downgrade() -> None:
    for table in ('ad_campaigns', 'stock_movements', 'products', 'shops', 'media_uploads', 'customer_profiles'):
        op.drop_table(table)
    bind = op.get_bind()
    for enum in (stock_kind, ad_status, listing_status):
        enum.drop(bind, checkfirst=True)
