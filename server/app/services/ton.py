"""TON payments to the UZARO wallet, found on toncenter.com by their comment (the order code) and amount."""

import logging

import httpx

from app.config import get_settings

TIMEOUT_SECONDS = 15
SCAN_LIMIT = 100  # recent incoming transactions looked at per check
log = logging.getLogger("app.ton")


class TonError(Exception):
    """toncenter could not be asked; the user may try the check again later."""


def nano_for(amount_uzs: int, uzs_per_ton: int) -> int:
    """NanoTON to ask for [amount_uzs] at [uzs_per_ton], rounded up so the wallet never gets less."""
    return -(-amount_uzs * 1_000_000_000 // uzs_per_ton)


def ton_text(nano: int) -> str:
    """"1.25" for 1 250 000 000 nanoTON (up to 4 decimals, rounded up)."""
    whole, rest = divmod(-(-nano // 100_000), 10_000)
    return f"{whole}.{rest:04d}".rstrip("0").rstrip(".")


async def find_payment(wallet: str, comment: str, min_nano: int) -> str | None:
    """The hash of an incoming transfer to [wallet] carrying [comment] and at least [min_nano], or None."""
    settings = get_settings()
    params: dict[str, str | int] = {"address": wallet, "limit": SCAN_LIMIT, "archival": "false"}
    if settings.toncenter_api_key:
        params["api_key"] = settings.toncenter_api_key
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS) as client:
            response = await client.get(f"{settings.toncenter_url.rstrip('/')}/getTransactions", params=params)
        data = response.json()
    except (httpx.HTTPError, ValueError) as error:
        raise TonError(type(error).__name__) from None
    if not data.get("ok"):
        raise TonError(str(data.get("error", "toncenter failed")))
    for tx in data.get("result") or []:
        message = tx.get("in_msg") or {}
        if (message.get("message") or "").strip() != comment or not message.get("source"):
            continue
        try:
            value = int(message.get("value") or 0)
        except ValueError:
            continue
        if value >= min_nano:
            return str((tx.get("transaction_id") or {}).get("hash") or "")[:56] or None
    return None
