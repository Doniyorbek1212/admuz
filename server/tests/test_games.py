"""Online games end to end through the hub (fake sockets) and the REST API: quick play, moves, clocks,
ratings, friend challenges, and an arena tournament from creation to prizes on the balance."""

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select, update

from app.games.hub import Hub
from app.games.models import Game, Tournament
from app.models import TelegramLink
from tests.test_gifts import _admin

pytestmark = pytest.mark.asyncio(loop_scope="session")


class FakeSocket:
    def __init__(self) -> None:
        self.sent: list[dict] = []

    async def send_json(self, data: dict) -> None:
        self.sent.append(data)

    def last(self, kind: str) -> dict:
        return next(m for m in reversed(self.sent) if m["t"] == kind)


async def _player(new_customer, session_factory, hub: Hub, telegram_id: int):
    customer = await new_customer()
    async with session_factory() as db:
        db.add(TelegramLink(customer_id=uuid.UUID(customer.id), telegram_user_id=telegram_id))
        await db.commit()
    socket = FakeSocket()
    hub.connect(uuid.UUID(customer.id), socket)
    return customer, uuid.UUID(customer.id), socket


async def _start(new_customer, session_factory, kind: str = "chess", telegram_id: int = 9001):
    hub = Hub()
    a, a_id, a_sock = await _player(new_customer, session_factory, hub, telegram_id)
    b, b_id, b_sock = await _player(new_customer, session_factory, hub, telegram_id + 1)
    for cid, name in ((a_id, "Ali"), (b_id, "Vali")):
        await hub.handle(cid, {"t": "seek", "kind": kind, "initial": 180, "increment": 2, "name": name})
    game = a_sock.last("game")["game"]
    white = a_id if game["white"]["id"] == str(a_id) else b_id
    black = b_id if white == a_id else a_id
    return hub, game["id"], white, black, (a, a_sock), (b, b_sock)


async def test_quick_play_pairs_two_seekers_and_plays_to_mate(new_customer, session_factory):
    hub, game_id, white, black, (a, a_sock), (b, b_sock) = await _start(new_customer, session_factory)
    first = a_sock.last("game")["game"]
    assert first["status"] == "active" and first["turn"] == "white" and len(first["legal"]) == 20 and not first["clock_running"]
    assert {first["white"]["name"], first["black"]["name"]} == {"Ali", "Vali"}

    await hub.handle(black, {"t": "move", "game": game_id, "move": "e7e5"})
    assert (a_sock.last("error") if white != uuid.UUID(a.id) else b_sock.last("error"))["code"] == "NOT_YOUR_TURN"
    for side, move in ((white, "f2f3"), (black, "e7e5"), (white, "g2g4"), (black, "d8h4")):
        await hub.handle(side, {"t": "move", "game": game_id, "move": move})
    over = a_sock.last("game")["game"]
    assert over["status"] == "finished" and over["winner"] == "black" and over["reason"] == "checkmate"
    assert over["black"]["delta"] > 0 > over["white"]["delta"]
    assert over["notation"] == ["f3", "e5", "g4", "Qh4#"] and over["check"] and over["legal"] == []

    board = (await a.get("/v1/games/leaderboard", params={"kind": "chess", "speed": "blitz"})).json()
    assert [row["rank"] for row in board["items"]] == [1, 2] and board["items"][0]["wins"] == 1
    history = (await b.get("/v1/games/history")).json()["items"]
    assert history[0]["moves"] == ["f2f3", "e7e5", "g2g4", "d8h4"]


async def test_illegal_moves_are_refused_and_checkers_works(new_customer, session_factory):
    hub, game_id, white, _black, (a, a_sock), (b, b_sock) = await _start(new_customer, session_factory, "checkers")
    sock = a_sock if white == uuid.UUID(a.id) else b_sock
    await hub.handle(white, {"t": "move", "game": game_id, "move": "c3-c4"})
    assert sock.last("error")["code"] == "ILLEGAL_MOVE"
    await hub.handle(white, {"t": "move", "game": game_id, "move": "c3-d4"})
    state = sock.last("game")["game"]
    assert state["moves"] == ["c3-d4"] and state["turn"] == "black"


async def test_unlinked_players_cannot_seek(new_customer):
    hub = Hub()
    customer = await new_customer()
    socket = FakeSocket()
    hub.connect(uuid.UUID(customer.id), socket)
    await hub.handle(uuid.UUID(customer.id), {"t": "seek", "kind": "chess", "initial": 180, "increment": 2})
    assert socket.last("error")["code"] == "TELEGRAM_NOT_LINKED"


async def test_running_out_of_time_loses_and_an_unstarted_game_aborts(new_customer, session_factory):
    hub, game_id, white, black, (a, a_sock), _ = await _start(new_customer, session_factory)
    async with session_factory() as db:
        await db.execute(update(Game).where(Game.id == uuid.UUID(game_id)).values(turn_started_at=datetime.now(UTC) - timedelta(seconds=40)))
        await db.commit()
    await hub.tick()
    assert a_sock.last("game")["game"]["status"] == "aborted"

    hub, game_id, white, black, (a, a_sock), _ = await _start(new_customer, session_factory, telegram_id=9201)
    for side, move in ((white, "e2e4"), (black, "e7e5")):
        await hub.handle(side, {"t": "move", "game": game_id, "move": move})
    async with session_factory() as db:
        await db.execute(update(Game).where(Game.id == uuid.UUID(game_id)).values(turn_started_at=datetime.now(UTC) - timedelta(seconds=181)))
        await db.commit()
    await hub.tick()
    over = a_sock.last("game")["game"]
    assert over["status"] == "finished" and over["reason"] == "timeout" and over["winner"] == "black"


async def test_draw_offer_and_friend_challenge(new_customer, session_factory):
    hub, game_id, white, black, (a, a_sock), _ = await _start(new_customer, session_factory)
    for side, move in ((white, "e2e4"), (black, "e7e5")):
        await hub.handle(side, {"t": "move", "game": game_id, "move": move})
    await hub.handle(white, {"t": "draw", "game": game_id})
    assert a_sock.last("game")["game"]["draw_offer"] == "white"
    await hub.handle(black, {"t": "draw", "game": game_id})
    assert a_sock.last("game")["game"]["winner"] == "draw"

    # Ali (9001) challenges Vali (9002) by Telegram id; Vali accepts.
    challenger = uuid.UUID(a.id)
    other = black if challenger == white else white
    await hub.handle(challenger, {"t": "challenge", "telegram_user_id": 9002 if challenger != other else 9001,
                                  "kind": "checkers", "initial": 300, "increment": 3})
    offers = [s for s in hub.sockets[other]][0]
    offer = offers.last("challenge")
    await hub.handle(other, {"t": "accept", "id": offer["id"]})
    assert a_sock.last("game")["game"]["kind"] == "checkers"


async def test_arena_tournament_pairs_scores_places_and_pays(client, new_customer, session_factory):
    admin = await _admin(session_factory, role=__import__("app.models", fromlist=["AdminRole"]).AdminRole.FINANCE)
    starts = datetime.now(UTC) + timedelta(minutes=5)
    created = await client.post("/v1/admin/games/tournaments", headers=admin, json={
        "kind": "chess", "title": "Shanba arenasi", "initial": 180, "increment": 2, "starts_at": starts.isoformat(),
        "duration_minutes": 30, "prize_uzs": 1_000_000, "prize_split": [60, 40], "min_games": 1})
    assert created.status_code == 201, created.text
    tid = created.json()["id"]

    hub = Hub()
    a, a_id, a_sock = await _player(new_customer, session_factory, hub, 9101)
    b, b_id, b_sock = await _player(new_customer, session_factory, hub, 9102)
    for customer in (a, b):
        assert (await customer.post(f"/v1/games/tournaments/{tid}/join")).json() == {"joined": True}
    async with session_factory() as db:
        await db.execute(update(Tournament).where(Tournament.id == uuid.UUID(tid)).values(starts_at=datetime.now(UTC) - timedelta(minutes=1)))
        await db.commit()
    for cid in (a_id, b_id):
        await hub.handle(cid, {"t": "arena", "tournament": tid})
    await hub.run_tournaments()
    game = a_sock.last("game")["game"]
    assert game["tournament_id"] == tid
    white = uuid.UUID(game["white"]["id"])
    black = b_id if white == a_id else a_id
    # Ten plies (shorter arena games score nothing), ending in the fool's mate.
    plies = ["a2a3", "a7a6", "h2h3", "h7h6", "b1c3", "b8c6", "f2f3", "e7e5", "g2g4", "d8h4"]
    for side, move in zip([white, black] * 5, plies, strict=True):
        await hub.handle(side, {"t": "move", "game": game["id"], "move": move})

    detail = (await a.get(f"/v1/games/tournaments/{tid}")).json()
    assert detail["status"] == "running" and detail["standings"][0]["score"] == 2 and detail["prizes"] == [600_000, 400_000]

    async with session_factory() as db:
        await db.execute(update(Tournament).where(Tournament.id == uuid.UUID(tid)).values(ends_at=datetime.now(UTC) - timedelta(seconds=1)))
        await db.commit()
    await hub.run_tournaments()
    assert (await client.post(f"/v1/admin/games/tournaments/{tid}/pay", headers=admin)).json() == {"paid": 2, "total_uzs": 1_000_000}
    assert (await client.post(f"/v1/admin/games/tournaments/{tid}/pay", headers=admin)).status_code == 409
    winner = a if black == a_id else b
    assert (await winner.get("/v1/wallet")).json()["balance_uzs"] == 600_000
    async with session_factory() as db:
        assert (await db.scalar(select(Tournament.status).where(Tournament.id == uuid.UUID(tid)))) == "paid"
