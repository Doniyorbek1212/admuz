"""Shop orders: a buyer checks out one shop's part of the cart, the seller takes it from new to delivered.

Prices and stock always come from the server. Placing an order takes the goods out of the warehouse (a sale in the
shop's ledger, so its accounting counts it); cancelling puts them back (a return). The buyer pays the seller on
delivery or pickup, and both sides get a Telegram message from the pay bot when they have linked their account.
"""

import uuid
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Query
from pydantic import BaseModel, Field, StringConstraints, model_validator
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.deps import CustomerDep, DbDep, rate_limit
from app.errors import bad_request, conflict, not_found
from app.models import ListingStatus, Order, OrderStatus, Product, Shop, StockKind, StockMovement
from app.services import pay_notify

router = APIRouter(prefix="/v1/market", tags=["market"])

MAX_LINES = 50
MAX_QUANTITY = 99
PAGE = 100

# What the seller may do next from each state; the buyer may only cancel a new order.
NEXT = {
    OrderStatus.NEW: {OrderStatus.ACCEPTED, OrderStatus.CANCELLED},
    OrderStatus.ACCEPTED: {OrderStatus.SHIPPED, OrderStatus.CANCELLED},
    OrderStatus.SHIPPED: {OrderStatus.DELIVERED, OrderStatus.CANCELLED},
    OrderStatus.DELIVERED: set(),
    OrderStatus.CANCELLED: set(),
}
STATUS_TEXT = {
    OrderStatus.ACCEPTED: "✅ qabul qilindi",
    OrderStatus.SHIPPED: "🚚 yo'lga chiqdi",
    OrderStatus.DELIVERED: "📦 yetkazildi",
    OrderStatus.CANCELLED: "❌ bekor qilindi",
}

Text = Annotated[str, StringConstraints(strip_whitespace=True, max_length=500)]


class LineIn(BaseModel):
    product_id: uuid.UUID
    quantity: Annotated[int, Field(ge=1, le=MAX_QUANTITY)]


class OrderIn(BaseModel):
    shop_id: uuid.UUID
    items: Annotated[list[LineIn], Field(min_length=1, max_length=MAX_LINES)]
    delivery: Literal["delivery", "pickup"]
    name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=2, max_length=80)]
    phone: Annotated[str, StringConstraints(strip_whitespace=True, pattern=r"^\+?[0-9 ()-]{7,20}$")]
    address: Annotated[str, StringConstraints(strip_whitespace=True, max_length=300)] = ""
    comment: Text = ""

    @model_validator(mode="after")
    def _check(self) -> "OrderIn":
        if len({line.product_id for line in self.items}) != len(self.items):
            raise ValueError("each product once")
        if self.delivery == "delivery" and len(self.address) < 5:
            raise ValueError("a delivery needs an address")
        return self


class StatusIn(BaseModel):
    status: Literal["accepted", "shipped", "delivered", "cancelled"]
    reason: Annotated[str, StringConstraints(strip_whitespace=True, max_length=256)] = ""


class CancelIn(BaseModel):
    reason: Annotated[str, StringConstraints(strip_whitespace=True, max_length=256)] = ""


def order_out(order: Order, shop: Shop, *, seller: bool = False) -> dict[str, Any]:
    out: dict[str, Any] = {
        "id": str(order.id),
        "number": order.id.hex[:6].upper(),
        "status": order.status.value,
        "items": order.items,
        "total_uzs": order.total_uzs,
        "delivery": order.delivery,
        "name": order.name,
        "phone": order.phone,
        "address": order.address,
        "comment": order.comment,
        "cancel_reason": order.cancel_reason,
        "created_at": order.created_at.isoformat() if order.created_at else None,
        "updated_at": order.updated_at.isoformat() if order.updated_at else None,
        "shop": {"id": str(shop.id), "name": shop.name, "logo_url": shop.logo_url, "phone": shop.phone, "telegram": shop.telegram},
    }
    if seller:
        out["next"] = sorted(s.value for s in NEXT[order.status])
    return out


def _move(db: AsyncSession, product: Product, kind: StockKind, quantity: int, unit_price: int, order: Order) -> None:
    product.stock += quantity
    db.add(StockMovement(shop_id=product.shop_id, product_id=product.id, kind=kind, quantity=quantity, unit_price_uzs=unit_price,
                         note=f"#{order.id.hex[:6].upper()}"))


async def _restock(db: AsyncSession, order: Order) -> None:
    """A cancelled order's goods back into the warehouse (products deleted since are skipped)."""
    ids = [uuid.UUID(line["product_id"]) for line in order.items]
    products = {p.id: p for p in await db.scalars(select(Product).where(Product.id.in_(ids)).with_for_update())}
    for line in order.items:
        if (product := products.get(uuid.UUID(line["product_id"]))) is not None:
            _move(db, product, StockKind.RETURN, line["quantity"], line["price_uzs"], order)


def _summary(order: Order) -> str:
    lines = "\n".join(f"• {line['title']} × {line['quantity']}" for line in order.items[:10])
    return f"{lines}\nJami: {pay_notify.som(order.total_uzs)}"


# ------------------------------------------------------------------ buyer


@router.post("/orders", status_code=201)
async def place_order(body: OrderIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    await rate_limit(f"order:{current.id}", limit=30, window_seconds=3600)
    shop = await db.get(Shop, body.shop_id)
    if shop is None or shop.status != ListingStatus.APPROVED:
        raise not_found("SHOP_NOT_FOUND")
    ids = [line.product_id for line in body.items]
    # Locked so two buyers cannot both take the last unit.
    products = {
        p.id: p
        for p in await db.scalars(
            select(Product).where(Product.id.in_(ids), Product.shop_id == shop.id, Product.active.is_(True)).with_for_update()
        )
    }
    items: list[dict[str, Any]] = []
    for line in body.items:
        product = products.get(line.product_id)
        if product is None:
            raise not_found("PRODUCT_NOT_FOUND")
        if product.stock < line.quantity:
            raise conflict("STOCK_NOT_ENOUGH", product.title)
        cover = next((m["url"] for m in product.media or [] if m.get("type") == "image"), "")
        items.append({"product_id": str(product.id), "title": product.title, "price_uzs": product.price_uzs,
                      "quantity": line.quantity, "image_url": cover})
    order = Order(
        id=uuid.uuid4(), shop_id=shop.id, buyer_id=current.id, status=OrderStatus.NEW, items=items,
        total_uzs=sum(i["price_uzs"] * i["quantity"] for i in items),
        **body.model_dump(include={"delivery", "name", "phone", "address", "comment"}),
    )
    db.add(order)
    for line in body.items:
        product = products[line.product_id]
        _move(db, product, StockKind.SALE, -line.quantity, product.price_uzs, order)
    await db.commit()
    await db.refresh(order)
    how = "yetkazib berish" if order.delivery == "delivery" else "olib ketish"
    await pay_notify.send_later(db, shop.owner_id, f"🛍 «{shop.name}» do'koniga yangi buyurtma #{order.id.hex[:6].upper()} ({how})\n"
                                                    f"{_summary(order)}\n{order.name}, {order.phone}")
    return order_out(order, shop)


@router.get("/orders")
async def my_orders(current: CustomerDep, db: DbDep) -> list[dict[str, Any]]:
    rows = await db.execute(
        select(Order, Shop).join(Shop, Shop.id == Order.shop_id).where(Order.buyer_id == current.id).order_by(Order.created_at.desc()).limit(PAGE)
    )
    return [order_out(order, shop) for order, shop in rows.all()]


@router.post("/orders/{order_id}/cancel")
async def cancel_order(order_id: uuid.UUID, body: CancelIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    order = await db.scalar(select(Order).where(Order.id == order_id, Order.buyer_id == current.id).with_for_update())
    if order is None:
        raise not_found("ORDER_NOT_FOUND")
    if order.status != OrderStatus.NEW:
        raise conflict("ORDER_ALREADY_ACCEPTED")
    order.status = OrderStatus.CANCELLED
    order.cancel_reason = body.reason or None
    await _restock(db, order)
    await db.commit()
    await db.refresh(order)
    shop = await db.get(Shop, order.shop_id)
    await pay_notify.send_later(db, shop.owner_id, f"❌ Buyurtma #{order.id.hex[:6].upper()} xaridor tomonidan bekor qilindi.")
    return order_out(order, shop)


# ------------------------------------------------------------------ seller


@router.get("/me/shops/{shop_id}/orders")
async def shop_orders(
    shop_id: uuid.UUID,
    current: CustomerDep,
    db: DbDep,
    state: Annotated[Literal["active", "done"], Query()] = "active",
) -> list[dict[str, Any]]:
    """[active]: new, accepted and shipped orders (newest first); [done]: delivered and cancelled ones."""
    shop = await db.get(Shop, shop_id)
    if shop is None or shop.owner_id != current.id:
        raise not_found("SHOP_NOT_FOUND")
    done = (OrderStatus.DELIVERED, OrderStatus.CANCELLED)
    where = Order.status.in_(done) if state == "done" else Order.status.not_in(done)
    orders = await db.scalars(select(Order).where(Order.shop_id == shop.id, where).order_by(Order.created_at.desc()).limit(PAGE))
    return [order_out(order, shop, seller=True) for order in orders]


@router.post("/me/orders/{order_id}/status")
async def set_status(order_id: uuid.UUID, body: StatusIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    row = (
        await db.execute(
            select(Order, Shop).join(Shop, Shop.id == Order.shop_id).where(Order.id == order_id, Shop.owner_id == current.id).with_for_update(of=Order)
        )
    ).first()
    if row is None:
        raise not_found("ORDER_NOT_FOUND")
    order, shop = row
    target = OrderStatus(body.status)
    if target not in NEXT[order.status]:
        raise conflict("ORDER_STATUS_INVALID")
    if target == OrderStatus.CANCELLED:
        if not body.reason:
            raise bad_request("REASON_REQUIRED")
        order.cancel_reason = body.reason
        await _restock(db, order)
    order.status = target
    await db.commit()
    await db.refresh(order)
    text = f"🛍 «{shop.name}»: buyurtmangiz #{order.id.hex[:6].upper()} {STATUS_TEXT[target]}."
    if target == OrderStatus.CANCELLED:
        text += f"\nSabab: {order.cancel_reason}"
    await pay_notify.send_later(db, order.buyer_id, text)
    return order_out(order, shop, seller=True)


async def new_order_counts(db: AsyncSession, shop_ids: list[uuid.UUID]) -> dict[uuid.UUID, int]:
    """New (not yet accepted) orders per shop, for the seller's badges."""
    if not shop_ids:
        return {}
    rows = await db.execute(
        select(Order.shop_id, func.count()).where(Order.shop_id.in_(shop_ids), Order.status == OrderStatus.NEW).group_by(Order.shop_id)
    )
    return dict(rows.all())
