"""Quick links: sites and apps admins pin to every user's hub "Tezkor" row

Revision ID: 0020
Revises: 0019
Create Date: 2026-11-12 12:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = '0020'
down_revision: str | Sequence[str] | None = '0019'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        'quick_links',
        sa.Column('id', postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column('title', sa.String(40), nullable=False),
        sa.Column('url', sa.String(500), nullable=False),
        sa.Column('logo', sa.String(64), server_default='', nullable=False),
        sa.Column('android_package', sa.String(150), server_default='', nullable=False),
        sa.Column('position', sa.Integer(), server_default='1', nullable=False),
        sa.Column('active', sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column('until', sa.Date(), nullable=True),
        sa.Column('note', sa.String(300), server_default='', nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )


def downgrade() -> None:
    op.drop_table('quick_links')
