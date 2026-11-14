"""Rendered full-screen shows (transparent animated WebP) for premium effect gifts

Revision ID: 0012
Revises: 0011
Create Date: 2026-11-07 17:30:00

"""
from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = '0012'
down_revision: str | Sequence[str] | None = '0011'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column('gift_items', sa.Column('show', sa.String(64), server_default='', nullable=False))


def downgrade() -> None:
    op.drop_column('gift_items', 'show')
