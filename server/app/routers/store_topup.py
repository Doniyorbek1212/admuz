"""Wallet top-up through the stores' own billing, the only way the Play and App Store builds may sell balance.

The app lists the packs (GET /v1/wallet/store-packs), buys one in the store tagged with the customer's
store_account_token, and hands the result over: a Play purchase token to POST /v1/wallet/google-play, a StoreKit 2
signed transaction to POST /v1/wallet/app-store. The balance is credited only after the purchase checks out;
Play purchases are then consumed here, App Store ones are finished by the app.
"""

import asyncio
import hashlib
import logging
import uuid
from typing import Annotated, Any

from fastapi import APIRouter
from pydantic import BaseModel, StringConstraints
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError

from app.config import get_settings
from app.deps import CurrentCustomer, CustomerDep, DbDep, rate_limit
from app.errors import bad_request, forbidden, unavailable
from app.models import WalletEntry
from app.services import app_store, google_play, wallet
from app.services.app_store import AppStoreError
from app.services.audit import audit
from app.services.google_play import GooglePlayError

router = APIRouter(prefix="/v1", tags=["store-topup"])
log = logging.getLogger("app.store_topup")

TOPUP_PACKS_UZS = wallet.TOPUP_PACKS_UZS
# The same product ids in Play Console and App Store Connect (consumables); each credits its pack in so'm whatever
# the local store price.
PRODUCTS = {f"uzaro_topup_{amount}": amount for amount in TOPUP_PACKS_UZS}
VERIFY_PER_HOUR = 30
# Free sandbox balance one account may collect while store_test_purchases is on.
TEST_CREDIT_CAP_UZS = 500_000


class GooglePlayTopupIn(BaseModel):
    product_id: Annotated[str, StringConstraints(min_length=1, max_length=64)]
    purchase_token: Annotated[str, StringConstraints(min_length=10, max_length=4096)]


class AppStoreTopupIn(BaseModel):
    signed_transaction: Annotated[str, StringConstraints(min_length=10, max_length=16384)]


@router.get("/wallet/store-packs")
async def packs(current: CustomerDep) -> dict[str, Any]:
    return {
        "google_play": google_play.configured(),
        "app_store": app_store.configured(),
        # Set on the purchase (Play obfuscatedAccountId / StoreKit appAccountToken): a purchase credits only its buyer.
        "account": str(current.customer.store_account_token),
        "products": [{"product_id": product_id, "amount_uzs": amount} for product_id, amount in PRODUCTS.items()],
    }


async def _test_credits(db: DbDep, customer_id: uuid.UUID) -> int:
    total = await db.scalar(
        select(func.coalesce(func.sum(WalletEntry.delta_uzs), 0)).where(
            WalletEntry.customer_id == customer_id,
            WalletEntry.kind == "topup",
            WalletEntry.reference.like("appstore-test:%") | WalletEntry.reference.like("gplay-test:%"),
        )
    )
    return int(total or 0)


async def _credit(
    db: DbDep, current: CurrentCustomer, *, account_id: str, amount_uzs: int, reference: str, is_test: bool
) -> tuple[bool, int]:
    """Checks the buyer and the test switch, then records the top-up once. Returns (newly credited, so'm)."""
    if account_id != str(current.customer.store_account_token):
        raise forbidden("PURCHASE_OTHER_ACCOUNT")
    if is_test:
        if not get_settings().store_test_purchases:
            raise forbidden("TEST_PURCHASE")
        # Sandbox money is free (App Review, TestFlight, license testers): marked, and capped per account.
        reference = reference.replace(":", "-test:", 1)
        if await _test_credits(db, current.id) >= TEST_CREDIT_CAP_UZS:
            raise forbidden("TEST_PURCHASE_LIMIT")
    if not await wallet.record_topup(db, current.id, amount_uzs, reference):
        return False, amount_uzs
    audit(db, f"customer:{current.id}", "store_topup", reference, amount_uzs=amount_uzs, test=is_test)
    try:
        await db.commit()
    except IntegrityError:
        # The same purchase sent twice at once: the other request credited it.
        await db.rollback()
        return False, amount_uzs
    return True, amount_uzs


async def _result(db: DbDep, current: CurrentCustomer, credited: bool, amount_uzs: int) -> dict[str, Any]:
    return {
        "state": "credited" if credited else "already_credited",
        "amount_uzs": amount_uzs if credited else 0,
        "balance_uzs": await wallet.balance(db, current.id),
    }


@router.post("/wallet/google-play")
async def credit_google_play(body: GooglePlayTopupIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    if not google_play.configured():
        raise unavailable("GOOGLE_PLAY_NOT_CONFIGURED")
    amount = PRODUCTS.get(body.product_id)
    if amount is None:
        raise bad_request("PRODUCT_UNKNOWN")
    await rate_limit(f"storetopup:{current.id}", limit=VERIFY_PER_HOUR, window_seconds=3600)
    try:
        purchase = await google_play.get_purchase(body.product_id, body.purchase_token)
    except GooglePlayError as exc:
        raise (bad_request if exc.code == "PURCHASE_NOT_FOUND" else unavailable)(exc.code) from exc
    if purchase.state == google_play.PENDING:
        return {"state": "pending", "amount_uzs": 0, "balance_uzs": await wallet.balance(db, current.id)}
    if purchase.state != google_play.PURCHASED:
        raise bad_request("PURCHASE_CANCELLED")

    reference = f"gplay:{purchase.order_id or hashlib.sha256(body.purchase_token.encode()).hexdigest()[:40]}"
    credited, credited_uzs = await _credit(
        db, current, account_id=purchase.account_id, amount_uzs=amount * purchase.quantity, reference=reference,
        is_test=purchase.is_test,
    )
    if not purchase.consumed:
        try:
            await google_play.consume(body.product_id, body.purchase_token)
        except GooglePlayError:
            # Already credited; the app re-sends unconsumed purchases when the top-up screen opens, retrying this.
            log.warning("google play consume failed for %s", reference)
    return await _result(db, current, credited, credited_uzs)


@router.post("/wallet/app-store")
async def credit_app_store(body: AppStoreTopupIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    if not app_store.configured():
        raise unavailable("APP_STORE_NOT_CONFIGURED")
    await rate_limit(f"storetopup:{current.id}", limit=VERIFY_PER_HOUR, window_seconds=3600)
    try:
        purchase = await asyncio.to_thread(app_store.verify, body.signed_transaction)
    except AppStoreError as exc:
        raise bad_request(exc.code) from exc
    amount = PRODUCTS.get(purchase.product_id)
    if amount is None:
        raise bad_request("PRODUCT_UNKNOWN")
    if purchase.revoked:
        raise bad_request("PURCHASE_CANCELLED")

    credited, credited_uzs = await _credit(
        db, current, account_id=purchase.account_id, amount_uzs=amount * purchase.quantity,
        reference=f"appstore:{purchase.transaction_id or uuid.uuid4()}", is_test=purchase.is_test,
    )
    return await _result(db, current, credited, credited_uzs)
