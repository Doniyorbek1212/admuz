"""App Store (StoreKit 2) consumables, the wallet top-up packs: verify the signed transaction the device hands over.

Apple's own library checks the x5c chain up to Apple Root CA - G3 (app/apple_roots, SHA-256 63:34:3A:BF:...:91:79),
the signature, the bundle id and the environment; online checks also ask OCSP whether a certificate was revoked.
Consumables have no server-side "consume": the app finishes the transaction once the balance is credited.
"""

import uuid
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier, VerificationException, VerificationStatus

from app.config import get_settings

ROOTS_DIR = Path(__file__).resolve().parent.parent / "apple_roots"


class AppStoreError(Exception):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


@dataclass(frozen=True, slots=True)
class AppStorePurchase:
    transaction_id: str
    product_id: str
    account_id: str  # appAccountToken the app set when it started the purchase, lower-case
    quantity: int
    revoked: bool  # refunded or taken back by Apple
    is_test: bool  # sandbox / TestFlight: nobody paid


def configured() -> bool:
    settings = get_settings()
    return bool(settings.apple_bundle_id and settings.apple_app_id)


@lru_cache
def _verifier(environment: Environment) -> SignedDataVerifier:
    settings = get_settings()
    roots = [path.read_bytes() for path in sorted(ROOTS_DIR.glob("*.cer"))]
    return SignedDataVerifier(roots, True, environment, settings.apple_bundle_id, settings.apple_app_id)


def _account(token: str | None) -> str:
    try:
        return str(uuid.UUID(token or ""))
    except ValueError:
        return ""


def verify(signed_transaction: str) -> AppStorePurchase:
    """Blocking (OCSP over the network): call it in a thread."""
    is_test = False
    try:
        payload = _verifier(Environment.PRODUCTION).verify_and_decode_signed_transaction(signed_transaction)
    except VerificationException as exc:
        if exc.status != VerificationStatus.INVALID_ENVIRONMENT:
            raise AppStoreError("PURCHASE_INVALID") from exc
        try:
            payload = _verifier(Environment.SANDBOX).verify_and_decode_signed_transaction(signed_transaction)
        except VerificationException as sandbox_exc:
            raise AppStoreError("PURCHASE_INVALID") from sandbox_exc
        is_test = True
    return AppStorePurchase(
        transaction_id=str(payload.transactionId or ""),
        product_id=str(payload.productId or ""),
        account_id=_account(payload.appAccountToken),
        quantity=max(1, payload.quantity or 1),
        revoked=payload.revocationDate is not None,
        is_test=is_test,
    )
