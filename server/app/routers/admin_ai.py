"""Admin side of UZARO AI: the provider key (write-only, stored encrypted), model, daily limit, on/off, a test call,
and usage numbers."""

from datetime import UTC, datetime, timedelta
from typing import Annotated, Any

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field, StringConstraints
from sqlalchemy import func, select

from app.ai import service
from app.ai.models import AiChat, AiMessage
from app.deps import DbDep, require_admin
from app.errors import ApiError
from app.models import AdminRole, AdminUser
from app.services.audit import audit

router = APIRouter(prefix="/v1/admin/ai", tags=["admin"])

Viewer = Annotated[AdminUser, Depends(require_admin(AdminRole.VIEWER))]
Owner = Annotated[AdminUser, Depends(require_admin(AdminRole.OWNER))]


async def _out(db: DbDep, admin: AdminUser) -> dict[str, Any]:
    config = await service.load(db)
    day = datetime.now(UTC) - timedelta(days=1)
    asked = await db.scalar(select(func.count()).select_from(AiMessage).where(AiMessage.role == "user", AiMessage.created_at >= day)) or 0
    people = await db.scalar(select(func.count(func.distinct(AiChat.customer_id))).where(AiChat.updated_at >= day)) or 0
    return {
        "key_set": bool(config.key),
        "key_hint": f"…{config.key[-4:]}" if config.key and admin.role == AdminRole.OWNER else "",
        "model": config.model, "daily_limit": config.daily_limit, "enabled": config.enabled,
        "stats": {"questions_24h": asked, "people_24h": people,
                  "chats": await db.scalar(select(func.count()).select_from(AiChat)) or 0},
    }


@router.get("")
async def get_ai(admin: Viewer, db: DbDep) -> dict[str, Any]:
    return await _out(db, admin)


_KEY_CHARS = r"^[A-Za-z0-9._\-]+$"  # newer provider keys look like "AQ.Ab8..."


class AiIn(BaseModel):
    api_key: Annotated[str, StringConstraints(strip_whitespace=True, min_length=20, max_length=400, pattern=_KEY_CHARS)] | None = None
    model: Annotated[str, StringConstraints(strip_whitespace=True, min_length=3, max_length=64, pattern=r"^[a-z0-9.\-]+$")] | None = None
    daily_limit: Annotated[int, Field(ge=1, le=10_000)] | None = None
    enabled: bool | None = None


@router.put("")
async def update_ai(body: AiIn, admin: Owner, db: DbDep) -> dict[str, Any]:
    if body.api_key is not None:
        await service.save(db, admin.name, service.KEY_SETTING, service.seal(body.api_key))
    if body.model is not None:
        await service.save(db, admin.name, service.MODEL_SETTING, body.model)
    if body.daily_limit is not None:
        await service.save(db, admin.name, service.LIMIT_SETTING, str(body.daily_limit))
    if body.enabled is not None:
        await service.save(db, admin.name, service.ENABLED_SETTING, "1" if body.enabled else "0")
    # The key itself is never logged, only that it changed.
    audit(db, f"admin:{admin.name}", "ai_settings_updated", "ai", key_changed=body.api_key is not None,
          model=body.model, daily_limit=body.daily_limit, enabled=body.enabled)
    await db.commit()
    return await _out(db, admin)


@router.post("/test")
async def test_ai(admin: Owner, db: DbDep) -> dict[str, Any]:
    """One short question with the saved settings, to check the key and model work."""
    config = await service.load(db)
    if not config.key:
        raise ApiError(400, "AI_NOT_CONFIGURED")
    try:
        reply = "".join([p async for p in service.stream_reply(service.AiConfig(config.key, config.model, 1, True),
                                                                [("user", "Kimsan? Bir jumlada javob ber.")])])
    except service.AiError as exc:
        raise ApiError(502, exc.code) from exc
    return {"reply": reply.strip()[:500]}
