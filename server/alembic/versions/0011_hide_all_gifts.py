"""A profile switch that hides all received gifts from people opening it

Revision ID: 0011
Revises: 0010
Create Date: 2026-11-07 16:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = '0011'
down_revision: str | Sequence[str] | None = '0010'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column('profile_styles', sa.Column('hide_gifts', sa.Boolean(), server_default=sa.false(), nullable=False))


def downgrade() -> None:
    # Rows kept only for the switch carry no background; they mean nothing without it.
    op.execute("DELETE FROM profile_styles WHERE background = ''")
    op.drop_column('profile_styles', 'hide_gifts')
