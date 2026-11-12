import asyncio
import logging
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager, suppress
from pathlib import Path

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from app.config import get_settings
from app.db import engine
from app.deps import get_redis
from app.limits import BodySizeLimit
from app.routers import (
    activity,
    admin,
    admin_auth,
    admin_gifts,
    admin_market,
    admin_movies,
    admin_music,
    admin_panel,
    admin_places,
    ads,
    badges,
    banned_channels,
    billing,
    customers,
    gifts,
    interests,
    market,
    media,
    movies,
    music,
    places,
    profile,
    public,
    quick_links,
    usernames,
)
from app.security import RedactingFilter
from app.services import movies as movie_pipeline

ADMIN_WEB_DIR = Path(__file__).resolve().parent / "admin_web"
# Ad and product media may live on other https hosts; scripts and styles only from the panel itself.
ADMIN_CSP = (
    "default-src 'self'; script-src 'self'; style-src 'self' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; "
    "img-src 'self' blob: data: https:; media-src 'self' blob: https:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
)
# Every other response (API JSON, /download, /privacy, /media): no plugins, no framing, no <base> hijack.
DEFAULT_CSP = "object-src 'none'; frame-ancestors 'none'; base-uri 'none'"
SECURITY_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Cross-Origin-Opener-Policy": "same-origin",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=(), payment=()",
}
HSTS = "max-age=31536000; includeSubDomains"
log = logging.getLogger("app")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
for handler in logging.getLogger().handlers:
    handler.addFilter(RedactingFilter())
# uvicorn's loggers do not propagate to the root handlers, so they need the filter themselves.
for name in ("uvicorn.access", "uvicorn.error"):
    logging.getLogger(name).addFilter(RedactingFilter())


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    stop = asyncio.Event()
    # Tests drive the movie pipeline directly instead of racing a background worker.
    worker = asyncio.create_task(movie_pipeline.worker(stop)) if get_settings().environment != "test" else None
    yield
    stop.set()
    if worker is not None:
        worker.cancel()
        with suppress(asyncio.CancelledError):
            await worker
    await get_redis().aclose()
    await engine.dispose()


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(
        title="UZARO API",
        version="0.1.0",
        lifespan=lifespan,
        # Docs and the schema only in development/test: staging and production don't publish the admin API map.
        docs_url="/docs" if settings.docs_enabled else None,
        openapi_url="/openapi.json" if settings.docs_enabled else None,
        redoc_url=None,
    )
    routers = (customers, profile, billing, admin, market, ads, media, places, movies, music, activity, gifts, badges, interests, usernames, banned_channels, quick_links)
    admin_routers = (admin_gifts, admin_market, admin_places, admin_movies, admin_music, admin_panel, admin_auth, public)
    for module in routers + admin_routers:
        app.include_router(module.router)
    app.include_router(banned_channels.admin_router)
    app.include_router(quick_links.admin_router)
    # The web admin panel: static files only; every action goes through the X-Admin-Key API.
    app.mount("/admin", StaticFiles(directory=ADMIN_WEB_DIR, html=True), name="admin")

    allowed_hosts = {host.lower() for host in settings.allowed_hosts}
    if settings.deployed and settings.admin_permanent_keys:
        log.warning("SADO_BILLING_ADMIN_PERMANENT_KEYS=true: CLI admin keys never expire; set false once admins use login/password")

    @app.middleware("http")
    async def security_headers(request: Request, call_next: Callable[[Request], Awaitable[Response]]) -> Response:
        path = request.url.path
        # /health stays reachable by container health checks that use an internal host name.
        if settings.deployed and path != "/health" and _host_name(request) not in allowed_hosts:
            return JSONResponse({"detail": "INVALID_HOST"}, status_code=400)
        response = await call_next(request)
        response.headers.update(SECURITY_HEADERS)
        if settings.deployed:
            response.headers["Strict-Transport-Security"] = HSTS
        if path.startswith("/admin"):
            response.headers["Content-Security-Policy"] = ADMIN_CSP
            response.headers["Cache-Control"] = "no-cache"
        else:
            response.headers.setdefault("Content-Security-Policy", DEFAULT_CSP)
        if path.startswith("/v1/"):
            # Tokens and personal data must not stay in shared or browser caches.
            response.headers.setdefault("Cache-Control", "no-store")
        return response

    # Outermost: oversized bodies are refused before the multipart parser buffers them.
    app.add_middleware(BodySizeLimit, max_bytes=settings.max_request_bytes)

    @app.get("/health", tags=["system"])
    async def health() -> dict[str, str]:
        await get_redis().ping()
        return {"status": "ok", "payments": "enabled" if settings.payments_enabled else "disabled"}

    return app


def _host_name(request: Request) -> str:
    host = request.headers.get("host", "")
    # Bracketed IPv6 keeps its colons; otherwise drop the port.
    return (host.split("]")[0] + "]" if host.startswith("[") else host.rsplit(":", 1)[0]).lower()


app = create_app()
