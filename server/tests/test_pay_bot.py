"""The pay bot (@UzaroPay_bot) and the website wallet: menus, Payme, Telegram Stars, TON, card receipts, web sign-in."""

import base64
import uuid

import pytest
from sqlalchemy import select

from app.config import get_settings
from app.models import AppSetting, TelegramLink, WalletTopup
from app.services import pay_bot, telegram_api, ton

pytestmark = pytest.mark.asyncio(loop_scope="session")

HOOK = "/v1/telegram/pay-webhook"
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
TON_WALLET = "UQ" + "A" * 46


@pytest.fixture(autouse=True)
def bot(monkeypatch, tmp_path):
    settings = get_settings()
    monkeypatch.setattr(settings, "pay_bot_token", "999:test-pay-token")
    monkeypatch.setattr(settings, "pay_bot_username", "UzaroPay_bot")
    monkeypatch.setattr(settings, "payme_merchant_id", "merchant123")
    monkeypatch.setattr(settings, "payme_key", "test-payme-key")
    monkeypatch.setattr(settings, "media_dir", str(tmp_path))
    monkeypatch.setattr(settings, "ad_payment_card", "")
    monkeypatch.setattr(settings, "ad_payment_card_holder", "")
    calls: list[tuple[str, dict]] = []

    async def fake_call(method: str, **params):
        calls.append((method, params))
        return {"message_id": 1}

    monkeypatch.setattr(telegram_api, "call", fake_call)
    return calls


async def _rates(session_factory, **values) -> None:
    async with session_factory() as db:
        for key, value in values.items():
            db.add(AppSetting(key=key, value=str(value), updated_by="test"))
        await db.commit()


async def _linked(new_customer, session_factory, telegram_id: int):
    customer = await new_customer()
    async with session_factory() as db:
        db.add(TelegramLink(customer_id=uuid.UUID(customer.id), telegram_user_id=telegram_id))
        await db.commit()
    return customer


async def _send(client, update: dict, secret: str | None = None):
    headers = {"X-Telegram-Bot-Api-Secret-Token": secret or pay_bot.webhook_secret()}
    return await client.post(HOOK, json={"update_id": 1, **update}, headers=headers)


def _message(user_id: int, **fields) -> dict:
    return {"message": {"message_id": 3, "from": {"id": user_id, "is_bot": False, "first_name": "Ali"},
                        "chat": {"id": user_id, "type": "private"}, **fields}}


def _press(user_id: int, data: str) -> dict:
    return {"callback_query": {"id": "cb1", "from": {"id": user_id}, "data": data, "message": {"message_id": 9}}}


def _buttons(calls, method: str = "editMessageText") -> list[dict]:
    markup = [p for m, p in calls if m == method][-1]["reply_markup"]
    return [button for row in markup["inline_keyboard"] for button in row]


def _alert(calls) -> str | None:
    return [p for m, p in calls if m == "answerCallbackQuery"][-1].get("text")


async def _balance(customer) -> int:
    return (await customer.get("/v1/wallet")).json()["balance_uzs"]


async def test_wrong_secret_is_refused_and_unlinked_users_are_told_to_link(client, bot):
    assert (await _send(client, _message(1, text="/start"), secret="wrong")).status_code == 401
    assert (await _send(client, _message(70_001, text="/start"))).status_code == 200
    assert bot[-1][0] == "sendMessage" and "tasdiqlang" in bot[-1][1]["text"]


async def test_menu_lists_packs_and_only_the_configured_methods(client, bot, new_customer, session_factory):
    await _linked(new_customer, session_factory, 70_002)
    await _send(client, _message(70_002, text="/start"))
    assert [b["callback_data"] for b in _buttons(bot, "sendMessage")][:2] == ["a:5000", "a:50000"]

    await _send(client, _press(70_002, "a:50000"))
    assert [b["callback_data"] for b in _buttons(bot)] == ["m:payme:50000", "back"]
    await _rates(session_factory, stars_uzs_per_star=200, ton_uzs_per_ton=40_000, ton_wallet=TON_WALLET, ad_payment_card="8600 1234")
    await _send(client, _press(70_002, "a:50000"))
    labels = [b["text"] for b in _buttons(bot)]
    assert any("250 ⭐" in label for label in labels) and any("1.25 TON" in label for label in labels)
    assert len(labels) == 5

    await _send(client, _press(70_002, "a:777"))
    assert "mavjud emas" in _alert(bot)


async def test_payme_button_opens_a_checkout_for_the_linked_account(client, bot, new_customer, session_factory):
    await _linked(new_customer, session_factory, 70_003)
    await _send(client, _press(70_003, "m:payme:100000"))
    url = _buttons(bot)[0]["url"]
    assert "ac.order_id=" in base64.b64decode(url.rsplit("/", 1)[1]).decode()


async def test_stars_invoice_is_checked_and_credited_once(client, bot, new_customer, session_factory):
    customer = await _linked(new_customer, session_factory, 70_004)
    await _rates(session_factory, stars_uzs_per_star=200)
    await _send(client, _press(70_004, "m:stars:50000"))
    invoice = [p for m, p in bot if m == "sendInvoice"][-1]
    assert invoice["currency"] == "XTR" and invoice["prices"][0]["amount"] == 250

    query = {"id": "q1", "from": {"id": 70_004}, "currency": "XTR", "invoice_payload": invoice["payload"]}
    await _send(client, {"pre_checkout_query": query | {"total_amount": 10}})
    assert bot[-1] == ("answerPreCheckoutQuery", {"pre_checkout_query_id": "q1", "ok": False, "error_message": bot[-1][1]["error_message"]})
    await _send(client, {"pre_checkout_query": query | {"total_amount": 250}})
    assert bot[-1][1]["ok"] is True

    paid = {"currency": "XTR", "total_amount": 250, "invoice_payload": invoice["payload"], "telegram_payment_charge_id": "stxABC"}
    await _send(client, _message(70_004, successful_payment=paid))
    await _send(client, _message(70_004, successful_payment=paid))
    assert await _balance(customer) == 50_000
    history = (await customer.get("/v1/wallet/history")).json()["items"]
    assert [h["method"] for h in history] == ["telegram_stars"]


async def test_ton_payment_is_found_by_its_code_and_credited_once(client, bot, new_customer, session_factory, monkeypatch):
    customer = await _linked(new_customer, session_factory, 70_005)
    await _rates(session_factory, ton_uzs_per_ton=40_000, ton_wallet=TON_WALLET)
    await _send(client, _press(70_005, "m:ton:100000"))
    check = next(b["callback_data"] for b in _buttons(bot) if b.get("callback_data", "").startswith("t:"))
    asked: list[tuple] = []

    async def not_yet(wallet, comment, min_nano):
        asked.append((wallet, comment, min_nano))
        return None

    monkeypatch.setattr(ton, "find_payment", not_yet)
    await _send(client, _press(70_005, check))
    assert "ko'rinmadi" in _alert(bot) and asked == [(TON_WALLET, check[2:], 2_500_000_000)]

    async def found(wallet, comment, min_nano):
        return "txhash1"

    monkeypatch.setattr(ton, "find_payment", found)
    await _send(client, _press(70_005, check))
    await _send(client, _press(70_005, check))
    assert "eskirgan" in _alert(bot)
    assert await _balance(customer) == 100_000


async def test_card_receipt_photo_waits_for_the_admin(client, bot, new_customer, session_factory, monkeypatch):
    customer = await _linked(new_customer, session_factory, 70_006)
    await _send(client, _message(70_006, photo=[{"file_id": "early"}]))
    assert "tanlang" in bot[-1][1]["text"]

    await _rates(session_factory, ad_payment_card="8600 1234 5678 9012", ad_payment_card_holder="UZARO")
    await _send(client, _press(70_006, "m:card:250000"))
    assert "8600 1234 5678 9012" in [p for m, p in bot if m == "editMessageText"][-1]["text"]

    async def fake_download(file_id, limit):
        assert file_id == "big"
        return PNG

    monkeypatch.setattr(telegram_api, "download", fake_download)
    await _send(client, _message(70_006, photo=[{"file_id": "small"}, {"file_id": "big"}]))
    assert "qabul qilindi" in bot[-1][1]["text"]
    async with session_factory() as db:
        topup = await db.scalar(select(WalletTopup).where(WalletTopup.customer_id == uuid.UUID(customer.id)))
    assert topup is not None and topup.amount_uzs == 250_000 and topup.status == "pending"
    assert await _balance(customer) == 0


async def test_website_signs_in_through_the_bot_and_opens_payme(client, bot, new_customer, session_factory):
    customer = await _linked(new_customer, session_factory, 70_007)
    login = (await client.post("/v1/web/login")).json()
    code = login["code"]
    assert login["bot_url"] == f"https://t.me/UzaroPay_bot?start=web_{code}"
    assert (await client.get(f"/v1/web/login/{code}")).json() == {"status": "pending"}

    await _send(client, _message(70_008, text=f"/start web_{code}"))  # not linked: stays pending
    assert (await client.get(f"/v1/web/login/{code}")).json()["status"] == "pending"
    await _send(client, _message(70_007, text=f"/start web_{code}"))
    # The link alone signs nobody in (it may come from someone else): the account owner must press "yes".
    assert (await client.get(f"/v1/web/login/{code}")).json()["status"] == "pending"
    assert _buttons(bot, "sendMessage")[0]["callback_data"] == f"w:{code}"
    await _send(client, _press(70_008, f"w:{code}"))  # not linked: refused
    assert (await client.get(f"/v1/web/login/{code}")).json()["status"] == "pending"
    await _send(client, {"callback_query": {"id": "cb2", "from": {"id": 70_007, "first_name": "Ali"}, "data": f"w:{code}", "message": {"message_id": 9}}})
    session = (await client.get(f"/v1/web/login/{code}")).json()
    assert session["status"] == "ok"
    assert (await client.get(f"/v1/web/login/{code}")).status_code == 404  # spent

    headers = {"X-Wallet-Session": session["token"]}
    wallet = (await client.get("/v1/web/wallet", headers=headers)).json()
    assert wallet["name"] == "Ali" and wallet["balance_uzs"] == 0 and wallet["payme"] is True
    assert (await client.post("/v1/web/payme", json={"amount_uzs": 123}, headers=headers)).status_code == 400
    paid = (await client.post("/v1/web/payme", json={"amount_uzs": 50_000}, headers=headers)).json()
    params = base64.b64decode(paid["checkout_url"].rsplit("/", 1)[1]).decode()
    assert "a=5000000" in params and params.endswith("c=https://uzaromessenger.uz/hamyon.html")
    assert await _balance(customer) == 0

    assert (await client.post("/v1/web/logout", headers=headers)).status_code == 204
    assert (await client.get("/v1/web/wallet", headers=headers)).status_code == 401


async def test_ton_amounts_round_up():
    assert ton.nano_for(100_000, 40_000) == 2_500_000_000
    assert ton.nano_for(1, 3) == 333_333_334
    assert ton.ton_text(2_500_000_000) == "2.5" and ton.ton_text(1_000_000_000) == "1" and ton.ton_text(1) == "0.0001"
