import uuid
from datetime import UTC, datetime

from app.models import GiftItem, SentGift
from app.routers.gifts import sent_out

SENDER, RECIPIENT, STRANGER = 111, 222, 333


def _sent(*, anonymous: bool = False, sender_hidden: bool = False) -> SentGift:
    return SentGift(
        id=uuid.uuid4(), gift_id=uuid.uuid4(), sender_customer_id=uuid.uuid4(), sender_telegram_id=SENDER,
        recipient_telegram_id=RECIPIENT, text="", price_uzs=1000, hidden=False, anonymous=anonymous,
        sender_hidden=sender_hidden, created_at=datetime.now(UTC),
    )


def _gift() -> GiftItem:
    return GiftItem(id=uuid.uuid4(), title="Rose", price_uzs=1000, animation="a.webp")


def test_sender_shown_to_everyone_by_default() -> None:
    assert sent_out(_sent(), _gift(), STRANGER)["sender_telegram_id"] == SENDER
    assert sent_out(_sent(), _gift(), None)["sender_telegram_id"] == SENDER


def test_anonymous_sender_known_only_to_the_two_involved() -> None:
    sent = _sent(anonymous=True)
    assert sent_out(sent, _gift(), STRANGER)["sender_telegram_id"] is None
    assert sent_out(sent, _gift(), None)["sender_telegram_id"] is None
    assert sent_out(sent, _gift(), RECIPIENT)["sender_telegram_id"] == SENDER
    assert sent_out(sent, _gift(), SENDER)["sender_telegram_id"] == SENDER


def test_recipient_can_hide_the_sender_from_profile_visitors() -> None:
    sent = _sent(sender_hidden=True)
    assert sent_out(sent, _gift(), STRANGER)["sender_telegram_id"] is None
    assert sent_out(sent, _gift(), RECIPIENT)["sender_telegram_id"] == SENDER
