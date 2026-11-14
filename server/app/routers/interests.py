"""Interest signals from the app (what the customer opens in the hub), the customer's right to wipe them,
and the admin view of what the audience is interested in."""

from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, status
from pydantic import BaseModel, Field
from sqlalchemy import func, select

from app.deps import CustomerDep, DbDep, rate_limit, require_admin
from app.models import AdCampaign, AdminRole, AdminUser, AdStatus, CustomerInterest
from app.services.interests import SIGNAL_WEIGHTS, TOPICS, ctr_percent, forget, record_signals
from app.services.market_settings import load_market_settings

router = APIRouter(tags=["interests"])

Viewer = Annotated[AdminUser, Depends(require_admin(AdminRole.VIEWER))]

MAX_SIGNALS_PER_REQUEST = 20
# A topic counts as one of a customer's interests in the admin overview from this (faded) score on.
INTERESTED_FROM = 1.0


class SignalIn(BaseModel):
    topic: Literal[TOPICS]  # type: ignore[valid-type]
    kind: Literal[tuple(SIGNAL_WEIGHTS)]  # type: ignore[valid-type]


class SignalsIn(BaseModel):
    signals: Annotated[list[SignalIn], Field(min_length=1, max_length=MAX_SIGNALS_PER_REQUEST)]


@router.post("/v1/interests", status_code=status.HTTP_204_NO_CONTENT)
async def add_signals(body: SignalsIn, current: CustomerDep, db: DbDep) -> None:
    await rate_limit(f"interests:{current.id}", limit=300, window_seconds=3600)
    settings = await load_market_settings(db)
    if not settings.ads_personalization:
        return
    await record_signals(db, current.id, [(s.topic, s.kind) for s in body.signals], settings.ads_interest_half_life_days)
    await db.commit()


@router.delete("/v1/interests", status_code=status.HTTP_204_NO_CONTENT)
async def clear_interests(current: CustomerDep, db: DbDep) -> None:
    """The customer turned personalised ads off: everything learnt about them is deleted."""
    await forget(db, current.id)
    await db.commit()


@router.get("/v1/admin/interests")
async def interests_overview(admin: Viewer, db: DbDep) -> dict[str, Any]:
    """Per topic: how many customers are interested, and how live ads on it perform. No per-person data."""
    half_life_s = max((await load_market_settings(db)).ads_interest_half_life_days, 1) * 86400
    faded = CustomerInterest.score * func.power(0.5, func.extract("epoch", func.now() - CustomerInterest.updated_at) / half_life_s)
    audience = dict(
        (await db.execute(
            select(CustomerInterest.topic, func.count()).where(faded >= INTERESTED_FROM).group_by(CustomerInterest.topic)
        )).all()
    )
    profiled = await db.scalar(select(func.count(func.distinct(CustomerInterest.customer_id))).where(faded >= INTERESTED_FROM)) or 0
    ads = await db.scalars(select(AdCampaign).where(AdCampaign.status == AdStatus.APPROVED))
    per_topic: dict[str, dict[str, int]] = {t: {"ads": 0, "views": 0, "clicks": 0} for t in TOPICS}
    for ad in ads:
        for topic in ad.topics or []:
            if topic in per_topic:
                per_topic[topic]["ads"] += 1
                per_topic[topic]["views"] += ad.views or 0
                per_topic[topic]["clicks"] += ad.clicks or 0
    topics = [
        {"topic": t, "users": int(audience.get(t, 0)), **per_topic[t], "ctr": ctr_percent(per_topic[t]["views"], per_topic[t]["clicks"])}
        for t in TOPICS
    ]
    topics.sort(key=lambda row: (-row["users"], TOPICS.index(row["topic"])))
    return {"profiled_users": int(profiled), "topics": topics}
