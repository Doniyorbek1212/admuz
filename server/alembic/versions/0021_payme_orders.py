"""Payme orders: balance top-ups paid through the Payme Merchant API

Revision ID: 0021
Revises: 0020
Create Date: 2026-11-13 12:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = '0021'
down_revision: str | Sequence[str] | None = '0020'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        'payme_orders',
        sa.Column('id', postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column('customer_id', postgresql.UUID(as_uuid=True), sa.ForeignKey('customers.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('amount_uzs', sa.Integer(), nullable=False),
        sa.Column('payme_id', sa.String(64), nullable=True, unique=True),
        sa.Column('payme_time', sa.BigInteger(), nullable=True),
        sa.Column('state', sa.SmallInteger(), server_default='0', nullable=False),
        sa.Column('create_time', sa.BigInteger(), server_default='0', nullable=False),
        sa.Column('perform_time', sa.BigInteger(), server_default='0', nullable=False),
        sa.Column('cancel_time', sa.BigInteger(), server_default='0', nullable=False),
        sa.Column('reason', sa.SmallInteger(), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index('ix_payme_orders_customer_id', 'payme_orders', ['customer_id'])
    op.create_index('ix_payme_orders_payme_time', 'payme_orders', ['payme_time'])


def downgrade() -> None:
    op.drop_table('payme_orders')
