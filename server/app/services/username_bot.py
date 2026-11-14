"""Short UZARO usernames in the gifts bot: "/nom ab" (or the website's t.me/<bot>?start=buy_ab) shows the price,
the "/buy_ab" command link in that answer buys it for the UZARO balance.

The buyer is the Telegram account writing to the bot, so it must already be linked to a UZARO account (the app
links it automatically when the user opens the username or gifts screen).
"""

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import TelegramLink
from app.services import username_sale, wallet
from app.services.username_sale import UsernameError

START_PREFIX = "buy_"  # t.me/<bot>?start=buy_<name>
BUY_COMMAND = "/buy_"

NOT_LINKED = (
    "Avval UZARO ilovasida hisobingizni tasdiqlang: ilovada Profil → UZARO username bo'limini oching "
    "(ilova shu botga o'zi yozib tasdiqlaydi). Keyin shu yerga qaytib, nomni qayta yuboring."
)
HELP = (
    "Qisqa UZARO username (2–4 harf) sotib olish:\n"
    "/nom ab — narxini ko'rish\n\n"
    "5 va undan uzun nomlar bepul — ularni UZARO ilovasida Profil → UZARO username bo'limida olasiz."
)
ERRORS = {
    "USERNAME_INVALID": "Nom lotin harfi bilan boshlansin: harflar, raqamlar va _ (2–32 belgi, __ va oxirida _ bo'lmasin).",
    "USERNAME_RESERVED": "Bu nom tizim uchun ajratilgan (uzaro, admin, support, …bot).",
    "USERNAME_TAKEN": "Afsus, bu nom band.",
    "USERNAME_SALE_CLOSED": "Bu uzunlikdagi nomlar hozircha sotuvda emas.",
    "USERNAME_FREE": "Bu nom bepul — UZARO ilovasida Profil → UZARO username bo'limida oling.",
    "INSUFFICIENT_BALANCE": "Balans yetarli emas. UZARO ilovasida Profil → UZARO username → «Balansni to'ldirish» orqali to'ldiring.",
}


def som(amount: int) -> str:
    return f"{amount:,}".replace(",", " ") + " so'm"


def command_name(text: str) -> tuple[str, str] | None:
    """("quote" | "buy", raw name) for a username command, None for any other message."""
    parts = text.strip().split(maxsplit=1)
    if not parts:
        return None
    head = parts[0].split("@", 1)[0]  # "/buy_ab@uzaro_bot" from a command menu
    arg = parts[1].strip() if len(parts) == 2 else ""
    if head == "/start" and arg.startswith(START_PREFIX):
        return "quote", arg.removeprefix(START_PREFIX)
    if head == "/nom":
        return "quote", arg
    if head.startswith(BUY_COMMAND):
        return "buy", head.removeprefix(BUY_COMMAND)
    return None


async def answer(db: AsyncSession, telegram_user_id: int, action: str, raw: str) -> str:
    """The bot's reply to a username command; buying commits the purchase."""
    if not raw:
        return HELP
    lock = select(TelegramLink).where(TelegramLink.telegram_user_id == telegram_user_id)
    link = await db.scalar(lock.with_for_update() if action == "buy" else lock)
    try:
        if action == "buy":
            if link is None:
                return NOT_LINKED
            row, balance = await username_sale.buy(db, link, raw, channel="bot")
            return f"✅ @{row.username} endi sizniki! UZARO'da shu nom bilan topishadi.\nQolgan balans: {som(balance)}."
        offer = await username_sale.quote(db, raw, link.customer_id if link else None)
    except UsernameError as error:
        return ERRORS.get(error.code, "Xatolik. Keyinroq urinib ko'ring.")
    name = f"@{offer.username}"
    if offer.status == "yours":
        return f"{name} allaqachon sizniki."
    if offer.status != "for_sale":
        return f"{name}: {ERRORS[{'taken': 'USERNAME_TAKEN', 'closed': 'USERNAME_SALE_CLOSED', 'free': 'USERNAME_FREE'}[offer.status]]}"
    if link is None:
        return f"{name} — {som(offer.price_uzs)}.\n\n{NOT_LINKED}"
    balance = await wallet.balance(db, link.customer_id)
    lines = [f"{name} — {som(offer.price_uzs)}.", f"Balansingiz: {som(balance)}."]
    if balance < offer.price_uzs:
        lines.append(ERRORS["INSUFFICIENT_BALANCE"])
    else:
        lines.append(f"\nSotib olish uchun bosing: {BUY_COMMAND}{offer.username}")
        lines.append("Nom hozirgi UZARO username'ingiz o'rniga o'tadi.")
    return "\n".join(lines)
