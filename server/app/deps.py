import uuid
from collections.abc import Callable, Coroutine
from dataclasses import dataclass
from typing import Annotated, Any

from fastapi import Depends, Header, Request
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_db
from app.errors import forbidden, too_many, unauthorized
from app.models import AdminRole, AdminUser, Customer, Device
from app.security import TokenError, decode_access_token, sha256_hex

_redis: Redis | None = None


def get_redis() -> Redis:
    global _redis
    if _redis is None:
        _redis = Redis.from_url(get_settings().redis_url, decode_responses=True)
    return _redis


DbDep = Annotated[AsyncSession, Depends(get_db)]


@dataclass(slots=True)
class CurrentCustomer:
    customer: Customer
    device_id: uuid.UUID

    @property
    def id(self) -> uuid.UUID:
        return self.customer.id


async def get_current_customer(request: Request, db: DbDep) -> CurrentCustomer:
    header = request.headers.get("authorization", "")
    if not header.lower().startswith("bearer "):
        raise unauthorized()
    try:
        customer_id, device_id = decode_access_token(header[7:].strip())
    except TokenError as exc:
        raise unauthorized("TOKEN_INVALID") from exc
    device = await db.get(Device, device_id)
    if device is None or device.revoked_at is not None or device.customer_id != customer_id:
        raise unauthorized("DEVICE_REVOKED")
    customer = await db.get(Customer, customer_id)
    if customer is None or customer.deleted_at is not None:
        raise unauthorized("CUSTOMER_DELETED")
    return CurrentCustomer(customer=customer, device_id=device_id)


CustomerDep = Annotated[CurrentCustomer, Depends(get_current_customer)]

_ROLE_RANK = {AdminRole.VIEWER: 0, AdminRole.SUPPORT: 1, AdminRole.FINANCE: 2, AdminRole.OWNER: 3}
ADMIN_FAILURES_PER_WINDOW = 20
ADMIN_SESSION_PREFIX = "adminsess:"


def require_admin(minimum: AdminRole) -> Callable[..., Coroutine[Any, Any, AdminUser]]:
    """Admin auth via X-Admin-Key (stored hashed). Roles are hierarchical."""

    async def dependency(request: Request, db: DbDep, x_admin_key: Annotated[str | None, Header()] = None) -> AdminUser:
        if not x_admin_key:
            raise unauthorized("ADMIN_KEY_REQUIRED")
        admin = None
        if get_settings().admin_permanent_keys:
            admin = await db.scalar(select(AdminUser).where(AdminUser.key_hash == sha256_hex(x_admin_key)))
        if admin is None:
            # Not a permanent key: maybe a session token from login/password (see admin_auth).
            session_admin = await get_redis().get(f"{ADMIN_SESSION_PREFIX}{sha256_hex(x_admin_key)}")
            if session_admin:
                admin = await db.get(AdminUser, uuid.UUID(session_admin))
        if admin is None or not admin.active:
            # The web panel makes key guessing cheap: cap wrong keys per address.
            await rate_limit(f"adminfail:{client_ip(request)}", limit=ADMIN_FAILURES_PER_WINDOW, window_seconds=900)
            raise unauthorized("ADMIN_KEY_INVALID")
        if _ROLE_RANK[admin.role] < _ROLE_RANK[minimum]:
            raise forbidden("ADMIN_ROLE_INSUFFICIENT")
        return admin

    return dependency


async def rate_limit(key: str, limit: int | None = None, window_seconds: int = 60) -> None:
    """Fixed-window limiter in Redis; fails closed for abuse-prone endpoints only if Redis answers."""
    redis = get_redis()
    limit = limit or get_settings().rate_limit_per_minute
    bucket = f"rl:{key}"
    count = await redis.incr(bucket)
    if count == 1:
        await redis.expire(bucket, window_seconds)
    if count > limit:
        ttl = await redis.ttl(bucket)
        raise too_many(max(ttl, 1))


async def revoke_admin_sessions(admin_id: uuid.UUID) -> int:
    """Ends every login session of one admin (password change, key revoke, deactivation)."""
    redis = get_redis()
    removed = 0
    async for key in redis.scan_iter(match=f"{ADMIN_SESSION_PREFIX}*", count=500):
        if await redis.get(key) == str(admin_id):
            removed += await redis.delete(key)
    return removed


def client_ip(request: Request) -> str:
    # X-Forwarded-For is client-controlled; uvicorn --proxy-headers rewrites request.client only for
    # proxies listed in --forwarded-allow-ips, so the peer address here cannot be spoofed.
    return request.client.host if request.client else "unknown"
