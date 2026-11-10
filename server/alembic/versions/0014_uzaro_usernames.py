"""UZARO usernames: a public @name per customer, resolved to their proven Telegram account

Revision ID: 0014
Revises: 0013
Create Date: 2026-11-10 12:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = '0014'
down_revision: str | Sequence[str] | None = '0013'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        'uzaro_usernames',
        sa.Column('customer_id', sa.UUID(), sa.ForeignKey('customers.id', ondelete='CASCADE'), primary_key=True),
        sa.Column('username', sa.String(32), nullable=False, unique=True),
        sa.Column('contact_token', sa.String(80), server_default='', nullable=False),
        sa.Column('contact_expires_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )


def downgrade() -> None:
    op.drop_table('uzaro_usernames')
