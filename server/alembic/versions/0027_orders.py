"""Shop orders: a buyer's cart from one shop, followed by the seller from new to delivered

Revision ID: 0027
Revises: 0026
Create Date: 2026-11-26 12:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = '0027'
down_revision: str | Sequence[str] | None = '0026'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

ORDER_STATUS = ('new', 'accepted', 'shipped', 'delivered', 'cancelled')


def upgrade() -> None:
    status = postgresql.ENUM(*ORDER_STATUS, name='order_status', create_type=False)
    status.create(op.get_bind(), checkfirst=True)
    op.create_table(
        'orders',
        sa.Column('id', sa.UUID(), primary_key=True),
        sa.Column('shop_id', sa.UUID(), sa.ForeignKey('shops.id', ondelete='CASCADE'), nullable=False),
        sa.Column('buyer_id', sa.UUID(), sa.ForeignKey('customers.id', ondelete='CASCADE'), nullable=False),
        sa.Column('status', status, nullable=False),
        sa.Column('items', postgresql.JSONB(), nullable=False),
        sa.Column('total_uzs', sa.BigInteger(), nullable=False),
        sa.Column('delivery', sa.String(length=16), nullable=False),
        sa.Column('name', sa.String(length=80), nullable=False),
        sa.Column('phone', sa.String(length=20), nullable=False),
        sa.Column('address', sa.String(length=300), nullable=False),
        sa.Column('comment', sa.String(length=500), nullable=False),
        sa.Column('cancel_reason', sa.String(length=256), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint('total_uzs >= 0', name='ck_orders_total_non_negative'),
    )
    op.create_index('ix_orders_shop_created', 'orders', ['shop_id', 'created_at'])
    op.create_index('ix_orders_buyer_created', 'orders', ['buyer_id', 'created_at'])


def downgrade() -> None:
    op.drop_index('ix_orders_buyer_created', table_name='orders')
    op.drop_index('ix_orders_shop_created', table_name='orders')
    op.drop_table('orders')
    postgresql.ENUM(name='order_status').drop(op.get_bind(), checkfirst=True)
