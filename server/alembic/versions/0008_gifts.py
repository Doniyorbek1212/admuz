"""UZARO gifts: telegram_links (bot-proven Telegram ids), gift catalog, sent gifts, so'm wallet and top-ups

Revision ID: 0008
Revises: 0007
Create Date: 2026-11-07 13:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = '0008'
down_revision: str | Sequence[str] | None = '0007'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def _created() -> sa.Column:
    return sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False)


def upgrade() -> None:
    op.create_table(
        'telegram_links',
        sa.Column('customer_id', sa.UUID(), sa.ForeignKey('customers.id', ondelete='CASCADE'), primary_key=True),
        sa.Column('telegram_user_id', sa.BigInteger(), nullable=False, unique=True),
        sa.Column('linked_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    )
    op.create_table(
        'gift_items',
        sa.Column('id', sa.UUID(), primary_key=True),
        sa.Column('title', sa.String(length=64), nullable=False),
        sa.Column('price_uzs', sa.Integer(), nullable=False),
        sa.Column('animation', sa.String(length=64), nullable=False),
        sa.Column('sort', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('active', sa.Boolean(), nullable=False, server_default=sa.true()),
        _created(),
    )
    op.create_table(
        'sent_gifts',
        sa.Column('id', sa.UUID(), primary_key=True),
        sa.Column('gift_id', sa.UUID(), sa.ForeignKey('gift_items.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('sender_customer_id', sa.UUID(), sa.ForeignKey('customers.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('sender_telegram_id', sa.BigInteger(), nullable=False),
        sa.Column('recipient_telegram_id', sa.BigInteger(), nullable=False),
        sa.Column('text', sa.String(length=140), nullable=False, server_default=''),
        sa.Column('price_uzs', sa.Integer(), nullable=False),
        sa.Column('hidden', sa.Boolean(), nullable=False, server_default=sa.false()),
        _created(),
    )
    op.create_index('ix_sent_gifts_sender_customer_id', 'sent_gifts', ['sender_customer_id'])
    op.create_index('ix_sent_gifts_recipient_created', 'sent_gifts', ['recipient_telegram_id', 'created_at'])
    op.create_table(
        'wallet_ledger',
        sa.Column('id', sa.UUID(), primary_key=True),
        sa.Column('customer_id', sa.UUID(), sa.ForeignKey('customers.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('delta_uzs', sa.BigInteger(), nullable=False),
        sa.Column('kind', sa.String(length=16), nullable=False),
        sa.Column('reference', sa.String(length=64), nullable=False),
        _created(),
        sa.UniqueConstraint('customer_id', 'kind', 'reference', name='uq_wallet_ledger_ref'),
    )
    op.create_index('ix_wallet_ledger_customer_id', 'wallet_ledger', ['customer_id'])
    op.create_table(
        'wallet_topups',
        sa.Column('id', sa.UUID(), primary_key=True),
        sa.Column('customer_id', sa.UUID(), sa.ForeignKey('customers.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('amount_uzs', sa.Integer(), nullable=False),
        sa.Column('receipt_path', sa.String(length=200), nullable=False),
        sa.Column('status', sa.String(length=16), nullable=False, server_default='pending'),
        sa.Column('reject_reason', sa.String(length=300), nullable=False, server_default=''),
        sa.Column('reviewed_by', sa.String(length=64), nullable=False, server_default=''),
        _created(),
        sa.Column('reviewed_at', sa.DateTime(timezone=True)),
    )
    op.create_index('ix_wallet_topups_customer_id', 'wallet_topups', ['customer_id'])
    op.create_index('ix_wallet_topups_status_created', 'wallet_topups', ['status', 'created_at'])


def downgrade() -> None:
    for table in ('wallet_topups', 'wallet_ledger', 'sent_gifts', 'gift_items', 'telegram_links'):
        op.drop_table(table)
