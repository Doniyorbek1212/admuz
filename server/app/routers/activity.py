"""Usage statistics: the app reports an event at most once per day per user; admins see distinct users per period."""

from datetime import date, datetime, timedelta
from enum import StrEnum
from typing import Annotated, Any

from fastapi import APIRouter, Depends, status
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert

from app.deps import CustomerDep, DbDep, rate_limit, require_admin
from app.models import ActivityDay, AdminRole, AdminUser
from app.routers.admin_panel import TASHKENT

router = APIRouter(tags=["activity"])

Viewer = Annotated[AdminUser, Depends(require_admin(AdminRole.VIEWER))]

# Calendar periods ending today: the last 1, 7, 30 and 365 days.
PERIODS = {"day": 1, "week": 7, "month": 30, "year": 365}
CHART_DAYS = 30


class ActivityEvent(StrEnum):
    APP_OPEN = "app_open"
    HUB_OPEN = "hub_open"
    MOVIES_OPEN = "movies_open"


class ActivityIn(BaseModel):
    event: ActivityEvent


def today() -> date:
    return datetime.now(TASHKENT).date()


@router.post("/v1/activity", status_code=status.HTTP_204_NO_CONTENT)
async def record(body: ActivityIn, current: CustomerDep, db: DbDep) -> None:
    await rate_limit(f"activity:{current.id}", limit=120, window_seconds=3600)
    await db.execute(insert(ActivityDay).values(day=today(), customer_id=current.id, event=body.event.value).on_conflict_do_nothing())
    await db.commit()


@router.get("/v1/admin/activity")
async def activity_stats(admin: Viewer, db: DbDep) -> dict[str, Any]:
    """Distinct users per event for today / 7 / 30 / 365 days, and a daily series for the last 30 days."""
    end = today()
    totals: dict[str, dict[str, int]] = {}
    for event in ActivityEvent:
        totals[event.value] = {}
        for name, days in PERIODS.items():
            totals[event.value][name] = await db.scalar(
                select(func.count(func.distinct(ActivityDay.customer_id))).where(ActivityDay.event == event.value, ActivityDay.day > end - timedelta(days=days))
            ) or 0
    rows = await db.execute(
        select(ActivityDay.day, ActivityDay.event, func.count())
        .where(ActivityDay.day > end - timedelta(days=CHART_DAYS))
        .group_by(ActivityDay.day, ActivityDay.event)
    )
    per_day: dict[date, dict[str, int]] = {}
    for day, event, n in rows.all():
        per_day.setdefault(day, {})[event] = n
    days = [end - timedelta(days=i) for i in range(CHART_DAYS - 1, -1, -1)]
    daily = [{"date": d.isoformat(), **{e.value: per_day.get(d, {}).get(e.value, 0) for e in ActivityEvent}} for d in days]
    return {"totals": totals, "daily": daily}
