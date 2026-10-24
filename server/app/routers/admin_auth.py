"""Login/password sign-in for the web admin panel. A successful login returns a session token that is sent as
X-Admin-Key like a permanent key; it lives 12 hours in Redis and dies on logout."""

from typing import Annotated, Any

from fastapi import APIRouter, Header, Request, status
from pydantic import BaseModel, StringConstraints
from sqlalchemy import select

from app.deps import ADMIN_SESSION_PREFIX, DbDep, client_ip, get_redis
from app.errors import too_many, unauthorized
from app.models import AdminUser
from app.security import new_secret, sha256_hex, verify_password
from app.services.audit import audit

router = APIRouter(prefix="/v1/admin", tags=["admin"])

SESSION_SECONDS = 12 * 3600
LOGIN_ATTEMPTS_PER_WINDOW = 10
LOGIN_WINDOW_SECONDS = 900


class LoginIn(BaseModel):
    login: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=64)]
    password: Annotated[str, StringConstraints(min_length=1, max_length=128)]


def login_candidates(login: str) -> list[str]:
    """The login as typed, plus phone-number spellings of it: +998 94 939 22 50, 998949392250 and 949392250 all match."""
    digits = "".join(ch for ch in login if ch.isdigit())
    candidates = {login}
    if digits and len(digits) >= 9 and len(digits) == len(login.replace("+", "").replace(" ", "").replace("-", "").replace("(", "").replace(")", "")):
        candidates |= {digits, digits[-9:], f"998{digits[-9:]}"}
    return sorted(candidates)


async def _check_not_locked(keys: list[str]) -> None:
    redis = get_redis()
    for key in keys:
        if int(await redis.get(key) or 0) >= LOGIN_ATTEMPTS_PER_WINDOW:
            raise too_many(max(await redis.ttl(key), 1))


async def _count_failure(keys: list[str]) -> None:
    redis = get_redis()
    for key in keys:
        if await redis.incr(key) == 1:
            await redis.expire(key, LOGIN_WINDOW_SECONDS)


@router.post("/login")
async def login(body: LoginIn, request: Request, db: DbDep) -> dict[str, Any]:
    # Only wrong attempts count, per address and per login, so neither one attacker nor many can grind a password.
    keys = [f"adminlogin:ip:{client_ip(request)}", f"adminlogin:user:{body.login.lower()}"]
    await _check_not_locked(keys)
    admin = await db.scalar(select(AdminUser).where(AdminUser.login.in_(login_candidates(body.login))))
    if admin is None or not admin.active or not verify_password(body.password, admin.password_hash):
        await _count_failure(keys)
        raise unauthorized("LOGIN_INVALID")
    token = new_secret(32)
    await get_redis().set(f"{ADMIN_SESSION_PREFIX}{sha256_hex(token)}", str(admin.id), ex=SESSION_SECONDS)
    audit(db, f"admin:{admin.name}", "admin_login", admin.name, ip=client_ip(request))
    await db.commit()
    return {"token": token, "name": admin.name, "role": admin.role.value, "expires_in": SESSION_SECONDS}


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(x_admin_key: Annotated[str | None, Header()] = None) -> None:
    if x_admin_key:
        await get_redis().delete(f"{ADMIN_SESSION_PREFIX}{sha256_hex(x_admin_key)}")
