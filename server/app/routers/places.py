"""The hub's "Region" directory: local services of a region or district, searchable, optionally nearest first."""

import math
import uuid
from typing import Annotated, Any

from fastapi import APIRouter, Query
from pydantic import StringConstraints
from sqlalchemy import ColumnElement, and_, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.deps import CustomerDep, DbDep
from app.errors import bad_request, not_found
from app.market import REGIONS, Region
from app.models import Place, PlaceCategory
from app.places_regions import DISTRICTS, is_district_of

router = APIRouter(prefix="/v1/places", tags=["places"])

Search = Annotated[str, StringConstraints(strip_whitespace=True, max_length=100)]


def place_out(place: Place, *, lat: float | None = None, lon: float | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {
        "id": str(place.id),
        "category": place.category.value,
        "region": place.region,
        "district": place.district,
        "name": place.name,
        "subcategory": place.subcategory,
        "description": place.description,
        "address": place.address,
        "landmark": place.landmark,
        "phones": list(place.phones or []),
        "telegram": place.telegram,
        "instagram": place.instagram,
        "website": place.website,
        "working_hours": place.working_hours,
        "is_24h": place.is_24h,
        "latitude": place.latitude,
        "longitude": place.longitude,
        "verified": place.verified,
        "source": "osm" if (place.source_ref or "").startswith("osm:") else "",
    }
    if lat is not None and lon is not None and place.latitude is not None and place.longitude is not None:
        out["distance_m"] = round(distance_m(lat, lon, place.latitude, place.longitude))
    return out


def distance_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance in metres (haversine)."""
    r = 6_371_000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


async def districts_of(db: AsyncSession, region: str) -> list[str]:
    """The region's known districts plus any new ones the OpenStreetMap import brought in."""
    static = list(DISTRICTS.get(region, ()))
    found = await db.scalars(select(Place.district).where(Place.region == region, Place.district.is_not(None)).distinct())
    return static + sorted(d for d in found if d not in static)


async def _scope(db: AsyncSession, region: str, district: str) -> list[ColumnElement[bool]]:
    if district and not is_district_of(region, district) and district not in await districts_of(db, region):
        raise bad_request("UNKNOWN_DISTRICT")
    # A district view also lists region-wide entries (no district): a taxi service for the whole region.
    where = [Place.active.is_(True), Place.region == region]
    if district:
        where.append(or_(Place.district == district, Place.district.is_(None)))
    return where


def _search(q: str) -> ColumnElement[bool]:
    pattern = f"%{q.replace('%', '').replace('_', '')}%"
    return or_(Place.name.ilike(pattern), Place.subcategory.ilike(pattern), Place.address.ilike(pattern), Place.district.ilike(pattern))


@router.get("/regions")
async def regions(current: CustomerDep, db: DbDep) -> list[dict[str, Any]]:
    return [{"name": name, "districts": await districts_of(db, name)} for name in REGIONS]


@router.get("/summary")
async def summary(current: CustomerDep, db: DbDep, region: Region, district: Search = "") -> dict[str, Any]:
    rows = await db.execute(select(Place.category, func.count()).where(*await _scope(db, region, district)).group_by(Place.category))
    counts = {category.value: n for category, n in rows.all()}
    return {"counts": counts, "total": sum(counts.values())}


@router.get("")
async def list_places(
    current: CustomerDep,
    db: DbDep,
    region: Region,
    district: Search = "",
    category: PlaceCategory | None = None,
    q: Search = "",
    lat: Annotated[float | None, Query(ge=-90, le=90)] = None,
    lon: Annotated[float | None, Query(ge=-180, le=180)] = None,
    offset: Annotated[int, Query(ge=0, le=10_000)] = 0,
    limit: Annotated[int, Query(ge=1, le=50)] = 20,
) -> dict[str, Any]:
    where = await _scope(db, region, district)
    if category is not None:
        where.append(Place.category == category)
    if q:
        where.append(_search(q))
    stmt = select(Place).where(and_(*where))
    if lat is not None and lon is not None:
        # Nearest first: equirectangular distance is enough to order by inside one region; places without
        # coordinates go last.
        k = math.cos(math.radians(lat))
        sq = func.pow(Place.latitude - lat, 2) + func.pow((Place.longitude - lon) * k, 2)
        stmt = stmt.order_by(Place.latitude.is_(None), sq, Place.name)
    else:
        stmt = stmt.order_by(Place.featured.desc(), Place.sort_order, Place.verified.desc(), Place.name)
    rows = list(await db.scalars(stmt.offset(offset).limit(limit + 1)))
    has_more = len(rows) > limit
    return {
        "items": [place_out(p, lat=lat, lon=lon) for p in rows[:limit]],
        "next_offset": offset + limit if has_more else None,
    }


@router.get("/{place_id}")
async def place_detail(place_id: uuid.UUID, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    place = await db.get(Place, place_id)
    if place is None or not place.active:
        raise not_found("PLACE_NOT_FOUND")
    return place_out(place)
