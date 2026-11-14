"""Premium gifts drawn by the app over the screen (lion, plane, helicopter) instead of a video

Revision ID: 0010
Revises: 0009
Create Date: 2026-11-07 15:30:00

"""
from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = '0010'
down_revision: str | Sequence[str] | None = '0009'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column('gift_items', sa.Column('effect', sa.String(24), server_default='', nullable=False))


def downgrade() -> None:
    op.drop_column('gift_items', 'effect')
