"""movies: admin-uploaded films and series, compressed and stored in a public Telegram channel

Revision ID: 0005
Revises: 0004
Create Date: 2026-11-02 10:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = '0005'
down_revision: str | Sequence[str] | None = '0004'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_kind = postgresql.ENUM('movie', 'series', name='movie_kind', create_type=False)
_status = postgresql.ENUM('uploading', 'queued', 'processing', 'ready', 'failed', name='video_status', create_type=False)


def upgrade() -> None:
    _kind.create(op.get_bind(), checkfirst=True)
    _status.create(op.get_bind(), checkfirst=True)
    op.create_table(
        'movie_titles',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('kind', _kind, nullable=False),
        sa.Column('title', sa.String(length=200), nullable=False),
        sa.Column('description', sa.String(length=3000), nullable=False, server_default=''),
        sa.Column('year', sa.Integer(), nullable=True),
        sa.Column('genres', sa.String(length=200), nullable=False, server_default=''),
        sa.Column('country', sa.String(length=80), nullable=False, server_default=''),
        sa.Column('language', sa.String(length=40), nullable=False, server_default=''),
        sa.Column('poster', sa.String(length=64), nullable=True),
        sa.Column('active', sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column('sort_order', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_table(
        'movie_videos',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('title_id', sa.UUID(), nullable=False),
        sa.Column('season', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('episode', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('name', sa.String(length=200), nullable=False, server_default=''),
        sa.Column('status', _status, nullable=False, server_default='uploading'),
        sa.Column('error', sa.String(length=500), nullable=False, server_default=''),
        sa.Column('original_name', sa.String(length=255), nullable=False, server_default=''),
        sa.Column('original_bytes', sa.BigInteger(), nullable=False, server_default='0'),
        sa.Column('uploaded_bytes', sa.BigInteger(), nullable=False, server_default='0'),
        sa.Column('compressed_bytes', sa.BigInteger(), nullable=False, server_default='0'),
        sa.Column('duration_seconds', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('width', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('height', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('tg_channel', sa.String(length=64), nullable=False, server_default=''),
        sa.Column('tg_message_id', sa.BigInteger(), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.ForeignKeyConstraint(['title_id'], ['movie_titles.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index('ix_movie_videos_title', 'movie_videos', ['title_id'])
    op.create_index('ix_movie_videos_status', 'movie_videos', ['status'])


def downgrade() -> None:
    op.drop_index('ix_movie_videos_status', table_name='movie_videos')
    op.drop_index('ix_movie_videos_title', table_name='movie_videos')
    op.drop_table('movie_videos')
    op.drop_table('movie_titles')
    _status.drop(op.get_bind(), checkfirst=True)
    _kind.drop(op.get_bind(), checkfirst=True)
