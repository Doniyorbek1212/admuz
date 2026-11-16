"""Game logic on the database: players, clocks, moves, results, ratings and arena tournament scoring.

Clocks: each side's first move is free (only the abort timer runs); after that the mover's clock runs from
[Game.turn_started_at] and gets the increment back after moving. A flag is checked on every move and by the
hub's ticker.
"""

import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.games import rating as glicko
from app.games.models import KINDS, Game, GamePlayer, GameRating, Tournament, TournamentPlayer
from app.games.rules import Analysis, analyse
from app.models import TelegramLink

# (initial seconds, increment) offered in quick play; tournaments may use any of them.
TIME_CONTROLS = ((60, 0), (120, 1), (180, 0), (180, 2), (300, 0), (300, 3), (600, 0), (600, 5), (900, 10))
FIRST_MOVE_SECONDS = 30  # a game nobody starts is aborted, no rating change
WIN_POINTS, DRAW_POINTS = 2, 1
STREAK_FOR_DOUBLE = 2  # after two wins in a row, the next wins (and draws) count double
ARENA_MIN_PLIES = 10  # an arena game shorter than 5 moves each scores no points
ARENA_MIN_DRAW_PLIES = 40  # an agreed draw scores only after 20 moves each


class GameError(Exception):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def speed_of(initial_s: int, increment_s: int) -> str:
    estimate = initial_s + 40 * increment_s
    return "bullet" if estimate < 180 else "blitz" if estimate < 480 else "rapid"


def check_time_control(kind: str, initial_s: int, increment_s: int) -> None:
    if kind not in KINDS:
        raise GameError("GAME_KIND_UNKNOWN")
    if (initial_s, increment_s) not in TIME_CONTROLS:
        raise GameError("TIME_CONTROL_UNKNOWN")


def now() -> datetime:
    return datetime.now(UTC)


# ---- players ----


async def player(db: AsyncSession, customer_id: uuid.UUID, name: str = "") -> GamePlayer:
    """The customer's game profile; only a proven Telegram account plays (one person, one rating)."""
    row = await db.get(GamePlayer, customer_id)
    link = await db.get(TelegramLink, customer_id)
    if link is None:
        raise GameError("TELEGRAM_NOT_LINKED")
    clean = " ".join(name.split())[:32]
    if row is None:
        row = GamePlayer(customer_id=customer_id, name=clean or "O'yinchi", telegram_user_id=link.telegram_user_id)
        db.add(row)
        await db.flush()
    elif row.telegram_user_id != link.telegram_user_id:
        row.telegram_user_id = link.telegram_user_id
    return row


async def rating(db: AsyncSession, customer_id: uuid.UUID, kind: str, speed: str, lock: bool = False) -> GameRating:
    # lock: a player can finish two games at once; the row lock keeps both rating updates.
    row = await db.get(GameRating, (customer_id, kind, speed), with_for_update=lock)
    if row is None:
        row = GameRating(customer_id=customer_id, kind=kind, speed=speed, rating=glicko.START_RATING,
                         deviation=glicko.START_DEVIATION, volatility=glicko.START_VOLATILITY,
                         games=0, wins=0, losses=0, draws=0, best=glicko.START_RATING)
        db.add(row)
    return row


def _glicko(row: GameRating, at: datetime) -> glicko.Glicko:
    idle = (at - row.updated_at).total_seconds() / 86400 if row.updated_at and row.games else 0
    return glicko.with_idle_days(glicko.Glicko(row.rating, row.deviation, row.volatility), idle)


# ---- games ----


async def create_game(db: AsyncSession, white: uuid.UUID, black: uuid.UUID, kind: str, initial_s: int, increment_s: int,
                      rated: bool, tournament_id: uuid.UUID | None = None) -> Game:
    speed = speed_of(initial_s, increment_s)
    white_rating, black_rating = await rating(db, white, kind, speed), await rating(db, black, kind, speed)
    game = Game(
        id=uuid.uuid4(), kind=kind, speed=speed, initial_s=initial_s, increment_s=increment_s, rated=rated,
        white_id=white, black_id=black, tournament_id=tournament_id, moves=[], position=analyse(kind, []).position,
        white_ms=initial_s * 1000, black_ms=initial_s * 1000, turn_started_at=now(), status="active",
        winner="", reason="", draw_offer="", white_rating=round(white_rating.rating), black_rating=round(black_rating.rating),
        white_delta=0, black_delta=0,
    )
    db.add(game)
    await db.flush()
    return game


def side_of(game: Game, customer_id: uuid.UUID) -> str:
    if customer_id == game.white_id:
        return "white"
    if customer_id == game.black_id:
        return "black"
    raise GameError("NOT_YOUR_GAME")


def turn_of(game: Game) -> str:
    return "white" if len(game.moves) % 2 == 0 else "black"


def clocks_running(game: Game) -> bool:
    return len(game.moves) >= 2


def remaining_ms(game: Game, at: datetime) -> dict[str, int]:
    """Both clocks as of [at] (the mover's is running)."""
    clocks = {"white": game.white_ms, "black": game.black_ms}
    if game.status == "active" and clocks_running(game):
        mover = turn_of(game)
        clocks[mover] = max(0, clocks[mover] - int((at - game.turn_started_at).total_seconds() * 1000))
    return clocks


def deadline(game: Game) -> datetime | None:
    """When the side to move loses on time (or the game is aborted before the first moves)."""
    if game.status != "active":
        return None
    if not clocks_running(game):
        return game.turn_started_at + timedelta(seconds=FIRST_MOVE_SECONDS)
    left = game.white_ms if turn_of(game) == "white" else game.black_ms
    return game.turn_started_at + timedelta(milliseconds=left)


async def play(db: AsyncSession, game: Game, customer_id: uuid.UUID, move: str) -> Analysis:
    if game.status != "active":
        raise GameError("GAME_OVER")
    side = side_of(game, customer_id)
    if side != turn_of(game):
        raise GameError("NOT_YOUR_TURN")
    at = now()
    if await flag_if_due(db, game, at):
        raise GameError("TIME_OUT")
    before = analyse(game.kind, list(game.moves))
    if move not in before.legal:
        raise GameError("ILLEGAL_MOVE")
    if clocks_running(game):
        left = remaining_ms(game, at)[side] + game.increment_s * 1000
        if side == "white":
            game.white_ms = left
        else:
            game.black_ms = left
    game.moves = [*game.moves, move]
    game.turn_started_at = at
    if game.draw_offer and game.draw_offer != side:
        game.draw_offer = ""  # moving instead of answering declines the offer
    after = analyse(game.kind, game.moves)
    game.position = after.position
    if after.outcome is not None:
        await finish(db, game, after.outcome.winner, after.outcome.reason)
    return after


async def flag_if_due(db: AsyncSession, game: Game, at: datetime) -> bool:
    """Ends the game when the side to move has run out of time (or nobody started it); True when it ended."""
    due = deadline(game)
    if due is None or at < due:
        return False
    if not clocks_running(game):
        await finish(db, game, "", "aborted")
        return True
    loser = turn_of(game)
    if loser == "white":
        game.white_ms = 0
    else:
        game.black_ms = 0
    # Russian/FIDE practice simplified: the side with time left wins on time.
    await finish(db, game, "black" if loser == "white" else "white", "timeout")
    return True


async def resign(db: AsyncSession, game: Game, customer_id: uuid.UUID) -> None:
    if game.status != "active":
        raise GameError("GAME_OVER")
    side = side_of(game, customer_id)
    if not clocks_running(game):
        await finish(db, game, "", "aborted")
        return
    await finish(db, game, "black" if side == "white" else "white", "resign")


async def offer_draw(db: AsyncSession, game: Game, customer_id: uuid.UUID) -> bool:
    """Offers a draw, or accepts the opponent's standing offer; True when the game ended drawn."""
    if game.status != "active":
        raise GameError("GAME_OVER")
    side = side_of(game, customer_id)
    if len(game.moves) < 2:
        raise GameError("TOO_EARLY")
    if game.draw_offer and game.draw_offer != side:
        await finish(db, game, "draw", "agreement")
        return True
    game.draw_offer = side
    return False


def decline_draw(game: Game, customer_id: uuid.UUID) -> None:
    if game.draw_offer and game.draw_offer != side_of(game, customer_id):
        game.draw_offer = ""


async def finish(db: AsyncSession, game: Game, winner: str, reason: str) -> None:
    at = now()
    game.ended_at = at
    game.draw_offer = ""
    game.reason = reason
    if reason == "aborted":
        game.status, game.winner = "aborted", ""
        return
    if reason != "timeout":  # a flag already set the loser's clock to 0
        clocks = remaining_ms(game, at)
        game.white_ms, game.black_ms = clocks["white"], clocks["black"]
    game.status, game.winner = "finished", winner
    if game.rated:
        await _rate(db, game, at)
    if game.tournament_id is not None:
        await _score(db, game)


async def _rate(db: AsyncSession, game: Game, at: datetime) -> None:
    # Locked in customer-id order so two games between the same pair cannot deadlock.
    first, second = sorted((game.white_id, game.black_id))
    rows = {cid: await rating(db, cid, game.kind, game.speed, lock=True) for cid in (first, second)}
    white_row, black_row = rows[game.white_id], rows[game.black_id]
    white, black = _glicko(white_row, at), _glicko(black_row, at)
    score = {"white": 1.0, "black": 0.0, "draw": 0.5}[game.winner]
    for row, me, them, mine in ((white_row, white, black, score), (black_row, black, white, 1 - score)):
        new = glicko.update(me, them, mine)
        delta = round(new.rating) - round(me.rating)
        if row is white_row:
            game.white_delta = delta
        else:
            game.black_delta = delta
        row.rating, row.deviation, row.volatility = new.rating, new.deviation, new.volatility
        row.games += 1
        row.wins += mine == 1.0
        row.losses += mine == 0.0
        row.draws += mine == 0.5
        row.best = max(row.best, new.rating)
        row.updated_at = at


def scores_points(game: Game) -> bool:
    """Whether an arena game counts: very short games score nothing, so two accounts cannot trade quick
    resignations or agreed draws for prize points."""
    plies = len(game.moves)
    if game.winner == "draw" and game.reason == "agreement":
        return plies >= ARENA_MIN_DRAW_PLIES
    return plies >= ARENA_MIN_PLIES


async def _score(db: AsyncSession, game: Game) -> None:
    if not scores_points(game):
        return
    for customer_id, side, opponent in ((game.white_id, "white", game.black_id), (game.black_id, "black", game.white_id)):
        entry = await db.get(TournamentPlayer, (game.tournament_id, customer_id))
        if entry is None:
            continue
        doubled = entry.streak >= STREAK_FOR_DOUBLE
        entry.games += 1
        entry.last_opponent = opponent
        if game.winner == side:
            entry.wins += 1
            entry.score += WIN_POINTS * (2 if doubled else 1)
            entry.streak += 1
        else:
            entry.score += (DRAW_POINTS * (2 if doubled else 1)) if game.winner == "draw" else 0
            entry.streak = 0
        entry.rating = (game.white_rating if side == "white" else game.black_rating) + (
            game.white_delta if side == "white" else game.black_delta)


# ---- tournaments ----


def pair_arena(waiting: list[TournamentPlayer]) -> list[tuple[uuid.UUID, uuid.UUID]]:
    """Pairs waiting players with the nearest in score (then rating), avoiding an instant rematch when possible."""
    pool = sorted(waiting, key=lambda p: (-p.score, -p.rating))
    pairs: list[tuple[uuid.UUID, uuid.UUID]] = []
    while len(pool) >= 2:
        first = pool.pop(0)
        pick = next((i for i, p in enumerate(pool) if p.customer_id != first.last_opponent), 0)
        second = pool.pop(pick)
        # Colours alternate down the list so the leaders do not always get white.
        pairs.append((first.customer_id, second.customer_id) if len(pairs) % 2 == 0 else (second.customer_id, first.customer_id))
    return pairs


async def standings(db: AsyncSession, tournament: Tournament) -> list[TournamentPlayer]:
    rows = await db.scalars(select(TournamentPlayer).where(TournamentPlayer.tournament_id == tournament.id))
    return sorted(rows, key=lambda p: (p.disqualified, -p.score, -p.wins, -p.rating, p.joined_at))


async def place_players(db: AsyncSession, tournament: Tournament) -> list[TournamentPlayer]:
    """Final places and prizes: only players with at least [min_games] games and not disqualified get a place."""
    ranked = [p for p in await standings(db, tournament) if not p.disqualified and p.games >= tournament.min_games]
    split = list(tournament.prize_split or [])
    for row in await standings(db, tournament):
        row.place, row.prize_uzs = None, 0
    for index, row in enumerate(ranked):
        row.place = index + 1
        row.prize_uzs = tournament.prize_uzs * split[index] // 100 if index < len(split) else 0
    return ranked
