"""Paid UZARO badges next to a Telegram user's name: checkmark or custom emoji, by the month

Revision ID: 0017
Revises: 0016
Create Date: 2026-11-11 11:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = '0017'
down_revision: str | Sequence[str] | None = '0016'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        'profile_badges',
        sa.Column('telegram_user_id', sa.BigInteger(), primary_key=True, autoincrement=False),
        sa.Column('emoji_id', sa.BigInteger(), server_default='0', nullable=False),
        sa.Column('expires_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )


def downgrade() -> None:
    op.drop_table('profile_badges')
