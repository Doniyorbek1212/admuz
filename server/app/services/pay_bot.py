"""@UzaroPay_bot: tops up the UZARO balance inside Telegram and signs people in on the website's wallet page.

The payer is the Telegram account writing to the bot, so it must already be linked to a UZARO account (the app
proves it through the gifts bot). Methods: Payme (a checkout link), Telegram Stars (an invoice), TON (a transfer
carrying an order code, checked on toncenter) and a card transfer whose receipt photo an admin approves.
Short-lived state lives in Redis; money reaches the balance only through the wallet ledger, once per payment.
"""

import html
import json
import logging
import secrets
import uuid
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.deps import get_redis, rate_limit
from app.errors import ApiError
from app.models import TelegramLink, TopupStatus, WalletTopup
from app.routers import payme
from app.security import sha256_hex
from app.services import telegram_api as tg
from app.services import ton, wallet
from app.services.audit import audit
from app.services.market_settings import MarketSettings, load_market_settings
from app.services.pay_notify import som
from app.uploads import save_receipt_bytes

log = logging.getLogger("app.pay_bot")

MAX_PENDING_RECEIPTS = 3
CARD_WAIT_SECONDS = 60 * 60  # how long the bot waits for a receipt photo after showing the card
STARS_TTL_SECONDS = 7 * 24 * 3600
TON_TTL_SECONDS = 3 * 24 * 3600
WEB_PREFIX = "web_"  # t.me/<bot>?start=web_<code>: the website's sign-in
WEB_CODE_MAX = 40  # longer than any code the site issues; keeps callback_data under Telegram's 64 bytes
BUTTONS_PER_10_MIN = 60  # per Telegram user: invoices and TON orders each leave a Redis entry behind

NOT_LINKED = (
    "Avval UZARO ilovasida hisobingizni tasdiqlang: ilovada Profil → ⋮ → Sovg'alar bo'limini oching "
    "(ilova Telegram hisobingizni o'zi tasdiqlaydi). Keyin shu yerga qaytib /start ni bosing."
)


def webhook_secret() -> str:
    """The secret_token given to setWebhook; Telegram echoes it in X-Telegram-Bot-Api-Secret-Token."""
    return sha256_hex(f"uzaro-pay-webhook:{get_settings().pay_bot_token}")


def _button(text: str, data: str) -> dict[str, str]:
    return {"text": text, "callback_data": data}


def _keyboard(*rows: list[dict[str, str]]) -> dict[str, Any]:
    return {"inline_keyboard": [row for row in rows if row]}


async def _customer(db: AsyncSession, telegram_user_id: int) -> uuid.UUID | None:
    return await db.scalar(select(TelegramLink.customer_id).where(TelegramLink.telegram_user_id == telegram_user_id))


# ---- entry point ----


async def handle(db: AsyncSession, update: dict[str, Any]) -> None:
    """One webhook update. Telegram API failures are logged; the update is never retried."""
    try:
        if isinstance(query := update.get("pre_checkout_query"), dict):
            await _pre_checkout(query)
        elif isinstance(query := update.get("callback_query"), dict):
            await _callback(db, query)
        elif isinstance(message := update.get("message"), dict):
            await _message(db, message)
    except tg.TelegramError as error:
        log.warning("pay bot update not handled: %s", error)


async def _message(db: AsyncSession, message: dict[str, Any]) -> None:
    sender, chat = message.get("from") or {}, message.get("chat") or {}
    user_id = sender.get("id")
    if not isinstance(user_id, int) or sender.get("is_bot") or chat.get("type") != "private":
        return
    if isinstance(paid := message.get("successful_payment"), dict):
        return await _stars_paid(db, user_id, paid)
    if message.get("photo") or (message.get("document") or {}).get("mime_type", "").startswith("image/"):
        return await _receipt(db, user_id, message)
    parts = (message.get("text") or "").strip().split(maxsplit=1)
    if parts and parts[0] == "/start" and len(parts) == 2 and parts[1].startswith(WEB_PREFIX):
        return await _web_ask(db, user_id, parts[1].removeprefix(WEB_PREFIX)[:WEB_CODE_MAX])
    await _menu(db, user_id)


# ---- menus ----


async def _menu(db: AsyncSession, user_id: int, edit: int | None = None) -> None:
    """The balance and the packs; [edit] replaces that message instead of sending a new one."""
    customer = await _customer(db, user_id)
    if customer is None:
        return await tg.send_text(user_id, NOT_LINKED)
    packs = [_button(som(a), f"a:{a}") for a in wallet.TOPUP_PACKS_UZS]
    rows = [packs[i : i + 2] for i in range(0, len(packs), 2)]
    text = f"💳 <b>UZARO hamyon</b>\nBalans: <b>{som(await wallet.balance(db, customer))}</b>\n\nQancha to'ldirasiz?"
    await _show(user_id, text, _keyboard(*rows), edit)


async def _show(chat_id: int, text: str, markup: dict[str, Any], edit: int | None) -> None:
    if edit is None:
        await tg.call("sendMessage", chat_id=chat_id, text=text, parse_mode="HTML", reply_markup=markup)
    else:
        await tg.call("editMessageText", chat_id=chat_id, message_id=edit, text=text, parse_mode="HTML", reply_markup=markup)


async def _methods(db: AsyncSession, user_id: int, amount: int, edit: int) -> None:
    rates = await load_market_settings(db)
    rows = [[_button("💳 Payme", f"m:payme:{amount}")]] if payme.payme_configured() else []
    if rates.stars_uzs_per_star:
        rows.append([_button(f"⭐ Telegram Stars — {_stars(amount, rates)} ⭐", f"m:stars:{amount}")])
    if rates.ton_uzs_per_ton and rates.ton_wallet:
        rows.append([_button(f"💎 TON — {ton.ton_text(ton.nano_for(amount, rates.ton_uzs_per_ton))} TON", f"m:ton:{amount}")])
    if rates.ad_payment_card:
        rows.append([_button("🧾 Karta orqali (admin tasdiqlaydi)", f"m:card:{amount}")])
    rows.append([_button("« Orqaga", "back")])
    await _show(user_id, f"<b>{som(amount)}</b> — to'lov usulini tanlang:", _keyboard(*rows), edit)


def _stars(amount: int, rates: MarketSettings) -> int:
    return -(-amount // rates.stars_uzs_per_star)


async def _callback(db: AsyncSession, query: dict[str, Any]) -> None:
    sender = query.get("from") or {}
    user_id = sender.get("id")
    message_id = (query.get("message") or {}).get("message_id")
    data = str(query.get("data") or "")
    alert = None
    if isinstance(user_id, int) and isinstance(message_id, int):
        alert = await _route(db, user_id, message_id, data, str(sender.get("first_name") or ""))
    await tg.call("answerCallbackQuery", callback_query_id=query.get("id"), text=alert, show_alert=bool(alert))


async def _route(db: AsyncSession, user_id: int, message_id: int, data: str, query_name: str = "") -> str | None:
    """Runs a button; returns a pop-up text for the user, or None."""
    kind, _, rest = data.partition(":")
    customer = await _customer(db, user_id)
    if customer is None:
        return "Avval UZARO ilovasida hisobingizni tasdiqlang."
    try:
        await rate_limit(f"paybot:{user_id}", limit=BUTTONS_PER_10_MIN, window_seconds=600)
    except ApiError:
        return "Juda ko'p urinish. Birozdan keyin qayta urinib ko'ring."
    if kind == "w":
        return await _web_confirm(customer, user_id, message_id, query_name, rest[:WEB_CODE_MAX])
    if kind == "back":
        return await _menu(db, user_id, message_id)
    if kind == "t":
        return await _ton_check(db, customer, user_id, rest)
    # "a:<amount>" picks a pack, "m:<method>:<amount>" a way to pay for it.
    method, _, amount_text = rest.partition(":") if kind == "m" else ("", "", rest)
    amount = int(amount_text) if amount_text.isdigit() else 0
    if amount not in wallet.TOPUP_PACKS_UZS:
        return "Bu summa endi mavjud emas. /start ni bosing."
    if kind == "a":
        return await _methods(db, user_id, amount, message_id)
    handlers = {"payme": _payme, "stars": _stars_invoice, "ton": _ton_order, "card": _card}
    if kind != "m" or method not in handlers:
        return None
    try:
        return await handlers[method](db, customer, user_id, amount, message_id)
    except ApiError as error:
        return "Juda ko'p urinish. Birozdan keyin qayta urinib ko'ring." if error.status_code == 429 else "Bu usul hozir ishlamayapti."


# ---- Payme ----


async def _payme(db: AsyncSession, customer: uuid.UUID, user_id: int, amount: int, edit: int) -> None:
    order = await payme.new_order(db, customer, amount, "bot")
    markup = _keyboard([{"text": f"💳 Payme orqali {som(amount)} to'lash", "url": payme.checkout_url(order)}], [_button("« Orqaga", "back")])
    await _show(user_id, f"<b>{som(amount)}</b>\nTugmani bosing va Payme'da to'lang — pul darhol hamyonga tushadi.", markup, edit)


# ---- Telegram Stars ----


async def _stars_invoice(db: AsyncSession, customer: uuid.UUID, user_id: int, amount: int, edit: int) -> str | None:
    rates = await load_market_settings(db)
    if not rates.stars_uzs_per_star:
        return "Stars orqali to'lov hozir o'chiq."
    stars = _stars(amount, rates)
    invoice = secrets.token_urlsafe(12)
    entry = json.dumps({"c": str(customer), "a": amount, "s": stars, "u": user_id})
    await get_redis().set(f"paybot:stars:{invoice}", entry, ex=STARS_TTL_SECONDS)
    await tg.call(
        "sendInvoice", chat_id=user_id, title="UZARO hamyon", description=f"UZARO balansiga {som(amount)}",
        payload=invoice, currency="XTR", prices=[{"label": som(amount), "amount": stars}],
    )
    return None


async def _stars_entry(payload: str) -> dict[str, Any] | None:
    raw = await get_redis().get(f"paybot:stars:{payload}")
    return json.loads(raw) if raw else None


async def _pre_checkout(query: dict[str, Any]) -> None:
    """Telegram asks before taking the Stars: only our own, unexpired invoice at its exact price goes through."""
    entry = await _stars_entry(str(query.get("invoice_payload") or ""))
    ok = (
        entry is not None
        and query.get("currency") == "XTR"
        and query.get("total_amount") == entry["s"]
        and (query.get("from") or {}).get("id") == entry["u"]
    )
    error = None if ok else "Hisob eskirgan. Botda /start ni bosib, qaytadan tanlang."
    await tg.call("answerPreCheckoutQuery", pre_checkout_query_id=query.get("id"), ok=ok, error_message=error)


async def _stars_paid(db: AsyncSession, user_id: int, paid: dict[str, Any]) -> None:
    charge = str(paid.get("telegram_payment_charge_id") or "")
    entry = await _stars_entry(str(paid.get("invoice_payload") or ""))
    if entry is None or paid.get("currency") != "XTR" or not charge:
        audit(db, f"telegram:{user_id}", "stars_unmatched", charge or "?", stars=paid.get("total_amount"))
        await db.commit()
        return await tg.send_text(user_id, "To'lov keldi, lekin buyurtma topilmadi. Administrator bilan bog'laning, kod: " + charge[:24])
    reference = f"stars:{charge}" if len(charge) <= 58 else f"stars:{sha256_hex(charge)[:40]}"
    await _credit(db, uuid.UUID(entry["c"]), user_id, entry["a"], reference, "Telegram Stars")


async def _credit(db: AsyncSession, customer: uuid.UUID, user_id: int, amount: int, reference: str, method: str) -> bool:
    """Credits one payment once; tells the payer. False when this payment was already credited."""
    try:
        fresh = await wallet.record_topup(db, customer, amount, reference)
        if fresh:
            audit(db, f"customer:{customer}", "bot_topup", reference, amount_uzs=amount, method=method)
        await db.commit()
    except IntegrityError:
        await db.rollback()
        fresh = False
    if fresh:
        balance = await wallet.balance(db, customer)
        await tg.send_text(user_id, f"✅ {som(amount)} hamyonga tushdi ({method}).\nBalans: {som(balance)}.")
    return fresh


# ---- TON ----


async def _ton_order(db: AsyncSession, customer: uuid.UUID, user_id: int, amount: int, edit: int) -> str | None:
    rates = await load_market_settings(db)
    if not (rates.ton_uzs_per_ton and rates.ton_wallet):
        return "TON orqali to'lov hozir o'chiq."
    nano = ton.nano_for(amount, rates.ton_uzs_per_ton)
    code = "UZ" + secrets.token_hex(4).upper()
    entry = json.dumps({"c": str(customer), "a": amount, "n": nano, "w": rates.ton_wallet})
    await get_redis().set(f"paybot:ton:{code}", entry, ex=TON_TTL_SECONDS)
    amount_ton = ton.ton_text(nano)
    text = (
        f"💎 <b>{som(amount)} = {amount_ton} TON</b>\n\n"
        f"1. Shu manzilga aynan <b>{amount_ton} TON</b> yuboring:\n<code>{html.escape(rates.ton_wallet)}</code>\n"
        f"2. Izohga (comment) shu kodni yozing:\n<code>{code}</code>\n"
        "3. Yuborgach «To'ladim» tugmasini bosing.\n\nIzohsiz yoki kam yuborilgan to'lov avtomatik topilmaydi."
    )
    wallet_link = f"https://app.tonkeeper.com/transfer/{rates.ton_wallet}?amount={nano}&text={code}"
    markup = _keyboard(
        [{"text": "💎 Tonkeeper'da ochish", "url": wallet_link}], [_button("✅ To'ladim — tekshirish", f"t:{code}")], [_button("« Orqaga", "back")]
    )
    await _show(user_id, text, markup, edit)
    return None


async def _ton_check(db: AsyncSession, customer: uuid.UUID, user_id: int, code: str) -> str | None:
    raw = await get_redis().get(f"paybot:ton:{code}")
    entry = json.loads(raw) if raw else None
    if entry is None or entry["c"] != str(customer):
        return "Bu buyurtma eskirgan. To'lagan bo'lsangiz, administrator bilan bog'laning: kod " + code[:12]
    try:
        tx = await ton.find_payment(entry["w"], code, entry["n"])
    except ton.TonError:
        return "TON tarmog'ini hozir tekshirib bo'lmadi. Bir daqiqadan keyin qayta bosing."
    if tx is None:
        return "To'lov hali ko'rinmadi. Tarmoq 1–2 daqiqada tasdiqlaydi, keyin qayta bosing."
    await _credit(db, customer, user_id, entry["a"], f"ton:{tx}", "TON")
    await get_redis().delete(f"paybot:ton:{code}")
    return None


# ---- card transfer, checked by an admin ----


async def _card(db: AsyncSession, customer: uuid.UUID, user_id: int, amount: int, edit: int) -> str | None:
    rates = await load_market_settings(db)
    if not rates.ad_payment_card:
        return "Karta orqali to'lov hozir o'chiq."
    await get_redis().set(f"paybot:card:{user_id}", str(amount), ex=CARD_WAIT_SECONDS)
    holder = f"\nEgasi: {html.escape(rates.ad_payment_card_holder)}" if rates.ad_payment_card_holder else ""
    text = (
        f"🧾 <b>{som(amount)}</b> ni shu kartaga o'tkazing:\n<code>{html.escape(rates.ad_payment_card)}</code>{holder}\n\n"
        "Keyin to'lov cheki (skrinshot) rasmini shu chatga yuboring. Administrator tekshirgach, pul hamyonga tushadi va shu yerda xabar beramiz."
    )
    await _show(user_id, text, _keyboard([_button("« Orqaga", "back")]), edit)
    return None


async def _receipt(db: AsyncSession, user_id: int, message: dict[str, Any]) -> None:
    raw = await get_redis().get(f"paybot:card:{user_id}")
    customer = await _customer(db, user_id)
    if raw is None or customer is None:
        return await tg.send_text(user_id, "Chek yuborishdan oldin summani va «Karta orqali» usulini tanlang: /start")
    pending = await db.scalar(
        select(func.count()).select_from(WalletTopup).where(WalletTopup.customer_id == customer, WalletTopup.status == TopupStatus.PENDING.value)
    ) or 0
    if pending >= MAX_PENDING_RECEIPTS:
        return await tg.send_text(user_id, "Sizda tekshirilmagan cheklar ko'p. Administrator ularni ko'rib chiqqach, yangisini yuboring.")
    file_id = (message.get("photo") or [{}])[-1].get("file_id") or (message.get("document") or {}).get("file_id")
    try:
        path = await save_receipt_bytes(await tg.download(str(file_id), get_settings().max_image_bytes))
    except (tg.TelegramError, ApiError):
        return await tg.send_text(user_id, "Rasmni o'qib bo'lmadi. Chekni JPG yoki PNG rasm qilib qayta yuboring.")
    db.add(WalletTopup(customer_id=customer, amount_uzs=int(raw), receipt_path=path))
    audit(db, f"customer:{customer}", "topup_requested", str(customer), amount_uzs=int(raw), channel="bot")
    await db.commit()
    await get_redis().delete(f"paybot:card:{user_id}")
    await tg.send_text(user_id, f"✅ {som(int(raw))} uchun chek qabul qilindi. Administrator tekshirgach, shu yerda xabar beramiz.")


# ---- website sign-in ----


WEB_EXPIRED = "Kirish havolasi eskirgan. Saytda «Telegram orqali kirish» ni qayta bosing."


async def _web_ask(db: AsyncSession, user_id: int, code: str) -> None:
    """A sign-in link only asks: someone else may have sent the person a link to their own browser's code."""
    if await get_redis().get(f"weblogin:{code}") != "":
        return await tg.send_text(user_id, WEB_EXPIRED)
    if await _customer(db, user_id) is None:
        return await tg.send_text(user_id, NOT_LINKED)
    text = (
        "🌐 <b>uzaromessenger.uz</b> saytida hamyoningizga kirish so'raldi.\n\n"
        "Faqat saytni <b>o'zingiz</b> ochib, «Telegram orqali kirish» ni hozir bosgan bo'lsangiz tasdiqlang. "
        "Havolani kimdir yuborgan bo'lsa, bosmang — u sizning hamyoningizni ko'radi."
    )
    markup = _keyboard([_button("✅ Ha, bu men — kirish", f"w:{code}")], [_button("✖ Yo'q", "back")])
    await _show(user_id, text, markup, None)


async def _web_confirm(customer: uuid.UUID, user_id: int, message_id: int, first_name: str, code: str) -> str | None:
    redis = get_redis()
    if await redis.get(f"weblogin:{code}") != "":
        return WEB_EXPIRED
    ttl = max(await redis.ttl(f"weblogin:{code}"), 1)
    await redis.set(f"weblogin:{code}", json.dumps({"c": str(customer), "name": first_name[:64]}), ex=ttl)
    await tg.call("editMessageText", chat_id=user_id, message_id=message_id, text="✅ Saytga kirish tasdiqlandi. Brauzerga qayting.")
    return None
