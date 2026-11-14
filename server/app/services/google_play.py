"""Google Play one-time products (the wallet top-up packs): read a purchase and consume it.

Android Publisher API v3 `purchases.products.get` / `:consume`, authorised by a service account whose JSON key sits at
`google_service_account_file`; the key is traded for an OAuth token through a signed JWT and the token is cached.
"""

import json
import time
from dataclasses import dataclass
from functools import lru_cache
from typing import Any
from urllib.parse import quote

import httpx
import jwt

from app.config import get_settings

SCOPE = "https://www.googleapis.com/auth/androidpublisher"
API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
TIMEOUT = httpx.Timeout(15.0)
TOKEN_MARGIN_SECONDS = 60

PURCHASED, CANCELLED, PENDING = 0, 1, 2
TEST_PURCHASE = 0  # purchaseType 0: a license tester's free purchase


class GooglePlayError(Exception):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


@dataclass(frozen=True, slots=True)
class ProductPurchase:
    order_id: str
    state: int
    consumed: bool
    account_id: str  # obfuscatedExternalAccountId the app set when it started the purchase
    quantity: int
    is_test: bool


def configured() -> bool:
    settings = get_settings()
    return bool(settings.google_package_name and settings.google_service_account_file)


@lru_cache
def _service_account() -> dict[str, Any]:
    with open(get_settings().google_service_account_file, encoding="utf-8") as file:
        return json.load(file)


_cached_token: tuple[str, float] = ("", 0.0)


async def _access_token(client: httpx.AsyncClient) -> str:
    global _cached_token
    token, expires_at = _cached_token
    if token and expires_at > time.time() + TOKEN_MARGIN_SECONDS:
        return token
    account = _service_account()
    now = int(time.time())
    claims = {"iss": account["client_email"], "scope": SCOPE, "aud": account["token_uri"], "iat": now, "exp": now + 3600}
    assertion = jwt.encode(claims, account["private_key"], algorithm="RS256")
    response = await client.post(
        account["token_uri"], data={"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion}
    )
    if response.status_code != 200:
        raise GooglePlayError("GOOGLE_AUTH_FAILED")
    body = response.json()
    _cached_token = (body["access_token"], time.time() + int(body.get("expires_in", 3600)))
    return _cached_token[0]


def _url(product_id: str, purchase_token: str) -> str:
    package = get_settings().google_package_name
    return f"{API}/{package}/purchases/products/{quote(product_id, safe='')}/tokens/{quote(purchase_token, safe='')}"


async def _call(method: str, url: str) -> httpx.Response:
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            headers = {"Authorization": f"Bearer {await _access_token(client)}"}
            return await client.request(method, url, headers=headers)
    except httpx.HTTPError as exc:
        raise GooglePlayError("GOOGLE_UNAVAILABLE") from exc


async def get_purchase(product_id: str, purchase_token: str) -> ProductPurchase:
    response = await _call("GET", _url(product_id, purchase_token))
    if response.status_code in (400, 404, 410):
        raise GooglePlayError("PURCHASE_NOT_FOUND")
    if response.status_code != 200:
        raise GooglePlayError("GOOGLE_UNAVAILABLE")
    body = response.json()
    return ProductPurchase(
        order_id=str(body.get("orderId") or ""),
        state=int(body.get("purchaseState", CANCELLED)),
        consumed=int(body.get("consumptionState", 0)) == 1,
        account_id=str(body.get("obfuscatedExternalAccountId") or ""),
        quantity=max(1, int(body.get("quantity") or 1)),
        is_test=body.get("purchaseType") == TEST_PURCHASE,
    )


async def consume(product_id: str, purchase_token: str) -> None:
    """Lets the user buy the same pack again; Play refunds a purchase left unconsumed (unacknowledged) for 3 days."""
    response = await _call("POST", _url(product_id, purchase_token) + ":consume")
    if response.status_code not in (200, 204):
        raise GooglePlayError("GOOGLE_CONSUME_FAILED")
