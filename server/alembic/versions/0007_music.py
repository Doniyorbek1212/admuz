"""music_tracks: songs for the hub's Music section (Uzbek old/new, world, for the car), uploaded by admins

Revision ID: 0007
Revises: 0006
Create Date: 2026-11-07 10:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = '0007'
down_revision: str | Sequence[str] | None = '0006'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        'music_tracks',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('category', sa.String(length=16), nullable=False),
        sa.Column('title', sa.String(length=200), nullable=False),
        sa.Column('artist', sa.String(length=200), nullable=False, server_default=''),
        sa.Column('audio', sa.String(length=64), nullable=False),
        sa.Column('size_bytes', sa.BigInteger(), nullable=False, server_default='0'),
        sa.Column('duration_seconds', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('active', sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index('ix_music_tracks_category_created', 'music_tracks', ['category', 'created_at'])


def downgrade() -> None:
    op.drop_index('ix_music_tracks_category_created', table_name='music_tracks')
    op.drop_table('music_tracks')
