import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.config import get_settings
from app.db import engine
from app.deps import get_redis
from app.routers import admin, admin_market, ads, billing, customers, market, media, profile
from app.security import RedactingFilter

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
for handler in logging.getLogger().handlers:
    handler.addFilter(RedactingFilter())


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    yield
    await get_redis().aclose()
    await engine.dispose()


def create_app() -> FastAPI:
    settings = get_settings()
    production = settings.environment == "production"
    app = FastAPI(
        title="Sado Billing",
        version="0.1.0",
        lifespan=lifespan,
        # No docs or public schema in production: don't publish the admin API map.
        docs_url=None if production else "/docs",
        openapi_url=None if production else "/openapi.json",
        redoc_url=None,
    )
    for module in (customers, profile, billing, admin, market, ads, media, admin_market):
        app.include_router(module.router)

    @app.get("/health", tags=["system"])
    async def health() -> dict[str, str]:
        await get_redis().ping()
        return {"status": "ok", "payments": "enabled" if settings.payments_enabled else "disabled"}

    return app


app = create_app()
