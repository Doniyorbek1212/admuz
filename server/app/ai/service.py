"""UZARO AI settings (key encrypted at rest), daily limits, and the streaming call to the model provider.

The provider is Google's Gemini API, but nothing provider-specific ever reaches the app: replies are plain text,
errors are UZARO codes, and the system instruction makes the model present itself as UZARO AI.
"""

import base64
import hashlib
import json
import logging
import os
from collections.abc import AsyncIterator
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import httpx
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.deps import get_redis
from app.models import AppSetting

log = logging.getLogger("app.ai")

KEY_SETTING = "ai_provider_key"
MODEL_SETTING = "ai_model"
LIMIT_SETTING = "ai_daily_limit"
ENABLED_SETTING = "ai_enabled"
DEFAULT_MODEL = "gemini-3.8-flash"
DEFAULT_DAILY_LIMIT = 50
MAX_PROMPT_CHARS = 8000
HISTORY_MESSAGES = 30  # earlier turns sent with each question
HISTORY_CHARS = 40_000
_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/{model}:streamGenerateContent?alt=sse"
# Google Cloud (Vertex AI express) keys are served here, with the same request and reply shape.
_CLOUD_ENDPOINT = "https://aiplatform.googleapis.com/v1/publishers/google/models/{model}:streamGenerateContent?alt=sse"


def _reason(raw: bytes) -> str:
    """The provider's error status and message for the server log (Google's errors never echo the key)."""
    try:
        body = json.loads(raw)
    except ValueError:
        return ""
    if isinstance(body, list):  # the Cloud endpoint wraps the error in a list
        body = body[0] if body and isinstance(body[0], dict) else {}
    error = body.get("error") if isinstance(body, dict) else None
    if not isinstance(error, dict):
        return ""
    return f"{error.get('status', '')}: {str(error.get('message', ''))[:200]}"


# Gemini API first (AI Studio keys, also the newer "AQ." ones); Google Cloud keys are tried on 403/404.
_ENDPOINTS = (_ENDPOINT, _CLOUD_ENDPOINT)
# Tried in order when the chosen model is overloaded (503), out of quota (429) or retired (404).
FALLBACK_MODELS = ("gemini-3.6-flash", "gemini-3.5-flash", "gemini-3.1-flash-lite")
_TRY_NEXT = {403, 404, 429, 500, 503}
_TIMEOUT = httpx.Timeout(connect=10, read=45, write=20, pool=10)


def _attempts(model: str) -> list[tuple[str, str]]:
    """The chosen model, then the fallbacks, on the Gemini API; last the chosen model on the Cloud endpoint."""
    models = [model, *(m for m in FALLBACK_MODELS if m != model)]
    return [(_ENDPOINT, m) for m in models] + [(_CLOUD_ENDPOINT, model)]
transport: httpx.AsyncBaseTransport | None = None  # tests swap in a fake provider

SYSTEM_PROMPT = (
    "You are UZARO AI, the assistant built into the UZARO messenger app, made by the UZARO team in Uzbekistan. "
    "Never say you are Gemini, Bard, Google, OpenAI, ChatGPT or any other product or company, and never name the "
    "model or company behind you; if asked who made you or what model you are, say you are UZARO AI by the UZARO team. "
    "Answer in the language the user writes in (Uzbek Latin by default for Uzbek, Russian, English or others). "
    "Be helpful, accurate and concise; use Markdown (headings, lists, **bold**, code blocks) when it helps reading. "
    "Today is {today}."
)


class AiError(Exception):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


# ---- the key, encrypted with a key derived from the server secret ----


def _cipher() -> AESGCM:
    # shortcut: rotating SADO_BILLING_JWT_SECRET makes the saved key unreadable; the owner then saves it again.
    return AESGCM(hashlib.sha256(b"uzaro-ai-key:" + get_settings().jwt_secret.encode()).digest())


def seal(secret: str) -> str:
    nonce = os.urandom(12)
    return base64.b64encode(nonce + _cipher().encrypt(nonce, secret.encode(), None)).decode()


def unseal(sealed: str) -> str | None:
    try:
        raw = base64.b64decode(sealed)
        return _cipher().decrypt(raw[:12], raw[12:], None).decode()
    except (InvalidTag, ValueError):
        return None


@dataclass(frozen=True)
class AiConfig:
    key: str | None
    model: str
    daily_limit: int
    enabled: bool

    @property
    def ready(self) -> bool:
        return self.enabled and bool(self.key)


async def load(db: AsyncSession) -> AiConfig:
    rows = {k: await db.get(AppSetting, k) for k in (KEY_SETTING, MODEL_SETTING, LIMIT_SETTING, ENABLED_SETTING)}
    sealed = rows[KEY_SETTING]
    return AiConfig(
        key=unseal(sealed.value) if sealed else None,
        model=rows[MODEL_SETTING].value if rows[MODEL_SETTING] else DEFAULT_MODEL,
        daily_limit=int(rows[LIMIT_SETTING].value) if rows[LIMIT_SETTING] else DEFAULT_DAILY_LIMIT,
        enabled=rows[ENABLED_SETTING].value == "1" if rows[ENABLED_SETTING] else True,
    )


async def save(db: AsyncSession, admin: str, key: str, value: str) -> None:
    row = await db.get(AppSetting, key)
    if row is None:
        db.add(AppSetting(key=key, value=value, updated_by=admin))
    else:
        row.value, row.updated_by = value, admin


# ---- daily limit per customer ----


def _day_bucket(customer_id: object) -> str:
    # The day turns at midnight in Uzbekistan (UTC+5, no daylight saving).
    return f"ai:day:{datetime.now(UTC) + timedelta(hours=5):%Y%m%d}:{customer_id}"


async def used_today(customer_id: object) -> int:
    return int(await get_redis().get(_day_bucket(customer_id)) or 0)


async def take_one(customer_id: object, limit: int) -> None:
    redis = get_redis()
    bucket = _day_bucket(customer_id)
    count = await redis.incr(bucket)
    if count == 1:
        await redis.expire(bucket, 26 * 3600)
    if count > limit:
        await redis.decr(bucket)
        raise AiError("AI_DAILY_LIMIT")


async def give_back(customer_id: object) -> None:
    """Returns a slot taken for a question that got no answer."""
    redis = get_redis()
    bucket = _day_bucket(customer_id)
    if int(await redis.get(bucket) or 0) > 0:
        await redis.decr(bucket)


# ---- the provider ----


def _contents(history: list[tuple[str, str]]) -> list[dict]:
    """Recent turns (oldest first) within the size budget; the provider wants user/model turns alternating."""
    picked: list[tuple[str, str]] = []
    total = 0
    for role, text in reversed(history[-HISTORY_MESSAGES:]):
        total += len(text)
        if total > HISTORY_CHARS and picked:
            break
        picked.append((role, text))
    picked.reverse()
    while picked and picked[0][0] != "user":
        picked.pop(0)
    merged: list[dict] = []
    for role, text in picked:
        if merged and merged[-1]["role"] == role:
            merged[-1]["parts"][0]["text"] += "\n\n" + text
        else:
            merged.append({"role": role, "parts": [{"text": text}]})
    return merged


async def stream_reply(config: AiConfig, history: list[tuple[str, str]], client: httpx.AsyncClient | None = None) -> AsyncIterator[str]:
    """Yields the reply in pieces. Raises AiError("AI_UNAVAILABLE") on any provider failure (details only logged)."""
    if not config.ready:
        raise AiError("AI_NOT_CONFIGURED")
    body = {
        "systemInstruction": {"parts": [{"text": SYSTEM_PROMPT.format(today=f"{datetime.now(UTC):%Y-%m-%d}")}]},
        "contents": _contents(history),
        "generationConfig": {"temperature": 0.7, "maxOutputTokens": 4096},
    }
    owned = client is None
    http = client or httpx.AsyncClient(timeout=_TIMEOUT, transport=transport)
    attempts = _attempts(config.model)
    busy = False
    try:
        for index, (endpoint, model) in enumerate(attempts):
            last = index + 1 == len(attempts)
            sent = False
            try:
                async with http.stream("POST", endpoint.format(model=model), json=body,
                                       headers={"x-goog-api-key": config.key or ""}) as response:
                    if response.status_code != 200:
                        log.warning("ai provider refused %s on endpoint %d: %s %s", model, _ENDPOINTS.index(endpoint),
                                    response.status_code, _reason(await response.aread()))
                        busy = busy or response.status_code in (429, 503)
                        if response.status_code in _TRY_NEXT and not last:
                            continue
                        raise AiError("AI_BUSY" if busy else "AI_UNAVAILABLE")
                    async for line in response.aiter_lines():
                        if not line.startswith("data:"):
                            continue
                        try:
                            event = json.loads(line[5:])
                        except ValueError:
                            continue
                        for candidate in event.get("candidates") or []:
                            for part in (candidate.get("content") or {}).get("parts") or []:
                                if isinstance(part.get("text"), str) and not part.get("thought"):
                                    sent = True
                                    yield part["text"]
                    return
            except httpx.HTTPError as exc:
                log.warning("ai provider unreachable on %s: %s", model, type(exc).__name__)
                if sent or last:  # half a reply cannot be continued by another model
                    raise AiError("AI_BUSY" if busy else "AI_UNAVAILABLE") from exc
    finally:
        if owned:
            await http.aclose()
