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


def test_admin_networks_are_validated_and_permanent_keys_default_off(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("SADO_BILLING_ADMIN_PERMANENT_KEYS", raising=False)  # conftest turns them on for the API tests
    assert Settings(**SAFE).admin_permanent_keys is False
    assert [str(n) for n in Settings(**SAFE, admin_allowed_ips=["203.0.113.7", "10.8.0.0/24"]).admin_networks] == ["203.0.113.7/32", "10.8.0.0/24"]
    with pytest.raises(ValueError, match="ADMIN_ALLOWED_IPS"):
        Settings(**SAFE, admin_allowed_ips=["office"])


@pytest.mark.parametrize("hosts", [[], ["*"], ["uzaromessenger.uz", "*"]])
def test_production_refuses_open_host_list(hosts: list[str]) -> None:
    with pytest.raises(ValueError, match="ALLOWED_HOSTS"):
        Settings(**{**SAFE, "allowed_hosts": hosts})


@pytest.mark.asyncio
async def test_production_answers_only_known_hosts_with_security_headers(monkeypatch: pytest.MonkeyPatch) -> None:
    from app import main

    monkeypatch.setattr(main, "get_settings", lambda: Settings(**SAFE))
    transport = httpx.ASGITransport(app=main.create_app())
    async with httpx.AsyncClient(transport=transport, base_url="https://uzaromessenger.uz") as client:
        ok = await client.get("/v1/nothing-here")
        assert ok.status_code == 404
        assert ok.headers["x-content-type-options"] == "nosniff"
        assert ok.headers["x-frame-options"] == "DENY"
        assert ok.headers["cache-control"] == "no-store"
        assert ok.headers["strict-transport-security"].startswith("max-age=")
        assert "frame-ancestors 'none'" in ok.headers["content-security-policy"]
        assert (await client.get("/v1/nothing-here", headers={"host": "sado.voxo.uz:443"})).status_code == 404
        spoofed = await client.get("/v1/nothing-here", headers={"host": "evil.example"})
        assert spoofed.status_code == 400
        assert spoofed.json() == {"detail": "INVALID_HOST"}


def test_access_log_hides_coordinates_and_tokens() -> None:
    import logging

    from app import main  # noqa: F401  (installs the filters)

    path = "/v1/places?region=Toshkent&lat=41.2995&lon=69.2401&slat=1"
    record = logging.LogRecord("uvicorn.access", logging.INFO, "", 0, '%s - "%s %s HTTP/%s" %d', ("1.2.3.4", "GET", path, "1.1", 200), None)
    for log_filter in logging.getLogger("uvicorn.access").filters:
        log_filter.filter(record)
    line = record.getMessage()
    assert "41.2995" not in line and "69.2401" not in line
    assert "lat=[REDACTED]&lon=[REDACTED]" in line and "slat=1" in line


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
