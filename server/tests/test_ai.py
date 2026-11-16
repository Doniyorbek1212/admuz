"""UZARO AI: the owner saves the key (never shown back), linked users chat with history, answers stream as SSE,
provider names and errors never reach the app, and the daily limit holds."""

import json
import uuid

import httpx
import pytest
from sqlalchemy import select

from app.ai import service
from app.models import AdminRole, AppSetting, TelegramLink
from tests.test_gifts import _admin

pytestmark = pytest.mark.asyncio(loop_scope="session")
KEY = "AIzaSyFAKE-test-key_0123456789abcd"


def _provider(seen: list[dict], status: int = 200):
    def handle(request: httpx.Request) -> httpx.Response:
        seen.append({"key": request.headers.get("x-goog-api-key"), "url": str(request.url), "body": json.loads(request.content)})
        if status != 200:
            return httpx.Response(status, json={"error": {"message": "Gemini quota exceeded"}})
        chunks = [{"candidates": [{"content": {"parts": [{"text": "Salom! "}]}}]},
                  {"candidates": [{"content": {"parts": [{"text": "Men UZARO AI."}]}}]}]
        return httpx.Response(200, text="".join(f"data: {json.dumps(c)}\r\n\r\n" for c in chunks),
                              headers={"content-type": "text/event-stream"})
    return httpx.MockTransport(handle)


def _events(body: str) -> list[dict]:
    return [json.loads(line[5:]) for line in body.splitlines() if line.startswith("data:")]


async def _linked(new_customer, session_factory, telegram_id: int):
    customer = await new_customer()
    async with session_factory() as db:
        db.add(TelegramLink(customer_id=uuid.UUID(customer.id), telegram_user_id=telegram_id))
        await db.commit()
    return customer


async def test_owner_sets_key_users_chat_with_history_and_streaming(client, new_customer, session_factory, monkeypatch):
    owner = await _admin(session_factory, role=AdminRole.OWNER)
    support = await _admin(session_factory)
    assert (await client.put("/v1/admin/ai", headers=support, json={"api_key": KEY})).status_code == 403
    saved = (await client.put("/v1/admin/ai", headers=owner, json={"api_key": KEY, "daily_limit": 2})).json()
    assert saved["key_set"] and saved["key_hint"] == "…abcd" and KEY not in json.dumps(saved)
    async with session_factory() as db:
        stored = (await db.get(AppSetting, service.KEY_SETTING)).value
    assert KEY not in stored and service.unseal(stored) == KEY

    seen: list[dict] = []
    monkeypatch.setattr(service, "transport", _provider(seen))
    unlinked = await new_customer()
    assert (await unlinked.post("/v1/ai/messages", json={"text": "salom"})).json()["detail"]["code"] == "TELEGRAM_NOT_LINKED"

    user = await _linked(new_customer, session_factory, 7001)
    first = _events((await user.post("/v1/ai/messages", json={"text": "Salom, sen kimsan?"})).text)
    assert first[0]["t"] == "chat" and first[0]["chat"]["title"] == "Salom, sen kimsan?"
    assert "".join(e["text"] for e in first if e["t"] == "delta") == "Salom! Men UZARO AI."
    assert first[-1]["t"] == "done" and first[-1]["message"]["role"] == "model"
    assert seen[0]["key"] == KEY and "UZARO AI" in seen[0]["body"]["systemInstruction"]["parts"][0]["text"]

    chat_id = first[0]["chat"]["id"]
    _events((await user.post("/v1/ai/messages", json={"chat_id": chat_id, "text": "Davom et"})).text)
    assert [c["role"] for c in seen[1]["body"]["contents"]] == ["user", "model", "user"]
    detail = (await user.get(f"/v1/ai/chats/{chat_id}")).json()
    assert [m["role"] for m in detail["messages"]] == ["user", "model", "user", "model"]
    assert (await user.get("/v1/ai/chats")).json()["items"][0]["id"] == chat_id

    over = await user.post("/v1/ai/messages", json={"text": "uchinchi"})
    assert over.status_code == 429 and over.json()["detail"]["code"] == "AI_DAILY_LIMIT"
    other = await _linked(new_customer, session_factory, 7002)
    assert (await other.get(f"/v1/ai/chats/{chat_id}")).status_code == 404
    assert (await user.delete(f"/v1/ai/chats/{chat_id}")).status_code == 204
    assert (await user.get("/v1/ai/chats")).json()["items"] == []


async def test_provider_failures_reach_the_app_only_as_uzaro_codes(client, new_customer, session_factory, monkeypatch):
    owner = await _admin(session_factory, role=AdminRole.OWNER)
    dotted = "AQ.Ab8FAKEtestKey_0123456789-abcdefghij"  # a Google Cloud key: the dot is part of it
    assert (await client.put("/v1/admin/ai", headers=owner, json={"api_key": dotted, "daily_limit": 5})).status_code == 200
    seen: list[dict] = []
    working = _provider(seen)

    def cloud_only(request: httpx.Request) -> httpx.Response:
        if "aiplatform" not in request.url.host:
            return httpx.Response(404, json={"error": {"message": "not found"}})
        return working.handle_request(request)

    monkeypatch.setattr(service, "transport", httpx.MockTransport(cloud_only))
    cloud_user = await _linked(new_customer, session_factory, 7102)
    answer = _events((await cloud_user.post("/v1/ai/messages", json={"text": "salom"})).text)
    assert answer[-1]["t"] == "done" and "aiplatform" in seen[0]["url"]
    await client.put("/v1/admin/ai", headers=owner, json={"api_key": KEY, "daily_limit": 5, "model": "gemini-x"})

    def overloaded(request: httpx.Request) -> httpx.Response:
        if "gemini-x" in request.url.path:
            return httpx.Response(503, json={"error": {"status": "UNAVAILABLE", "message": "high demand"}})
        return working.handle_request(request)

    seen.clear()
    monkeypatch.setattr(service, "transport", httpx.MockTransport(overloaded))
    answer = _events((await cloud_user.post("/v1/ai/messages", json={"text": "salom"})).text)
    assert answer[-1]["t"] == "done" and service.FALLBACK_MODELS[0] in seen[0]["url"]  # a busy model falls back
    monkeypatch.setattr(service, "transport", _provider([], status=429))
    user = await _linked(new_customer, session_factory, 7101)
    body = (await user.post("/v1/ai/messages", json={"text": "salom"})).text
    assert _events(body)[-1] == {"t": "error", "code": "AI_BUSY"} and "Gemini" not in body
    status = (await user.get("/v1/ai/status")).json()
    assert status["used_today"] == 0  # a question that got no answer gives its daily slot back
    assert (await user.post("/v1/ai/messages", json={"chat_id": str(uuid.uuid4()), "text": "x"})).status_code == 404
    assert (await user.get("/v1/ai/status")).json()["used_today"] == 0
    assert (await client.post("/v1/admin/ai/test", headers=owner)).json()["detail"]["code"] == "AI_BUSY"

    await client.put("/v1/admin/ai", headers=owner, json={"enabled": False})
    assert (await user.post("/v1/ai/messages", json={"text": "salom"})).json()["detail"]["code"] == "AI_NOT_CONFIGURED"
    assert (await user.get("/v1/ai/status")).json()["available"] is False
    async with session_factory() as db:
        assert (await db.scalars(select(AppSetting.key))).all()  # settings rows exist, key sealed
