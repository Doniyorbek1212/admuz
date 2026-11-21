"""UZARO AI for the app: chats with history, and answers streamed as Server-Sent Events.

POST /v1/ai/messages streams `data: {...}` lines: {"t":"chat","chat":{...}} first (so a new chat gets its id),
then {"t":"delta","text":"..."} pieces, then {"t":"done","message":{...}} or {"t":"error","code":"..."}.
"""

import json
import logging
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime
from typing import Annotated, Any

import anyio
from fastapi import APIRouter, Query
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, StringConstraints
from sqlalchemy import delete, select

from app.ai import service
from app.ai.models import AiChat, AiMessage
from app.db import SessionFactory
from app.deps import CustomerDep, DbDep, rate_limit
from app.errors import ApiError, not_found
from app.models import TelegramLink

router = APIRouter(prefix="/v1/ai", tags=["ai"])
log = logging.getLogger(__name__)
TITLE_CHARS = 60


def _chat_out(c: AiChat) -> dict[str, Any]:
    return {"id": str(c.id), "title": c.title, "updated_at": c.updated_at.isoformat() if c.updated_at else None}


def _message_out(m: AiMessage) -> dict[str, Any]:
    return {"id": m.id, "role": m.role, "text": m.text, "created_at": m.created_at.isoformat() if m.created_at else None}


async def _own_chat(db: DbDep, chat_id: uuid.UUID, customer_id: uuid.UUID) -> AiChat:
    chat = await db.get(AiChat, chat_id)
    if chat is None or chat.customer_id != customer_id:
        raise not_found("AI_CHAT_NOT_FOUND")
    return chat


@router.get("/status")
async def status(current: CustomerDep, db: DbDep) -> dict[str, Any]:
    config = await service.load(db)
    return {"available": config.ready, "daily_limit": config.daily_limit, "used_today": await service.used_today(current.id),
            "linked": await db.get(TelegramLink, current.id) is not None}


@router.get("/chats")
async def chats(current: CustomerDep, db: DbDep, limit: Annotated[int, Query(ge=1, le=200)] = 100) -> dict[str, Any]:
    rows = await db.scalars(select(AiChat).where(AiChat.customer_id == current.id).order_by(AiChat.updated_at.desc()).limit(limit))
    return {"items": [_chat_out(c) for c in rows]}


@router.get("/chats/{chat_id}")
async def chat_detail(chat_id: uuid.UUID, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    chat = await _own_chat(db, chat_id, current.id)
    messages = await db.scalars(select(AiMessage).where(AiMessage.chat_id == chat.id).order_by(AiMessage.id))
    return _chat_out(chat) | {"messages": [_message_out(m) for m in messages]}


class RenameIn(BaseModel):
    title: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=80)]


@router.patch("/chats/{chat_id}")
async def rename_chat(chat_id: uuid.UUID, body: RenameIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    chat = await _own_chat(db, chat_id, current.id)
    chat.title = body.title
    await db.commit()
    return _chat_out(chat)


@router.delete("/chats/{chat_id}", status_code=204)
async def delete_chat(chat_id: uuid.UUID, current: CustomerDep, db: DbDep) -> None:
    chat = await _own_chat(db, chat_id, current.id)
    await db.delete(chat)
    await db.commit()


@router.delete("/chats", status_code=204)
async def delete_all_chats(current: CustomerDep, db: DbDep) -> None:
    await db.execute(delete(AiChat).where(AiChat.customer_id == current.id))
    await db.commit()


class AskIn(BaseModel):
    chat_id: uuid.UUID | None = None
    text: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=service.MAX_PROMPT_CHARS)]


def _event(payload: dict[str, Any]) -> str:
    return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"


@router.post("/messages")
async def ask(body: AskIn, current: CustomerDep, db: DbDep) -> StreamingResponse:
    await rate_limit(f"ai:{current.id}", limit=12, window_seconds=60)
    if await db.get(TelegramLink, current.id) is None:
        raise ApiError(403, "TELEGRAM_NOT_LINKED")
    config = await service.load(db)
    if not config.ready:
        raise ApiError(503, "AI_NOT_CONFIGURED")
    existing = None if body.chat_id is None else await _own_chat(db, body.chat_id, current.id)
    try:
        await service.take_one(current.id, config.daily_limit)
    except service.AiError as exc:
        raise ApiError(429, exc.code) from exc
    if existing is None:
        title = " ".join(body.text.split())
        chat = AiChat(id=uuid.uuid4(), customer_id=current.id, title=title[:TITLE_CHARS] + ("…" if len(title) > TITLE_CHARS else ""))
        db.add(chat)
    else:
        chat = existing
    chat.updated_at = datetime.now(UTC)
    db.add(AiMessage(chat_id=chat.id, role="user", text=body.text))
    await db.flush()
    recent = await db.scalars(
        select(AiMessage).where(AiMessage.chat_id == chat.id).order_by(AiMessage.id.desc()).limit(service.HISTORY_MESSAGES)
    )
    history = [(m.role, m.text) for m in reversed(list(recent))]
    chat_json = _chat_out(chat)
    await db.commit()
    chat_id, customer_id = chat.id, current.id

    async def save_reply(text: str) -> AiMessage | None:
        if not text:
            return None
        try:
            async with SessionFactory() as session:
                saved = AiMessage(chat_id=chat_id, role="model", text=text)
                session.add(saved)
                await session.commit()
                return saved
        except Exception:  # the chat was deleted meanwhile, or the DB is down: the answer was already streamed
            log.exception("ai reply not saved")
            return None

    async def events() -> AsyncIterator[str]:
        yield _event({"t": "chat", "chat": chat_json})
        parts: list[str] = []
        error: str | None = None
        saved: AiMessage | None = None
        try:
            async for piece in service.stream_reply(config, history):
                parts.append(piece)
                yield _event({"t": "delta", "text": piece})
        except service.AiError as exc:
            error = exc.code
        except Exception:
            log.exception("ai stream failed")
            error = "AI_UNAVAILABLE"
        finally:
            # Saved even when the app goes away mid-answer (the shield keeps the save alive through the cancel).
            with anyio.CancelScope(shield=True):
                saved = await save_reply("".join(parts).strip())
                if not parts:
                    await service.give_back(customer_id)  # nothing was answered, so the daily slot is not spent
            if saved is None and error is None:
                error = "AI_EMPTY"
        if error:
            yield _event({"t": "error", "code": error})
        elif saved is not None:
            yield _event({"t": "done", "message": _message_out(saved)})

    return StreamingResponse(events(), media_type="text/event-stream", headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})
