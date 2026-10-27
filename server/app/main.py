import logging
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request, Response
from fastapi.staticfiles import StaticFiles

from app.config import get_settings
from app.db import engine
from app.deps import get_redis
from app.routers import admin, admin_auth, admin_market, admin_panel, admin_places, ads, billing, customers, market, media, places, profile, public
from app.security import RedactingFilter

ADMIN_WEB_DIR = Path(__file__).resolve().parent / "admin_web"
# Ad and product media may live on other https hosts; scripts and styles only from the panel itself.
ADMIN_CSP = (
    "default-src 'self'; script-src 'self'; style-src 'self' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; "
    "img-src 'self' blob: data: https:; media-src 'self' blob: https:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
)

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
        title="UZARO API",
        version="0.1.0",
        lifespan=lifespan,
        # No docs or public schema in production: don't publish the admin API map.
        docs_url=None if production else "/docs",
        openapi_url=None if production else "/openapi.json",
        redoc_url=None,
    )
    for module in (customers, profile, billing, admin, market, ads, media, places, admin_market, admin_places, admin_panel, admin_auth, public):
        app.include_router(module.router)
    # The web admin panel: static files only; every action goes through the X-Admin-Key API.
    app.mount("/admin", StaticFiles(directory=ADMIN_WEB_DIR, html=True), name="admin")

    @app.middleware("http")
    async def panel_headers(request: Request, call_next: Callable[[Request], Awaitable[Response]]) -> Response:
        response = await call_next(request)
        if request.url.path.startswith("/admin"):
            response.headers["Content-Security-Policy"] = ADMIN_CSP
            response.headers["X-Frame-Options"] = "DENY"
            response.headers["Referrer-Policy"] = "no-referrer"
            response.headers["Cache-Control"] = "no-cache"
        return response

    @app.get("/health", tags=["system"])
    async def health() -> dict[str, str]:
        await get_redis().ping()
        return {"status": "ok", "payments": "enabled" if settings.payments_enabled else "disabled"}

    return app


app = create_app()
