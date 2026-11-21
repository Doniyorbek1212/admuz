"""Rendered-show gifts from gift_renders/manifest.json: key, sound, show length, tier, ru/en names

Revision ID: 0016
Revises: 0015
Create Date: 2026-11-10 20:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = '0016'
down_revision: str | Sequence[str] | None = '0015'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column('gift_items', sa.Column('key', sa.String(32), nullable=True))
    op.create_unique_constraint('uq_gift_items_key', 'gift_items', ['key'])
    op.add_column('gift_items', sa.Column('sound', sa.String(64), server_default='', nullable=False))
    op.add_column('gift_items', sa.Column('duration_ms', sa.Integer(), server_default='0', nullable=False))
    op.add_column('gift_items', sa.Column('tier', sa.Integer(), server_default='0', nullable=False))
    op.add_column('gift_items', sa.Column('title_ru', sa.String(64), server_default='', nullable=False))
    op.add_column('gift_items', sa.Column('title_en', sa.String(64), server_default='', nullable=False))


def downgrade() -> None:
    for column in ('title_en', 'title_ru', 'tier', 'duration_ms', 'sound'):
        op.drop_column('gift_items', column)
    op.drop_constraint('uq_gift_items_key', 'gift_items', type_='unique')
    op.drop_column('gift_items', 'key')
