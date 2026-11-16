"""Admin side of online games: arena tournaments (create, edit, cancel, standings, disqualify, pay the prizes to the
UZARO balance) and fair-play bans."""

import uuid
from datetime import UTC, datetime, timedelta
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field, StringConstraints, field_validator
from sqlalchemy import func, select

from app.deps import DbDep, require_admin
from app.errors import bad_request, conflict, not_found
from app.games import service
from app.games.models import Game, GamePlayer, Tournament, TournamentPlayer
from app.models import AdminRole, AdminUser
from app.routers.games import standings_out, tournament_out
from app.services import wallet
from app.services.audit import audit

router = APIRouter(prefix="/v1/admin/games", tags=["admin"])

Viewer = Annotated[AdminUser, Depends(require_admin(AdminRole.VIEWER))]
Support = Annotated[AdminUser, Depends(require_admin(AdminRole.SUPPORT))]
Finance = Annotated[AdminUser, Depends(require_admin(AdminRole.FINANCE))]


class TournamentIn(BaseModel):
    kind: Literal["chess", "checkers"]
    title: Annotated[str, StringConstraints(strip_whitespace=True, min_length=3, max_length=80)]
    description: Annotated[str, StringConstraints(strip_whitespace=True, max_length=1000)] = ""
    initial: int
    increment: int
    starts_at: datetime
    duration_minutes: Annotated[int, Field(ge=10, le=24 * 60)]
    prize_uzs: Annotated[int, Field(ge=0, le=100_000_000)] = 0
    prize_split: Annotated[list[Annotated[int, Field(ge=1, le=100)]], Field(max_length=20)] = []
    min_games: Annotated[int, Field(ge=1, le=50)] = 3

    @field_validator("prize_split")
    @classmethod
    def _split(cls, value: list[int]) -> list[int]:
        if sum(value) > 100:
            raise ValueError("prize_split adds up to more than 100%")
        return value

    @field_validator("prize_split", mode="after")
    @classmethod
    def _split_needed(cls, value: list[int], info: Any) -> list[int]:
        if info.data.get("prize_uzs") and not value:
            raise ValueError("a prize needs the places' split")
        return value


async def _tournament(db: DbDep, tournament_id: uuid.UUID) -> Tournament:
    t = await db.get(Tournament, tournament_id)
    if t is None:
        raise not_found("TOURNAMENT_NOT_FOUND")
    return t


def _apply(t: Tournament, body: TournamentIn) -> None:
    try:
        service.check_time_control(body.kind, body.initial, body.increment)
    except service.GameError as exc:
        raise bad_request(exc.code) from exc
    starts = body.starts_at if body.starts_at.tzinfo else body.starts_at.replace(tzinfo=UTC)
    t.kind, t.title, t.description = body.kind, body.title, body.description
    t.initial_s, t.increment_s = body.initial, body.increment
    t.starts_at, t.ends_at = starts, starts + timedelta(minutes=body.duration_minutes)
    t.prize_uzs, t.prize_split, t.min_games = body.prize_uzs, list(body.prize_split), body.min_games


@router.get("/tournaments")
async def list_tournaments(admin: Viewer, db: DbDep) -> dict[str, Any]:
    rows = list(await db.scalars(select(Tournament).order_by(Tournament.starts_at.desc()).limit(200)))
    counts = dict((await db.execute(select(TournamentPlayer.tournament_id, func.count()).group_by(TournamentPlayer.tournament_id))).all())
    active = await db.scalar(select(func.count()).select_from(Game).where(Game.status == "active")) or 0
    players = await db.scalar(select(func.count()).select_from(GamePlayer)) or 0
    day = datetime.now(UTC) - timedelta(days=1)
    today = await db.scalar(select(func.count()).select_from(Game).where(Game.created_at >= day, Game.status != "aborted")) or 0
    return {"items": [tournament_out(t, counts.get(t.id, 0)) for t in rows],
            "stats": {"active_games": active, "players": players, "games_24h": today},
            "time_controls": [{"initial": i, "increment": n, "speed": service.speed_of(i, n)} for i, n in service.TIME_CONTROLS]}


@router.post("/tournaments", status_code=201)
async def create_tournament(body: TournamentIn, admin: Support, db: DbDep) -> dict[str, Any]:
    t = Tournament(id=uuid.uuid4(), status="scheduled", created_by=admin.name)
    _apply(t, body)
    if t.ends_at <= datetime.now(UTC):
        raise bad_request("TOURNAMENT_IN_PAST")
    db.add(t)
    audit(db, f"admin:{admin.name}", "tournament_created", str(t.id), title=t.title, prize_uzs=t.prize_uzs)
    await db.commit()
    return tournament_out(t)


@router.put("/tournaments/{tournament_id}")
async def update_tournament(tournament_id: uuid.UUID, body: TournamentIn, admin: Support, db: DbDep) -> dict[str, Any]:
    t = await _tournament(db, tournament_id)
    if t.status != "scheduled":
        raise conflict("TOURNAMENT_STARTED")
    _apply(t, body)
    audit(db, f"admin:{admin.name}", "tournament_updated", str(t.id), prize_uzs=t.prize_uzs)
    await db.commit()
    return tournament_out(t)


@router.post("/tournaments/{tournament_id}/cancel")
async def cancel_tournament(tournament_id: uuid.UUID, admin: Support, db: DbDep) -> dict[str, Any]:
    t = await _tournament(db, tournament_id)
    if t.status not in ("scheduled", "running"):
        raise conflict("TOURNAMENT_OVER")
    t.status = "cancelled"
    audit(db, f"admin:{admin.name}", "tournament_cancelled", str(t.id))
    await db.commit()
    return tournament_out(t)


@router.get("/tournaments/{tournament_id}")
async def tournament_detail(tournament_id: uuid.UUID, admin: Viewer, db: DbDep) -> dict[str, Any]:
    t = await _tournament(db, tournament_id)
    standing = await standings_out(db, t, None)
    banned = {str(c) for c in await db.scalars(select(GamePlayer.customer_id).where(GamePlayer.banned.is_(True)))}
    standing = [r | {"banned": str(r["customer_id"]) in banned} for r in standing]
    return tournament_out(t, len(standing)) | {"standings": standing}


class DisqualifyIn(BaseModel):
    customer_id: uuid.UUID
    disqualified: bool = True


@router.post("/tournaments/{tournament_id}/disqualify")
async def disqualify(tournament_id: uuid.UUID, body: DisqualifyIn, admin: Support, db: DbDep) -> dict[str, Any]:
    t = await _tournament(db, tournament_id)
    if t.status == "paid":
        raise conflict("TOURNAMENT_PAID")
    entry = await db.get(TournamentPlayer, (tournament_id, body.customer_id))
    if entry is None:
        raise not_found("PLAYER_NOT_FOUND")
    entry.disqualified = body.disqualified
    if t.status == "finished":
        await service.place_players(db, t)
    audit(db, f"admin:{admin.name}", "tournament_disqualify", str(t.id), customer_id=str(body.customer_id), value=body.disqualified)
    await db.commit()
    return {"disqualified": entry.disqualified}


@router.post("/tournaments/{tournament_id}/pay")
async def pay_prizes(tournament_id: uuid.UUID, admin: Finance, db: DbDep) -> dict[str, Any]:
    """Credits each placed player's prize to their UZARO balance once (the ledger reference makes it idempotent)."""
    t = await db.get(Tournament, tournament_id, with_for_update=True)
    if t is None:
        raise not_found("TOURNAMENT_NOT_FOUND")
    if t.status != "finished":
        raise conflict("TOURNAMENT_NOT_FINISHED")
    winners = [p for p in await service.place_players(db, t) if p.prize_uzs > 0]
    for entry in winners:
        await wallet.record(db, entry.customer_id, entry.prize_uzs, "prize", f"tournament:{t.id}")
    t.status = "paid"
    total = sum(p.prize_uzs for p in winners)
    audit(db, f"admin:{admin.name}", "tournament_paid", str(t.id), winners=len(winners), total_uzs=total)
    await db.commit()
    return {"paid": len(winners), "total_uzs": total}


class BanIn(BaseModel):
    banned: bool = True


@router.post("/players/{customer_id}/ban")
async def ban_player(customer_id: uuid.UUID, body: BanIn, admin: Support, db: DbDep) -> dict[str, Any]:
    player = await db.get(GamePlayer, customer_id)
    if player is None:
        raise not_found("PLAYER_NOT_FOUND")
    player.banned = body.banned
    audit(db, f"admin:{admin.name}", "game_player_ban", str(customer_id), banned=body.banned)
    await db.commit()
    return {"banned": player.banned}
