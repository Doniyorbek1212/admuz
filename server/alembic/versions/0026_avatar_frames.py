"""Animated avatar frames: the frame shop and the frames each Telegram user owns and wears

Revision ID: 0026
Revises: 0025
Create Date: 2026-11-24 12:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = '0026'
down_revision: str | Sequence[str] | None = '0025'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        'frame_items',
        sa.Column('key', sa.String(length=32), primary_key=True),
        sa.Column('title', sa.String(length=64), nullable=False),
        sa.Column('title_ru', sa.String(length=64), nullable=False),
        sa.Column('title_en', sa.String(length=64), nullable=False),
        sa.Column('tier', sa.Integer(), nullable=False),
        sa.Column('price_uzs', sa.Integer(), nullable=False),
        sa.Column('animation', sa.String(length=64), nullable=False),
        sa.Column('small', sa.String(length=64), nullable=False),
        sa.Column('sort', sa.Integer(), nullable=False),
        sa.Column('active', sa.Boolean(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_table(
        'owned_frames',
        sa.Column('telegram_user_id', sa.BigInteger(), primary_key=True),
        sa.Column('frame_key', sa.String(length=32), sa.ForeignKey('frame_items.key', ondelete='CASCADE'), primary_key=True),
        sa.Column('equipped', sa.Boolean(), nullable=False),
        sa.Column('price_uzs', sa.Integer(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    # the lookup for everyone on screen: worn frames only
    op.create_index('ix_owned_frames_worn', 'owned_frames', ['telegram_user_id'], postgresql_where=sa.text('equipped'))


def downgrade() -> None:
    op.drop_index('ix_owned_frames_worn', table_name='owned_frames')
    op.drop_table('owned_frames')
    op.drop_table('frame_items')
