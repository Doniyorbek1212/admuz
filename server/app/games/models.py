"""Tables of online chess and checkers: players, ratings, games, arena tournaments."""

import uuid
from datetime import datetime

from sqlalchemy import BigInteger, Boolean, DateTime, Float, ForeignKey, Index, Integer, String, func
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base

KINDS = ("chess", "checkers")
SPEEDS = ("bullet", "blitz", "rapid")


class GamePlayer(Base):
    """A customer's name in games (from their Telegram name, editable) and their proven Telegram id for avatars."""

    __tablename__ = "game_players"

    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"), primary_key=True)
    name: Mapped[str] = mapped_column(String(32))
    telegram_user_id: Mapped[int | None] = mapped_column(BigInteger)
    # Admin fair-play ban: may still play casual games but not rated ones or tournaments.
    banned: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class GameRating(Base):
    """Glicko-2 rating per game and speed (bullet / blitz / rapid), like lichess."""

    __tablename__ = "game_ratings"
    __table_args__ = (Index("ix_game_ratings_board", "kind", "speed", "rating"),)

    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"), primary_key=True)
    kind: Mapped[str] = mapped_column(String(16), primary_key=True)
    speed: Mapped[str] = mapped_column(String(16), primary_key=True)
    rating: Mapped[float] = mapped_column(Float, default=1500.0)
    deviation: Mapped[float] = mapped_column(Float, default=350.0)
    volatility: Mapped[float] = mapped_column(Float, default=0.06)
    games: Mapped[int] = mapped_column(Integer, default=0)
    wins: Mapped[int] = mapped_column(Integer, default=0)
    losses: Mapped[int] = mapped_column(Integer, default=0)
    draws: Mapped[int] = mapped_column(Integer, default=0)
    best: Mapped[float] = mapped_column(Float, default=1500.0)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class Game(Base):
    """One game; [moves] is the whole record, so any position can be replayed and the server re-checks it."""

    __tablename__ = "games"
    __table_args__ = (
        Index("ix_games_white", "white_id", "created_at"),
        Index("ix_games_black", "black_id", "created_at"),
        Index("ix_games_status", "status"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    kind: Mapped[str] = mapped_column(String(16))
    speed: Mapped[str] = mapped_column(String(16))
    initial_s: Mapped[int] = mapped_column(Integer)
    increment_s: Mapped[int] = mapped_column(Integer)
    rated: Mapped[bool] = mapped_column(Boolean, default=True)
    white_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"))
    black_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"))
    tournament_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("tournaments.id", ondelete="SET NULL"), index=True)
    moves: Mapped[list[str]] = mapped_column(JSONB, default=list)
    position: Mapped[str] = mapped_column(String(100), default="")
    white_ms: Mapped[int] = mapped_column(BigInteger)
    black_ms: Mapped[int] = mapped_column(BigInteger)
    turn_started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    status: Mapped[str] = mapped_column(String(16), default="active")  # active | finished | aborted
    winner: Mapped[str] = mapped_column(String(8), default="")  # white | black | draw
    reason: Mapped[str] = mapped_column(String(16), default="")
    draw_offer: Mapped[str] = mapped_column(String(8), default="")  # the side offering a draw now
    white_rating: Mapped[int] = mapped_column(Integer, default=0)
    black_rating: Mapped[int] = mapped_column(Integer, default=0)
    white_delta: Mapped[int] = mapped_column(Integer, default=0)
    black_delta: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Tournament(Base):
    """An arena: during [starts_at, ends_at) players are paired again and again; a win is 2 points, a draw 1, and
    from the third win in a row a win counts double. Entry is free; UZARO puts up [prize_uzs], split by
    [prize_split] (percent per place), paid to the UZARO balance once an admin confirms the results."""

    __tablename__ = "tournaments"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    kind: Mapped[str] = mapped_column(String(16))
    title: Mapped[str] = mapped_column(String(80))
    description: Mapped[str] = mapped_column(String(1000), default="")
    initial_s: Mapped[int] = mapped_column(Integer)
    increment_s: Mapped[int] = mapped_column(Integer)
    starts_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    ends_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    prize_uzs: Mapped[int] = mapped_column(BigInteger, default=0)
    prize_split: Mapped[list[int]] = mapped_column(JSONB, default=list)
    min_games: Mapped[int] = mapped_column(Integer, default=3)
    status: Mapped[str] = mapped_column(String(16), default="scheduled")  # scheduled | running | finished | paid | cancelled
    created_by: Mapped[str] = mapped_column(String(64), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class TournamentPlayer(Base):
    __tablename__ = "tournament_players"

    tournament_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tournaments.id", ondelete="CASCADE"), primary_key=True)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"), primary_key=True)
    score: Mapped[int] = mapped_column(Integer, default=0)
    games: Mapped[int] = mapped_column(Integer, default=0)
    wins: Mapped[int] = mapped_column(Integer, default=0)
    streak: Mapped[int] = mapped_column(Integer, default=0)
    rating: Mapped[int] = mapped_column(Integer, default=1500)
    last_opponent: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True))
    disqualified: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")
    place: Mapped[int | None] = mapped_column(Integer)
    prize_uzs: Mapped[int] = mapped_column(BigInteger, default=0)
    joined_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
