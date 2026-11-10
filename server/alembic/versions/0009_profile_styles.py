"""UZARO profile styles (the header background a Telegram user picked) and premium video gifts

Revision ID: 0009
Revises: 0008
Create Date: 2026-11-07 15:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = '0009'
down_revision: str | Sequence[str] | None = '0008'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        'profile_styles',
        sa.Column('telegram_user_id', sa.BigInteger(), primary_key=True),
        sa.Column('background', sa.String(15), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    )
    op.add_column('gift_items', sa.Column('video', sa.String(64), server_default='', nullable=False))


def downgrade() -> None:
    op.drop_column('gift_items', 'video')
    op.drop_table('profile_styles')
