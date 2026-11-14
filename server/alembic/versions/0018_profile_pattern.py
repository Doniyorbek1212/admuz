"""Profile background pattern: a custom emoji id or a plain emoji scattered over the header

Revision ID: 0018
Revises: 0017
Create Date: 2026-11-11 12:20:00

"""
from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = '0018'
down_revision: str | Sequence[str] | None = '0017'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column('profile_styles', sa.Column('pattern', sa.String(32), server_default='', nullable=False))


def downgrade() -> None:
    op.drop_column('profile_styles', 'pattern')
