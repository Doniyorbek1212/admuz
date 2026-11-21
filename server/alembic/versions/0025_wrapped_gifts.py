"""Gifts sent wrapped: the recipient pulls the ribbon to open them

Revision ID: 0025
Revises: 0024
Create Date: 2026-11-21 12:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = '0025'
down_revision: str | Sequence[str] | None = '0024'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column('sent_gifts', sa.Column('wrapped', sa.Boolean(), nullable=False, server_default=sa.false()))
    op.add_column('sent_gifts', sa.Column('opened_at', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column('sent_gifts', 'opened_at')
    op.drop_column('sent_gifts', 'wrapped')
