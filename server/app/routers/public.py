"""Public download of the Android app: release info for in-app update checks, a download page and the APK itself."""

import html
from pathlib import Path
from typing import Any

from fastapi import APIRouter
from fastapi.responses import FileResponse, HTMLResponse

from app.config import get_settings
from app.deps import DbDep
from app.errors import not_found
from app.services.market_settings import load_market_settings

router = APIRouter(tags=["public"])

APK_NAME = "UZARO.apk"


def apk_path() -> Path:
    """Uploaded next to the media files (same volume), replaced on each release."""
    return Path(get_settings().media_dir) / "release" / APK_NAME


@router.get("/v1/app/release")
async def release(db: DbDep) -> dict[str, Any]:
    settings = await load_market_settings(db)
    path = apk_path()
    return {
        "version": settings.app_version,
        "build": settings.app_build,
        "notes": settings.app_release_notes,
        "available": path.is_file(),
        "size_bytes": path.stat().st_size if path.is_file() else 0,
        "download_url": f"/download/{APK_NAME}",
    }


@router.get(f"/download/{APK_NAME}")
async def download_apk() -> FileResponse:
    path = apk_path()
    if not path.is_file():
        raise not_found("APK_NOT_PUBLISHED")
    return FileResponse(path, media_type="application/vnd.android.package-archive", filename=APK_NAME)


@router.get("/download", response_class=HTMLResponse)
async def download_page(db: DbDep) -> HTMLResponse:
    settings = await load_market_settings(db)
    path = apk_path()
    size = f"{path.stat().st_size / 1_048_576:.1f} MB" if path.is_file() else ""
    version = html.escape(settings.app_version or "")
    notes = "".join(f"<li>{html.escape(line.lstrip('-• ').strip())}</li>" for line in settings.app_release_notes.splitlines() if line.strip())
    button = (
        f'<a class="btn" href="/download/{APK_NAME}">Android uchun yuklab olish</a><p class="meta">Versiya {version} · {size}</p>'
        if path.is_file()
        else '<p class="meta">Yangi versiya tez orada joylanadi.</p>'
    )
    page = _PAGE.replace("{{button}}", button).replace("{{notes}}", f"<h2>Yangiliklar</h2><ul>{notes}</ul>" if notes else "")
    return HTMLResponse(page, headers={"Cache-Control": "no-cache"})


_PAGE = """<!doctype html>
<html lang="uz">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>UZARO — yuklab olish</title>
<style>
:root { --bg: #0c2b2a; --card: #12403d; --ink: #f4efe2; --muted: #b9cbc5; --gold: #e3b54a; }
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 24px 16px;
  background: radial-gradient(circle at 30% 10%, #165450, var(--bg) 60%);
  color: var(--ink); font: 16px/1.5 system-ui, "Segoe UI", sans-serif; }
main { width: 100%; max-width: 440px; background: var(--card); border: 1px solid #ffffff1f; border-radius: 22px; padding: 32px 26px; text-align: center; }
.logo { width: 84px; height: 84px; border-radius: 22px; background: linear-gradient(135deg, #1b7c73, #0d4f4a); display: grid; place-items: center;
  margin: 0 auto 14px; font-size: 40px; font-weight: 800; color: var(--gold); border: 2px solid var(--gold); }
h1 { margin: 0; font-size: 30px; letter-spacing: .04em; }
.tag { color: var(--muted); margin: 4px 0 24px; }
.btn { display: block; background: var(--gold); color: #1d1a10; text-decoration: none; font-weight: 800; padding: 15px; border-radius: 14px; font-size: 17px; }
.btn:focus-visible { outline: 3px solid var(--ink); outline-offset: 3px; }
.meta { color: var(--muted); font-size: 14px; margin: 10px 0 0; }
h2 { font-size: 16px; margin: 26px 0 8px; text-align: left; }
ul { text-align: left; margin: 0; padding-left: 20px; color: var(--muted); }
.how { text-align: left; color: var(--muted); font-size: 14px; margin-top: 22px; border-top: 1px solid #ffffff1f; padding-top: 16px; }
</style>
</head>
<body>
<main>
  <div class="logo">U</div>
  <h1>UZARO</h1>
  <p class="tag">Yaqinlar bilan, har doim</p>
  {{button}}
  {{notes}}
  <div class="how"><b>O'rnatish:</b> faylni oching, telefon so'rasa "Noma'lum manbalardan o'rnatish"ga ruxsat bering.
  Avvalgi versiya bo'lsa, ustidan yangilanadi, ma'lumotlar saqlanib qoladi.</div>
</main>
</body>
</html>"""
