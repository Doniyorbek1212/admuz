"""Online chess and checkers: players, ratings, games, arena tournaments

Revision ID: 0022
Revises: 0021
Create Date: 2026-11-14 18:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = '0022'
down_revision: str | Sequence[str] | None = '0021'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

UUID = postgresql.UUID(as_uuid=True)


def _customer(name: str, **kw) -> sa.Column:
    return sa.Column(name, UUID, sa.ForeignKey('customers.id', ondelete='CASCADE'), nullable=False, **kw)


def upgrade() -> None:
    op.create_table(
        'game_players',
        _customer('customer_id', primary_key=True),
        sa.Column('name', sa.String(32), nullable=False),
        sa.Column('telegram_user_id', sa.BigInteger(), nullable=True),
        sa.Column('banned', sa.Boolean(), server_default='false', nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_table(
        'game_ratings',
        _customer('customer_id', primary_key=True),
        sa.Column('kind', sa.String(16), primary_key=True),
        sa.Column('speed', sa.String(16), primary_key=True),
        sa.Column('rating', sa.Float(), server_default='1500', nullable=False),
        sa.Column('deviation', sa.Float(), server_default='350', nullable=False),
        sa.Column('volatility', sa.Float(), server_default='0.06', nullable=False),
        sa.Column('games', sa.Integer(), server_default='0', nullable=False),
        sa.Column('wins', sa.Integer(), server_default='0', nullable=False),
        sa.Column('losses', sa.Integer(), server_default='0', nullable=False),
        sa.Column('draws', sa.Integer(), server_default='0', nullable=False),
        sa.Column('best', sa.Float(), server_default='1500', nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index('ix_game_ratings_board', 'game_ratings', ['kind', 'speed', 'rating'])
    op.create_table(
        'tournaments',
        sa.Column('id', UUID, primary_key=True),
        sa.Column('kind', sa.String(16), nullable=False),
        sa.Column('title', sa.String(80), nullable=False),
        sa.Column('description', sa.String(1000), server_default='', nullable=False),
        sa.Column('initial_s', sa.Integer(), nullable=False),
        sa.Column('increment_s', sa.Integer(), nullable=False),
        sa.Column('starts_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('ends_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('prize_uzs', sa.BigInteger(), server_default='0', nullable=False),
        sa.Column('prize_split', postgresql.JSONB(), server_default='[]', nullable=False),
        sa.Column('min_games', sa.Integer(), server_default='3', nullable=False),
        sa.Column('status', sa.String(16), server_default='scheduled', nullable=False),
        sa.Column('created_by', sa.String(64), server_default='', nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index('ix_tournaments_starts_at', 'tournaments', ['starts_at'])
    op.create_table(
        'tournament_players',
        sa.Column('tournament_id', UUID, sa.ForeignKey('tournaments.id', ondelete='CASCADE'), primary_key=True),
        _customer('customer_id', primary_key=True),
        sa.Column('score', sa.Integer(), server_default='0', nullable=False),
        sa.Column('games', sa.Integer(), server_default='0', nullable=False),
        sa.Column('wins', sa.Integer(), server_default='0', nullable=False),
        sa.Column('streak', sa.Integer(), server_default='0', nullable=False),
        sa.Column('rating', sa.Integer(), server_default='1500', nullable=False),
        sa.Column('last_opponent', UUID, nullable=True),
        sa.Column('disqualified', sa.Boolean(), server_default='false', nullable=False),
        sa.Column('place', sa.Integer(), nullable=True),
        sa.Column('prize_uzs', sa.BigInteger(), server_default='0', nullable=False),
        sa.Column('joined_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_table(
        'games',
        sa.Column('id', UUID, primary_key=True),
        sa.Column('kind', sa.String(16), nullable=False),
        sa.Column('speed', sa.String(16), nullable=False),
        sa.Column('initial_s', sa.Integer(), nullable=False),
        sa.Column('increment_s', sa.Integer(), nullable=False),
        sa.Column('rated', sa.Boolean(), server_default='true', nullable=False),
        _customer('white_id'),
        _customer('black_id'),
        sa.Column('tournament_id', UUID, sa.ForeignKey('tournaments.id', ondelete='SET NULL'), nullable=True),
        sa.Column('moves', postgresql.JSONB(), server_default='[]', nullable=False),
        sa.Column('position', sa.String(100), server_default='', nullable=False),
        sa.Column('white_ms', sa.BigInteger(), nullable=False),
        sa.Column('black_ms', sa.BigInteger(), nullable=False),
        sa.Column('turn_started_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column('status', sa.String(16), server_default='active', nullable=False),
        sa.Column('winner', sa.String(8), server_default='', nullable=False),
        sa.Column('reason', sa.String(16), server_default='', nullable=False),
        sa.Column('draw_offer', sa.String(8), server_default='', nullable=False),
        sa.Column('white_rating', sa.Integer(), server_default='0', nullable=False),
        sa.Column('black_rating', sa.Integer(), server_default='0', nullable=False),
        sa.Column('white_delta', sa.Integer(), server_default='0', nullable=False),
        sa.Column('black_delta', sa.Integer(), server_default='0', nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column('ended_at', sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index('ix_games_white', 'games', ['white_id', 'created_at'])
    op.create_index('ix_games_black', 'games', ['black_id', 'created_at'])
    op.create_index('ix_games_status', 'games', ['status'])
    op.create_index('ix_games_tournament_id', 'games', ['tournament_id'])


def downgrade() -> None:
    op.drop_table('games')
    op.drop_table('tournament_players')
    op.drop_table('tournaments')
    op.drop_table('game_ratings')
    op.drop_table('game_players')
