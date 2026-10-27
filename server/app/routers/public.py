"""Public pages of the app: release info for in-app update checks, a download page, the APK and the privacy policy."""

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


@router.get("/privacy", response_class=HTMLResponse)
async def privacy_page() -> HTMLResponse:
    """Linked from the store listings and from Settings > Help in the app."""
    return HTMLResponse(_PRIVACY)


_PRIVACY = """<!doctype html>
<html lang="uz">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>UZARO — Maxfiylik siyosati / Privacy Policy</title>
<style>
body { margin: 0; background: #f6f4ee; color: #1d2b2a; font: 16px/1.6 system-ui, "Segoe UI", sans-serif; }
main { max-width: 760px; margin: 0 auto; padding: 32px 16px 56px; }
h1 { font-size: 28px; margin: 0 0 4px; }
h2 { font-size: 19px; margin: 28px 0 6px; }
.meta { color: #5c6b68; margin: 0 0 20px; }
hr { border: 0; border-top: 1px solid #d9d4c6; margin: 40px 0; }
a { color: #0d6b62; }
</style>
</head>
<body>
<main>
<h1>UZARO — Maxfiylik siyosati</h1>
<p class="meta">Oxirgi yangilanish: 2026-yil 26-oktabr</p>
<p>UZARO — Telegram tarmog'ida ishlaydigan messenger ilova. U Telegram'ning ochiq API'si (TDLib) orqali ishlaydi
va qo'shimcha ravishda biznes bo'limi (do'konlar, mahsulotlar, e'lonlar, "Hudud" ma'lumotnomasi) taklif qiladi.
Ushbu siyosat ilova qanday ma'lumotlardan foydalanishini tushuntiradi.</p>

<h2>1. Telegram ma'lumotlari</h2>
<p>Telefon raqamingiz, xabarlar, kontaktlar, fayllar va qo'ng'iroqlar to'g'ridan-to'g'ri Telegram serverlariga yuboriladi
va ular <a href="https://telegram.org/privacy">Telegram maxfiylik siyosati</a> asosida qayta ishlanadi.
UZARO serverlari xabarlaringizni ko'rmaydi va saqlamaydi. Chatlar keshi faqat qurilmangizda saqlanadi.</p>

<h2>2. Qurilma ruxsatlari</h2>
<ul>
<li><b>Kontaktlar</b> — siz ruxsat bersangiz, Telegram'dagi tanishlaringizni topish uchun Telegram'ga yuboriladi.</li>
<li><b>Kamera va mikrofon</b> — rasm, video, ovozli xabarlar va qo'ng'iroqlar uchun, faqat siz ishlatganda.</li>
<li><b>Joylashuv</b> — faqat siz chatda joylashuv yuborganingizda yoki "Hudud"da yaqin joylarni saralaganingizda.
Fonda kuzatilmaydi va saqlanmaydi.</li>
<li><b>Rasm va videolar</b> — siz tanlagan fayllarni yuborish uchun.</li>
<li><b>Bildirishnomalar</b> — yangi xabarlar haqida xabar berish uchun.</li>
</ul>

<h2>3. UZARO serveri saqlaydigan ma'lumotlar</h2>
<p>Biznes bo'limi uchun serverimiz quyidagilarni saqlaydi:</p>
<ul>
<li>anonim mijoz identifikatori va qurilma turi (Telegram ID ishlatilmaydi);</li>
<li>siz yaratgan do'kon, mahsulot, e'lon matnlari va rasmlari — ular boshqa foydalanuvchilarga ochiq ko'rsatiladi;</li>
<li>to'lov chekining rasmi (faqat siz yuklasangiz) — to'lovni tekshirish uchun, faqat administratorlar ko'radi;</li>
<li>ism, username va telefon raqami — faqat ilovada rozilik berganingizdan keyin;</li>
<li>Google Play orqali xaridlar bo'lsa, xarid tasdig'i (karta ma'lumotlari bizga kelmaydi).</li>
</ul>

<h2>4. Ma'lumotlarni ulashish</h2>
<p>Ma'lumotlaringizni sotmaymiz va reklama uchun uchinchi tomonlarga bermaymiz. Ular faqat Telegram (xabar almashish uchun),
Google Play (xaridlar uchun) va qonun talab qilgan hollarda davlat organlari bilan ulashiladi.</p>

<h2>5. Xavfsizlik va saqlash muddati</h2>
<p>Barcha aloqa HTTPS orqali shifrlanadi. Biznes ma'lumotlari siz ularni o'chirmaguningizcha yoki o'chirishni so'ramaguningizcha saqlanadi.</p>

<h2>6. O'chirish</h2>
<p>Do'kon, mahsulot va e'lonlarni ilovaning o'zida o'chirishingiz mumkin. Serverdagi barcha ma'lumotlaringizni o'chirish uchun
Google Play'dagi ilova sahifasida ko'rsatilgan email orqali murojaat qiling — 30 kun ichida o'chiriladi.
Telegram akkauntini <a href="https://my.telegram.org/delete">my.telegram.org/delete</a> orqali o'chirish mumkin.</p>

<h2>7. Bolalar</h2>
<p>Ilova 13 yoshdan kichik bolalar uchun mo'ljallanmagan.</p>

<h2>8. O'zgarishlar</h2>
<p>Siyosat o'zgarsa, shu sahifa yangilanadi.</p>

<hr>

<h1>UZARO — Privacy Policy</h1>
<p class="meta">Last updated: October 26, 2026</p>
<p>UZARO is a messaging app built on the Telegram network using Telegram's open API (TDLib). It also offers a business
section (shops, products, ads and a local places directory). This policy explains what data the app uses.</p>

<h2>1. Telegram data</h2>
<p>Your phone number, messages, contacts, files and calls go directly to Telegram's servers and are processed under the
<a href="https://telegram.org/privacy">Telegram Privacy Policy</a>. UZARO servers never see or store your messages.
The chat cache is stored only on your device.</p>

<h2>2. Device permissions</h2>
<ul>
<li><b>Contacts</b> — with your permission, sent to Telegram to find people you know on Telegram.</li>
<li><b>Camera and microphone</b> — for photos, videos, voice messages and calls, only when you use them.</li>
<li><b>Location</b> — only when you send a location in a chat or sort nearby places in the directory.
It is not tracked in the background and not stored.</li>
<li><b>Photos and videos</b> — to send files you choose.</li>
<li><b>Notifications</b> — to alert you about new messages.</li>
</ul>

<h2>3. Data stored on the UZARO server</h2>
<p>For the business section our server stores:</p>
<ul>
<li>an anonymous customer identifier and device type (your Telegram ID is not used);</li>
<li>shop, product and ad texts and images you create — these are shown publicly to other users;</li>
<li>a payment receipt image, only if you upload one — used to verify payment and seen only by administrators;</li>
<li>your name, username and phone number — only after you agree to share them in the app;</li>
<li>purchase confirmations for Google Play purchases (we never receive card details).</li>
</ul>

<h2>4. Sharing</h2>
<p>We do not sell your data or share it with third parties for advertising. Data is shared only with Telegram
(to deliver messages), Google Play (for purchases) and authorities when required by law.</p>

<h2>5. Security and retention</h2>
<p>All connections are encrypted with HTTPS. Business data is kept until you delete it or ask us to delete it.</p>

<h2>6. Deletion</h2>
<p>You can delete shops, products and ads in the app. To delete all your data from our server, contact us at the email
shown on the app's Google Play page; it is deleted within 30 days. Your Telegram account can be deleted at
<a href="https://my.telegram.org/delete">my.telegram.org/delete</a>.</p>

<h2>7. Children</h2>
<p>The app is not intended for children under 13.</p>

<h2>8. Changes</h2>
<p>If this policy changes, this page will be updated.</p>
</main>
</body>
</html>"""


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
