"""Admin sign-in confirmed in Telegram

Revision ID: 0024
Revises: 0023
Create Date: 2026-11-16 18:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = '0024'
down_revision: str | Sequence[str] | None = '0023'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column('admin_users', sa.Column('telegram_user_id', sa.BigInteger(), nullable=True))


def downgrade() -> None:
    op.drop_column('admin_users', 'telegram_user_id')
