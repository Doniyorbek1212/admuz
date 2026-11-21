"""Online chess and checkers for the app: profile and ratings, leaderboards, game history, tournaments, and the
live WebSocket (/v1/games/ws) that carries seeks, challenges, moves and clocks (see app/games/hub.py)."""

import asyncio
import contextlib
import json
import uuid
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect, status
from pydantic import BaseModel, StringConstraints
from sqlalchemy import func, or_, select

from app.db import SessionFactory
from app.deps import CustomerDep, DbDep, customer_from_token, rate_limit
from app.errors import ApiError, bad_request, conflict, not_found
from app.games import rating as glicko
from app.games import service
from app.games.hub import game_out, hub
from app.games.models import KINDS, SPEEDS, Game, GamePlayer, GameRating, Tournament, TournamentPlayer
from app.games.service import GameError

router = APIRouter(prefix="/v1/games", tags=["games"])
Kind = Literal["chess", "checkers"]
Speed = Literal["bullet", "blitz", "rapid"]
AUTH_TIMEOUT_S = 10
MAX_MESSAGE_CHARS = 2000


def _rating_out(row: GameRating | None, kind: str, speed: str) -> dict[str, Any]:
    if row is None:
        return {"kind": kind, "speed": speed, "rating": 1500, "provisional": True, "games": 0, "wins": 0, "losses": 0, "draws": 0, "best": 1500}
    return {"kind": kind, "speed": speed, "rating": round(row.rating), "provisional": glicko.provisional(glicko.Glicko(row.rating, row.deviation)),
            "games": row.games, "wins": row.wins, "losses": row.losses, "draws": row.draws, "best": round(row.best)}


def _game_error(exc: GameError) -> ApiError:
    return conflict(exc.code) if exc.code != "TELEGRAM_NOT_LINKED" else ApiError(status.HTTP_403_FORBIDDEN, exc.code)


class NameIn(BaseModel):
    name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=2, max_length=32)]


@router.get("/me")
async def me(current: CustomerDep, db: DbDep) -> dict[str, Any]:
    player = await db.get(GamePlayer, current.id)
    rows = {(r.kind, r.speed): r for r in await db.scalars(select(GameRating).where(GameRating.customer_id == current.id))}
    return {
        "name": player.name if player else "",
        "banned": bool(player and player.banned),
        "ratings": [_rating_out(rows.get((k, s)), k, s) for k in KINDS for s in SPEEDS],
        "time_controls": [{"initial": i, "increment": n, "speed": service.speed_of(i, n)} for i, n in service.TIME_CONTROLS],
    }


@router.put("/me")
async def set_name(body: NameIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    await rate_limit(f"gamename:{current.id}", limit=10, window_seconds=3600)
    try:
        player = await service.player(db, current.id, body.name)
    except GameError as exc:
        raise _game_error(exc) from exc
    player.name = " ".join(body.name.split())
    await db.commit()
    return {"name": player.name}


@router.get("/leaderboard")
async def leaderboard(current: CustomerDep, db: DbDep, kind: Kind = "chess", speed: Speed = "blitz") -> dict[str, Any]:
    rows = (await db.execute(
        select(GameRating, GamePlayer)
        .join(GamePlayer, GamePlayer.customer_id == GameRating.customer_id)
        .where(GameRating.kind == kind, GameRating.speed == speed, GameRating.games > 0, GamePlayer.banned.is_(False))
        .order_by(GameRating.rating.desc())
        .limit(100)
    )).all()
    mine = await db.get(GameRating, (current.id, kind, speed))
    my_rank = None
    if mine is not None and mine.games > 0:
        my_rank = 1 + (await db.scalar(select(func.count()).select_from(GameRating).where(
            GameRating.kind == kind, GameRating.speed == speed, GameRating.games > 0, GameRating.rating > mine.rating)) or 0)
    return {
        "items": [_rating_out(r, kind, speed) | {"rank": i + 1, "name": p.name, "telegram_user_id": p.telegram_user_id,
                                               "me": p.customer_id == current.id} for i, (r, p) in enumerate(rows)],
        "me": _rating_out(mine, kind, speed) | {"rank": my_rank},
    }


async def _players(db: DbDep, games: list[Game]) -> dict[uuid.UUID, GamePlayer]:
    ids = {g.white_id for g in games} | {g.black_id for g in games}
    return {p.customer_id: p for p in await db.scalars(select(GamePlayer).where(GamePlayer.customer_id.in_(ids)))} if ids else {}


@router.get("/history")
async def history(current: CustomerDep, db: DbDep, kind: Kind | None = None,
                  limit: Annotated[int, Query(ge=1, le=50)] = 30, offset: Annotated[int, Query(ge=0, le=10_000)] = 0) -> dict[str, Any]:
    stmt = select(Game).where(or_(Game.white_id == current.id, Game.black_id == current.id), Game.status != "aborted")
    if kind:
        stmt = stmt.where(Game.kind == kind)
    games = list(await db.scalars(stmt.order_by(Game.created_at.desc()).offset(offset).limit(limit + 1)))
    players = await _players(db, games)
    return {"items": [game_out(g, players) for g in games[:limit]], "has_more": len(games) > limit}


@router.get("/active")
async def active(current: CustomerDep, db: DbDep) -> dict[str, Any]:
    """The player's unfinished games, so the app can bring them back after a restart."""
    games = list(await db.scalars(select(Game).where(or_(Game.white_id == current.id, Game.black_id == current.id), Game.status == "active")))
    players = await _players(db, games)
    return {"items": [game_out(g, players) for g in games]}


@router.get("/games/{game_id}")
async def game_detail(game_id: uuid.UUID, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    game = await db.get(Game, game_id)
    if game is None:
        raise not_found("GAME_NOT_FOUND")
    return game_out(game, await _players(db, [game]))


# ---- tournaments ----


def tournament_out(t: Tournament, players: int = 0, joined: bool = False) -> dict[str, Any]:
    split = list(t.prize_split or [])
    return {
        "id": str(t.id), "kind": t.kind, "title": t.title, "description": t.description, "initial": t.initial_s,
        "increment": t.increment_s, "speed": service.speed_of(t.initial_s, t.increment_s),
        "starts_at": t.starts_at.isoformat(), "ends_at": t.ends_at.isoformat(), "status": t.status,
        "prize_uzs": t.prize_uzs, "prize_split": split, "prizes": [t.prize_uzs * p // 100 for p in split],
        "min_games": t.min_games, "players": players, "joined": joined,
    }


async def standings_out(db: DbDep, t: Tournament, viewer: uuid.UUID | None) -> list[dict[str, Any]]:
    rows = await service.standings(db, t)
    names = {p.customer_id: p for p in await db.scalars(select(GamePlayer).where(GamePlayer.customer_id.in_([r.customer_id for r in rows])))} if rows else {}
    out = []
    for index, r in enumerate(rows):
        p = names.get(r.customer_id)
        out.append({"rank": index + 1, "name": p.name if p else "?", "telegram_user_id": p.telegram_user_id if p else None,
                    "score": r.score, "games": r.games, "wins": r.wins, "streak": r.streak, "rating": r.rating,
                    "fire": r.streak >= service.STREAK_FOR_DOUBLE, "place": r.place, "prize_uzs": r.prize_uzs,
                    "disqualified": r.disqualified, "me": r.customer_id == viewer, "customer_id": str(r.customer_id)})
    return out


@router.get("/tournaments")
async def tournaments(current: CustomerDep, db: DbDep) -> dict[str, Any]:
    rows = list(await db.scalars(select(Tournament).where(Tournament.status != "cancelled").order_by(Tournament.starts_at.desc()).limit(40)))
    counts = dict((await db.execute(select(TournamentPlayer.tournament_id, func.count()).group_by(TournamentPlayer.tournament_id))).all())
    mine = set(await db.scalars(select(TournamentPlayer.tournament_id).where(TournamentPlayer.customer_id == current.id)))
    order = {"running": 0, "scheduled": 1, "finished": 2, "paid": 2}
    rows.sort(key=lambda t: (order.get(t.status, 3), t.starts_at.timestamp() if t.status == "scheduled" else -t.starts_at.timestamp()))
    return {"items": [tournament_out(t, counts.get(t.id, 0), t.id in mine) for t in rows]}


@router.get("/tournaments/{tournament_id}")
async def tournament_detail(tournament_id: uuid.UUID, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    t = await db.get(Tournament, tournament_id)
    if t is None or t.status == "cancelled":
        raise not_found("TOURNAMENT_NOT_FOUND")
    standing = await standings_out(db, t, current.id)
    for row in standing:
        row.pop("customer_id")
    return tournament_out(t, len(standing), any(r["me"] for r in standing)) | {"standings": standing}


@router.post("/tournaments/{tournament_id}/join")
async def join_tournament(tournament_id: uuid.UUID, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    t = await db.get(Tournament, tournament_id)
    if t is None or t.status not in ("scheduled", "running") or service.now() >= t.ends_at:
        raise bad_request("TOURNAMENT_CLOSED")
    try:
        player = await service.player(db, current.id)
    except GameError as exc:
        raise _game_error(exc) from exc
    if player.banned:
        raise conflict("PLAYER_BANNED")
    if await db.get(TournamentPlayer, (t.id, current.id)) is None:
        row = await service.rating(db, current.id, t.kind, service.speed_of(t.initial_s, t.increment_s))
        db.add(TournamentPlayer(tournament_id=t.id, customer_id=current.id, rating=round(row.rating), score=0, games=0,
                                wins=0, streak=0, prize_uzs=0, disqualified=False))
        await db.commit()
    return {"joined": True}


@router.post("/tournaments/{tournament_id}/leave")
async def leave_tournament(tournament_id: uuid.UUID, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    """Before the start this removes the player; once running they just stop being paired (points stay)."""
    t = await db.get(Tournament, tournament_id)
    entry = await db.get(TournamentPlayer, (tournament_id, current.id))
    hub.arena.get(tournament_id, set()).discard(current.id)
    if t is not None and entry is not None and t.status == "scheduled":
        await db.delete(entry)
        await db.commit()
    return {"joined": t is not None and entry is not None and t.status != "scheduled"}


# ---- live ----


@router.websocket("/ws")
async def live(socket: WebSocket) -> None:
    """First message must be {"t": "auth", "token": "<access token>"}; then hub messages both ways."""
    await socket.accept()
    try:
        first = await asyncio.wait_for(socket.receive_json(), timeout=AUTH_TIMEOUT_S)
        async with SessionFactory() as db:
            current = await customer_from_token(db, str(first.get("token", ""))) if isinstance(first, dict) and first.get("t") == "auth" else None
    except (TimeoutError, ApiError, WebSocketDisconnect, ValueError):
        current = None
    if current is None:
        with contextlib.suppress(Exception):
            await socket.close(code=4401)
        return
    customer_id = current.id
    hub.connect(customer_id, socket)
    await socket.send_json({"t": "ready"})
    try:
        while True:
            raw = await socket.receive_text()
            if len(raw) > MAX_MESSAGE_CHARS:
                await socket.send_json({"t": "error", "code": "MESSAGE_TOO_LONG"})
                continue
            try:
                message = json.loads(raw)
            except ValueError:
                await socket.send_json({"t": "error", "code": "BAD_MESSAGE"})
                continue
            if isinstance(message, dict):
                await hub.handle(customer_id, message)
    except WebSocketDisconnect:
        pass
    finally:
        hub.disconnect(customer_id, socket)
