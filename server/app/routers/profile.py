"""Optional customer profile: the Telegram name, username and phone a user agreed to share with Sado
(shown to admins, e.g. to contact sellers and advertisers). Deleting it returns the account to anonymous."""

from typing import Annotated, Any

from fastapi import APIRouter, status
from pydantic import BaseModel, StringConstraints

from app.deps import CustomerDep, DbDep, rate_limit
from app.market import profile_out
from app.models import CustomerProfile

router = APIRouter(prefix="/v1/customers/me/profile", tags=["customers"])


class ProfileIn(BaseModel):
    first_name: Annotated[str, StringConstraints(strip_whitespace=True, max_length=64)] = ""
    last_name: Annotated[str, StringConstraints(strip_whitespace=True, max_length=64)] = ""
    username: Annotated[str, StringConstraints(strip_whitespace=True, pattern=r"^([A-Za-z][A-Za-z0-9_]{3,31})?$")] = ""
    phone: Annotated[str, StringConstraints(strip_whitespace=True, pattern=r"^(\+?[0-9]{7,15})?$")] = ""


@router.put("")
async def save_profile(body: ProfileIn, current: CustomerDep, db: DbDep) -> dict[str, Any] | None:
    await rate_limit(f"profile:{current.id}", limit=30, window_seconds=3600)
    profile = await db.get(CustomerProfile, current.id)
    if profile is None:
        profile = CustomerProfile(customer_id=current.id)
        db.add(profile)
    for field, value in body.model_dump().items():
        setattr(profile, field, value)
    await db.commit()
    return profile_out(profile)


@router.delete("", status_code=status.HTTP_204_NO_CONTENT)
async def delete_profile(current: CustomerDep, db: DbDep) -> None:
    profile = await db.get(CustomerProfile, current.id)
    if profile is not None:
        await db.delete(profile)
        await db.commit()
