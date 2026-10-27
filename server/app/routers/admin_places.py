"""Admin editing of the "Region" directory: add, correct, hide or delete places. Every change is audited."""

import uuid
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Query, status
from pydantic import BaseModel, Field, StringConstraints, model_validator
from sqlalchemy import func, select

from app.deps import DbDep, require_admin
from app.errors import bad_request, not_found
from app.market import Region
from app.models import AdminRole, AdminUser, Place, PlaceCategory
from app.places_regions import is_district_of
from app.routers.places import place_out
from app.services.audit import audit

router = APIRouter(prefix="/v1/admin/places", tags=["admin"])

Viewer = Annotated[AdminUser, Depends(require_admin(AdminRole.VIEWER))]
Support = Annotated[AdminUser, Depends(require_admin(AdminRole.SUPPORT))]


def _text(max_length: int) -> Any:
    return Annotated[str, StringConstraints(strip_whitespace=True, max_length=max_length)]


class PlaceIn(BaseModel):
    category: PlaceCategory
    region: Region
    district: Annotated[str | None, StringConstraints(strip_whitespace=True, max_length=80)] = None
    name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]
    subcategory: _text(80) = ""
    description: _text(3000) = ""
    address: _text(300) = ""
    landmark: _text(200) = ""
    phones: Annotated[list[Annotated[str, StringConstraints(strip_whitespace=True, pattern=r"^\+?[0-9 ()-]{5,20}$")]], Field(max_length=6)] = []
    telegram: Annotated[str, StringConstraints(strip_whitespace=True, pattern=r"^([A-Za-z][A-Za-z0-9_]{3,31})?$")] = ""
    instagram: Annotated[str, StringConstraints(strip_whitespace=True, pattern=r"^([A-Za-z0-9._]{1,30})?$")] = ""
    website: Annotated[str, StringConstraints(strip_whitespace=True, max_length=300, pattern=r"^(https://[^\s<>\"']+)?$")] = ""
    working_hours: _text(200) = ""
    is_24h: bool = False
    latitude: Annotated[float | None, Field(ge=-90, le=90)] = None
    longitude: Annotated[float | None, Field(ge=-180, le=180)] = None
    verified: bool = False
    featured: bool = False
    active: bool = True
    sort_order: Annotated[int, Field(ge=-1000, le=1000)] = 0

    @model_validator(mode="after")
    def _district_in_region(self) -> "PlaceIn":
        if self.district == "":
            self.district = None
        if self.district and not is_district_of(self.region, self.district):
            raise ValueError("district does not belong to the region")
        return self


async def _place(db: DbDep, place_id: uuid.UUID) -> Place:
    place = await db.get(Place, place_id)
    if place is None:
        raise not_found("PLACE_NOT_FOUND")
    return place


@router.get("")
async def list_places(
    admin: Viewer,
    db: DbDep,
    region: str = "",
    category: PlaceCategory | None = None,
    q: Annotated[str, StringConstraints(strip_whitespace=True, max_length=100)] = "",
    active: bool | None = None,
    offset: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
) -> dict[str, Any]:
    stmt = select(Place)
    if region:
        stmt = stmt.where(Place.region == region)
    if category is not None:
        stmt = stmt.where(Place.category == category)
    if active is not None:
        stmt = stmt.where(Place.active.is_(active))
    if q:
        stmt = stmt.where(Place.name.ilike(f"%{q.replace('%', '').replace('_', '')}%"))
    total = await db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    rows = await db.scalars(stmt.order_by(Place.updated_at.desc()).offset(offset).limit(limit))
    return {"items": [place_out(p) | {"active": p.active, "featured": p.featured, "sort_order": p.sort_order} for p in rows], "total": total}


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_place(body: PlaceIn, admin: Support, db: DbDep) -> dict[str, Any]:
    place = Place(**body.model_dump())
    db.add(place)
    await db.flush()
    audit(db, admin.name, "place_created", str(place.id), name=place.name, category=place.category.value)
    await db.commit()
    await db.refresh(place)
    return place_out(place)


@router.put("/{place_id}")
async def update_place(place_id: uuid.UUID, body: PlaceIn, admin: Support, db: DbDep) -> dict[str, Any]:
    place = await _place(db, place_id)
    for field, value in body.model_dump().items():
        setattr(place, field, value)
    audit(db, admin.name, "place_updated", str(place.id), name=place.name)
    await db.commit()
    await db.refresh(place)
    return place_out(place)


@router.delete("/{place_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_place(place_id: uuid.UUID, admin: Support, db: DbDep) -> None:
    place = await _place(db, place_id)
    if place.source_ref:
        # A deleted import would come back on the next import run: hide it instead.
        raise bad_request("PLACE_IMPORTED_HIDE_INSTEAD")
    audit(db, admin.name, "place_deleted", str(place.id), name=place.name)
    await db.delete(place)
    await db.commit()
