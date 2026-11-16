"""The live side of games: connected players, quick-play seeks, friend challenges, moves, clocks and arena pairing.

One instance per process. shortcut: sockets, seeks and challenges live in this process's memory, which is right
for the single uvicorn process the API runs as; with several workers they would move to Redis pub/sub.
Every game change is committed to the database before it is announced, so a restart loses only open seeks.
"""

import asyncio
import contextlib
import logging
import secrets
import time
import uuid
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any, Protocol

from sqlalchemy import select

from app.db import SessionFactory
from app.games import service
from app.games.models import Game, GamePlayer, Tournament, TournamentPlayer
from app.games.rules import analyse
from app.games.service import GameError

log = logging.getLogger("app.games")
CHALLENGE_TTL_S = 120
SEEK_RANGE = 150  # rating gap accepted at once; grows by SEEK_RANGE_GROWTH per second of waiting
SEEK_RANGE_GROWTH = 25
ARENA_PAIR_EVERY_S = 3
SEND_TIMEOUT_S = 5


class Socket(Protocol):
    async def send_json(self, data: Any) -> None: ...


@dataclass
class Seek:
    customer_id: uuid.UUID
    kind: str
    initial_s: int
    increment_s: int
    rated: bool
    rating: float
    since: float = field(default_factory=time.monotonic)


@dataclass
class Challenge:
    id: str
    from_id: uuid.UUID
    to_id: uuid.UUID
    kind: str
    initial_s: int
    increment_s: int
    rated: bool
    expires: float


class Hub:
    def __init__(self) -> None:
        self.sockets: dict[uuid.UUID, set[Socket]] = defaultdict(set)
        self.seeks: list[Seek] = []
        self.challenges: dict[str, Challenge] = {}
        self.watchers: dict[uuid.UUID, set[uuid.UUID]] = defaultdict(set)
        self.arena: dict[uuid.UUID, set[uuid.UUID]] = defaultdict(set)  # tournament -> players ready for a game
        self.locks: dict[uuid.UUID, asyncio.Lock] = defaultdict(asyncio.Lock)
        self.pairing = asyncio.Lock()
        self._last_arena = 0.0

    # ---- connections ----

    def connect(self, customer_id: uuid.UUID, socket: Socket) -> None:
        self.sockets[customer_id].add(socket)

    def disconnect(self, customer_id: uuid.UUID, socket: Socket) -> None:
        sockets = self.sockets.get(customer_id)
        if sockets is None:
            return
        sockets.discard(socket)
        if not sockets:
            del self.sockets[customer_id]
            self.seeks = [s for s in self.seeks if s.customer_id != customer_id]
            for waiting in self.arena.values():
                waiting.discard(customer_id)
            for game_id in [g for g, people in self.watchers.items() if customer_id in people]:
                self.watchers[game_id].discard(customer_id)
                if not self.watchers[game_id]:
                    del self.watchers[game_id]

    async def send(self, customer_id: uuid.UUID, payload: dict[str, Any]) -> None:
        for socket in list(self.sockets.get(customer_id, ())):
            try:
                # A stalled client must not hold up the ticker and everyone else's games.
                await asyncio.wait_for(socket.send_json(payload), SEND_TIMEOUT_S)
            except Exception:
                self.disconnect(customer_id, socket)

    # ---- messages ----

    async def handle(self, customer_id: uuid.UUID, message: dict[str, Any]) -> None:
        kind = message.get("t")
        handler = getattr(self, f"_on_{kind}", None) if isinstance(kind, str) and kind.isidentifier() else None
        if handler is None:
            await self.send(customer_id, {"t": "error", "code": "UNKNOWN_MESSAGE"})
            return
        try:
            await handler(customer_id, message)
        except GameError as exc:
            await self.send(customer_id, {"t": "error", "code": exc.code, "ref": message.get("t")})
        except (KeyError, ValueError, TypeError):
            await self.send(customer_id, {"t": "error", "code": "BAD_MESSAGE", "ref": message.get("t")})

    async def _on_ping(self, customer_id: uuid.UUID, _: dict[str, Any]) -> None:
        await self.send(customer_id, {"t": "pong"})

    async def _on_seek(self, customer_id: uuid.UUID, m: dict[str, Any]) -> None:
        kind, initial_s, increment_s, rated = str(m["kind"]), int(m["initial"]), int(m["increment"]), bool(m.get("rated", True))
        service.check_time_control(kind, initial_s, increment_s)
        async with SessionFactory() as db:
            me = await service.player(db, customer_id, str(m.get("name", "")))
            if rated and me.banned:
                raise GameError("PLAYER_BANNED")
            row = await service.rating(db, customer_id, kind, service.speed_of(initial_s, increment_s))
            await db.commit()
            my_rating = row.rating
        async with self.pairing:
            self.seeks = [s for s in self.seeks if s.customer_id != customer_id]
            self.seeks.append(Seek(customer_id, kind, initial_s, increment_s, rated, my_rating))
        await self.send(customer_id, {"t": "seeking", "kind": kind, "initial": initial_s, "increment": increment_s, "rated": rated})
        await self.match_seeks()

    async def _on_cancel(self, customer_id: uuid.UUID, _: dict[str, Any]) -> None:
        async with self.pairing:
            self.seeks = [s for s in self.seeks if s.customer_id != customer_id]
        await self.send(customer_id, {"t": "cancelled"})

    async def _on_challenge(self, customer_id: uuid.UUID, m: dict[str, Any]) -> None:
        kind, initial_s, increment_s = str(m["kind"]), int(m["initial"]), int(m["increment"])
        service.check_time_control(kind, initial_s, increment_s)
        async with SessionFactory() as db:
            me = await service.player(db, customer_id, str(m.get("name", "")))
            await db.commit()
            friend = await db.scalar(select(GamePlayer).where(GamePlayer.telegram_user_id == int(m["telegram_user_id"])))
        if friend is None or friend.customer_id == customer_id:
            raise GameError("FRIEND_NOT_PLAYING")
        rated = bool(m.get("rated", False))
        if rated and (me.banned or friend.banned):
            raise GameError("PLAYER_BANNED")
        challenge = Challenge(secrets.token_urlsafe(8), customer_id, friend.customer_id, kind, initial_s, increment_s,
                              rated, time.monotonic() + CHALLENGE_TTL_S)
        # One open challenge per sender: a new one replaces the old, so the table cannot be flooded.
        self.challenges = {k: c for k, c in self.challenges.items() if c.from_id != customer_id}
        self.challenges[challenge.id] = challenge
        offer = {"t": "challenge", "id": challenge.id, "from": me.name, "from_telegram_id": me.telegram_user_id, "kind": kind,
                 "initial": initial_s, "increment": increment_s, "rated": challenge.rated}
        await self.send(friend.customer_id, offer)
        await self.send(customer_id, {"t": "challenge_sent", "id": challenge.id, "online": friend.customer_id in self.sockets})

    async def _on_accept(self, customer_id: uuid.UUID, m: dict[str, Any]) -> None:
        challenge = self.challenges.pop(str(m["id"]), None)
        if challenge is None or challenge.to_id != customer_id or challenge.expires < time.monotonic():
            raise GameError("CHALLENGE_GONE")
        async with SessionFactory() as db:
            me = await service.player(db, customer_id, str(m.get("name", "")))
            sender = await db.get(GamePlayer, challenge.from_id)
            if challenge.rated and (me.banned or sender is None or sender.banned):
                raise GameError("PLAYER_BANNED")
            white, black = (challenge.from_id, customer_id) if secrets.randbelow(2) else (customer_id, challenge.from_id)
            game = await service.create_game(db, white, black, challenge.kind, challenge.initial_s, challenge.increment_s, challenge.rated)
            await db.commit()
        await self.announce(game.id)

    async def _on_decline(self, customer_id: uuid.UUID, m: dict[str, Any]) -> None:
        challenge = self.challenges.pop(str(m["id"]), None)
        if challenge is not None and challenge.to_id == customer_id:
            await self.send(challenge.from_id, {"t": "declined", "id": challenge.id})

    async def _on_open(self, customer_id: uuid.UUID, m: dict[str, Any]) -> None:
        game_id = uuid.UUID(str(m["game"]))
        await self.announce(game_id, only=customer_id)  # raises GAME_NOT_FOUND before anything is kept
        async with SessionFactory() as db:
            game = await db.get(Game, game_id)
        if game is not None and game.status == "active":
            self.watchers[game_id].add(customer_id)

    async def _on_move(self, customer_id: uuid.UUID, m: dict[str, Any]) -> None:
        await self._game_action(uuid.UUID(str(m["game"])), lambda db, g: service.play(db, g, customer_id, str(m["move"])))

    async def _on_resign(self, customer_id: uuid.UUID, m: dict[str, Any]) -> None:
        await self._game_action(uuid.UUID(str(m["game"])), lambda db, g: service.resign(db, g, customer_id))

    async def _on_draw(self, customer_id: uuid.UUID, m: dict[str, Any]) -> None:
        await self._game_action(uuid.UUID(str(m["game"])), lambda db, g: service.offer_draw(db, g, customer_id))

    async def _on_decline_draw(self, customer_id: uuid.UUID, m: dict[str, Any]) -> None:
        async def decline(_db: Any, game: Game) -> None:
            service.decline_draw(game, customer_id)

        await self._game_action(uuid.UUID(str(m["game"])), decline)

    async def _on_arena(self, customer_id: uuid.UUID, m: dict[str, Any]) -> None:
        """Ready (or not) for the next game of a running tournament the player has joined."""
        tournament_id = uuid.UUID(str(m["tournament"]))
        async with SessionFactory() as db:
            entry = await db.get(TournamentPlayer, (tournament_id, customer_id))
        if entry is None:
            raise GameError("NOT_IN_TOURNAMENT")
        if m.get("ready", True):
            self.arena[tournament_id].add(customer_id)
        else:
            self.arena[tournament_id].discard(customer_id)
        await self.send(customer_id, {"t": "arena", "tournament": str(tournament_id), "ready": customer_id in self.arena[tournament_id]})

    async def _game_action(self, game_id: uuid.UUID, action: Any) -> None:
        """Runs [action] on the locked game, commits, and sends both players the new state (also after a refused
        move, which re-syncs the client; a flag found while refusing it is saved and announced too)."""
        error: GameError | None = None
        async with self.locks[game_id]:
            async with SessionFactory() as db:
                game = await db.get(Game, game_id, with_for_update=True)
                if game is None:
                    self.locks.pop(game_id, None)  # no lock kept for ids that are not games
                    raise GameError("GAME_NOT_FOUND")
                try:
                    await action(db, game)
                except GameError as exc:
                    error = exc
                await db.commit()
        await self.announce(game_id)
        if error is not None:
            raise error

    # ---- announcing ----

    async def announce(self, game_id: uuid.UUID, only: uuid.UUID | None = None) -> None:
        async with SessionFactory() as db:
            game = await db.get(Game, game_id)
            if game is None:
                raise GameError("GAME_NOT_FOUND")
            players = {p.customer_id: p for p in await db.scalars(
                select(GamePlayer).where(GamePlayer.customer_id.in_([game.white_id, game.black_id])))}
        payload = {"t": "game", "game": game_out(game, players)}
        targets = {only} if only else {game.white_id, game.black_id} | self.watchers.get(game_id, set())
        for customer_id in targets:
            await self.send(customer_id, payload)
        if game.status != "active":
            self.watchers.pop(game_id, None)
            self.locks.pop(game_id, None)

    # ---- matchmaking ----

    async def match_seeks(self) -> None:
        created: list[uuid.UUID] = []
        async with self.pairing:
            now = time.monotonic()
            # A snapshot: disconnect() may replace self.seeks while a game is being created below.
            seeks = list(self.seeks)
            taken: set[int] = set()
            matched: list[Seek] = []
            for i, a in enumerate(seeks):
                if i in taken:
                    continue
                for j in range(i + 1, len(seeks)):
                    b = seeks[j]
                    if j in taken or (a.kind, a.initial_s, a.increment_s, a.rated) != (b.kind, b.initial_s, b.increment_s, b.rated):
                        continue
                    gap = SEEK_RANGE + SEEK_RANGE_GROWTH * (now - min(a.since, b.since))
                    if abs(a.rating - b.rating) > gap:
                        continue
                    taken |= {i, j}
                    matched += [a, b]
                    async with SessionFactory() as db:
                        white, black = (a.customer_id, b.customer_id) if secrets.randbelow(2) else (b.customer_id, a.customer_id)
                        game = await service.create_game(db, white, black, a.kind, a.initial_s, a.increment_s, a.rated)
                        await db.commit()
                    created.append(game.id)
                    break
            self.seeks = [s for s in self.seeks if not any(s is t for t in matched)]
        for game_id in created:
            await self.announce(game_id)

    # ---- the ticker: flags, seek widening, tournaments ----

    async def tick(self) -> None:
        ended: list[uuid.UUID] = []
        async with SessionFactory() as db:
            at = service.now()
            for game in await db.scalars(select(Game).where(Game.status == "active")):
                due = service.deadline(game)
                if due is not None and due <= at:
                    ended.append(game.id)
        for game_id in ended:
            with contextlib.suppress(GameError):
                await self._game_action(game_id, lambda db, g: service.flag_if_due(db, g, service.now()))
        if self.seeks:
            await self.match_seeks()
        if time.monotonic() - self._last_arena >= ARENA_PAIR_EVERY_S:
            self._last_arena = time.monotonic()
            await self.run_tournaments()
        stale = [k for k, c in self.challenges.items() if c.expires < time.monotonic()]
        for key in stale:
            self.challenges.pop(key, None)

    async def run_tournaments(self) -> None:
        created: list[uuid.UUID] = []
        async with SessionFactory() as db:
            at = service.now()
            # Locked, so an admin cancel or edit cannot be overwritten by this round (and a cancelled
            # tournament can never turn "finished" and payable).
            rows = await db.scalars(select(Tournament).where(Tournament.status.in_(("scheduled", "running"))).with_for_update())
            for tournament in rows:
                if tournament.status == "scheduled" and tournament.starts_at <= at:
                    tournament.status = "running"
                if tournament.status != "running":
                    continue
                busy = set(await db.scalars(select(Game.white_id).where(Game.tournament_id == tournament.id, Game.status == "active")))
                busy |= set(await db.scalars(select(Game.black_id).where(Game.tournament_id == tournament.id, Game.status == "active")))
                if at >= tournament.ends_at:
                    self.arena.pop(tournament.id, None)
                    if not busy:  # the last games have ended: final places
                        tournament.status = "finished"
                        await service.place_players(db, tournament)
                    continue
                ready = self.arena.get(tournament.id, set()) - busy
                if len(ready) < 2:
                    continue
                banned = select(GamePlayer.customer_id).where(GamePlayer.banned.is_(True))
                waiting = list(await db.scalars(select(TournamentPlayer).where(
                    TournamentPlayer.tournament_id == tournament.id, TournamentPlayer.customer_id.in_(ready),
                    TournamentPlayer.disqualified.is_(False), TournamentPlayer.customer_id.not_in(banned))))
                for white, black in service.pair_arena(waiting):
                    game = await service.create_game(db, white, black, tournament.kind, tournament.initial_s,
                                                     tournament.increment_s, rated=True, tournament_id=tournament.id)
                    created.append(game.id)
            await db.commit()
        for game_id in created:
            await self.announce(game_id)

    async def run(self, stop: asyncio.Event) -> None:
        while not stop.is_set():
            try:
                await self.tick()
            except Exception:
                log.exception("game ticker round failed")
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(stop.wait(), timeout=1)


def game_out(game: Game, players: dict[uuid.UUID, GamePlayer]) -> dict[str, Any]:
    at = service.now()
    state = analyse(game.kind, list(game.moves))
    active = game.status == "active"

    def person(customer_id: uuid.UUID, rating: int, delta: int) -> dict[str, Any]:
        p = players.get(customer_id)
        return {"id": str(customer_id), "name": p.name if p else "?", "telegram_user_id": p.telegram_user_id if p else None,
                "rating": rating, "delta": delta}

    return {
        "id": str(game.id), "kind": game.kind, "speed": game.speed, "initial": game.initial_s, "increment": game.increment_s,
        "rated": game.rated, "tournament_id": str(game.tournament_id) if game.tournament_id else None,
        "white": person(game.white_id, game.white_rating, game.white_delta),
        "black": person(game.black_id, game.black_rating, game.black_delta),
        "moves": list(game.moves), "position": game.position, "turn": service.turn_of(game),
        "legal": state.legal if active else [], "notation": list(state.notation), "check": state.check, "clocks": service.remaining_ms(game, at),
        "clock_running": service.clocks_running(game) and game.status == "active",
        "first_move_ms": max(0, int(((service.deadline(game) or at) - at).total_seconds() * 1000)) if not service.clocks_running(game) else None,
        "status": game.status, "winner": game.winner, "reason": game.reason, "draw_offer": game.draw_offer,
        "created_at": game.created_at.isoformat() if game.created_at else None,
    }


hub = Hub()
