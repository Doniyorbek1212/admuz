import httpx
import pytest
from fastapi import FastAPI, Request

from app.config import Settings
from app.limits import BodySizeLimit

SECRET = "x" * 40
SAFE = {
    "environment": "production",
    "jwt_secret": SECRET,
    "database_url": "postgresql+asyncpg://api:long-random@db:5432/sado",
    "redis_url": "redis://cache:6379/0",
    "FORWARDED_ALLOW_IPS": "172.18.0.0/16",
    # conftest enables the mock provider for the API tests; production must not.
    "enabled_providers": [],
}


def test_production_with_real_settings_starts() -> None:
    settings = Settings(**SAFE)
    assert not settings.docs_enabled


@pytest.mark.parametrize(
    ("override", "message"),
    [
        ({"database_url": "postgresql+asyncpg://sado:sado@db:5432/sado"}, "DATABASE_URL"),
        ({"redis_url": "redis://localhost:6379/2"}, "REDIS_URL"),
        ({"FORWARDED_ALLOW_IPS": ""}, "FORWARDED_ALLOW_IPS"),
        ({"FORWARDED_ALLOW_IPS": "*"}, "forge"),
        ({"max_request_bytes": 1024}, "MAX_REQUEST_BYTES"),
    ],
)
def test_production_refuses_development_defaults(override: dict[str, str | int], message: str) -> None:
    with pytest.raises(ValueError, match=message):
        Settings(**{**SAFE, **override})


def test_staging_hides_docs_development_shows_them() -> None:
    assert not Settings(**{**SAFE, "environment": "staging"}).docs_enabled
    assert Settings(environment="development", jwt_secret=SECRET, enabled_providers=[]).docs_enabled


def _echo_app(limit: int) -> BodySizeLimit:
    app = FastAPI()

    @app.post("/echo")
    async def echo(request: Request) -> dict[str, int]:
        return {"size": len(await request.body())}

    return BodySizeLimit(app, max_bytes=limit)


@pytest.mark.asyncio
async def test_body_limit_rejects_declared_and_streamed_oversize() -> None:
    transport = httpx.ASGITransport(app=_echo_app(10))
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        assert (await client.post("/echo", content=b"12345")).json() == {"size": 5}
        assert (await client.post("/echo", content=b"x" * 11)).status_code == 413

        async def chunks():
            for _ in range(4):
                yield b"xxxx"

        # No Content-Length: counted while streaming.
        assert (await client.post("/echo", content=chunks())).status_code == 413
