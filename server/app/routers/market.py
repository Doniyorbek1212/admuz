"""Online shops: a customer runs shops (the first ones free, further ones paid), lists products with photos and
videos, keeps a warehouse ledger and sees the shop's accounting. Shops go live after admin approval."""

import uuid
from datetime import UTC, datetime, timedelta
from typing import Annotated, Any, Literal

from fastapi import APIRouter, File, Query, UploadFile, status
from pydantic import BaseModel, Field, StringConstraints, model_validator
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.deps import CustomerDep, DbDep, rate_limit
from app.errors import bad_request, conflict, not_found
from app.market import Category, MediaItem, OptionalMediaUrl, Phone, Region, Telegram, movement_out, product_out, shop_out
from app.models import ListingStatus, MediaUpload, Product, Shop, StockKind, StockMovement
from app.uploads import save_receipt

router = APIRouter(prefix="/v1/market", tags=["market"])

MAX_PRODUCTS_PER_SHOP = 500
MAX_SHOPS_PER_CUSTOMER = 10
MAX_MEDIA_PER_PRODUCT = 10
PAGE_SIZE = 50
LOW_STOCK = 3
_OPEN = (ListingStatus.AWAITING_PAYMENT, ListingStatus.PENDING, ListingStatus.APPROVED, ListingStatus.REJECTED)


class ShopIn(BaseModel):
    name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=2, max_length=80)]
    description: Annotated[str, StringConstraints(strip_whitespace=True, max_length=1000)] = ""
    region: Region
    phone: Phone = ""
    telegram: Telegram = ""
    logo_url: OptionalMediaUrl = ""


class ProductIn(BaseModel):
    title: Annotated[str, StringConstraints(strip_whitespace=True, min_length=2, max_length=120)]
    description: Annotated[str, StringConstraints(strip_whitespace=True, max_length=2000)] = ""
    category: Category = ""
    sku: Annotated[str, StringConstraints(strip_whitespace=True, max_length=40)] = ""
    price_uzs: Annotated[int, Field(ge=0, le=10_000_000_000)]
    old_price_uzs: Annotated[int | None, Field(ge=0, le=10_000_000_000)] = None
    media: Annotated[list[MediaItem], Field(max_length=MAX_MEDIA_PER_PRODUCT)] = []
    active: bool = True

    @model_validator(mode="after")
    def _discount_is_higher(self) -> "ProductIn":
        if self.old_price_uzs is not None and self.old_price_uzs <= self.price_uzs:
            self.old_price_uzs = None  # not a discount: drop the crossed-out price
        return self


class NewProductIn(ProductIn):
    initial_stock: Annotated[int, Field(ge=0, le=1_000_000)] = 0


class StockIn(BaseModel):
    kind: StockKind
    quantity: Annotated[int, Field(ge=1, le=1_000_000)]
    # For "adjust" the sign matters (+ found, - lost); for the other kinds the direction comes from the kind.
    direction: Literal[1, -1] = 1
    unit_price_uzs: Annotated[int, Field(ge=0, le=10_000_000_000)] = 0
    note: Annotated[str, StringConstraints(strip_whitespace=True, max_length=200)] = ""


class CloseIn(BaseModel):
    reason: Annotated[str, StringConstraints(strip_whitespace=True, min_length=3, max_length=256)]


# ------------------------------------------------------------------ helpers


async def _own_shop(db: AsyncSession, customer_id: uuid.UUID, shop_id: uuid.UUID) -> Shop:
    shop = await db.get(Shop, shop_id)
    if shop is None or shop.owner_id != customer_id or shop.status == ListingStatus.CLOSED:
        raise not_found("SHOP_NOT_FOUND")
    return shop


async def _own_product(db: AsyncSession, customer_id: uuid.UUID, product_id: uuid.UUID) -> tuple[Product, Shop]:
    row = (
        await db.execute(
            select(Product, Shop).join(Shop, Shop.id == Product.shop_id).where(Product.id == product_id, Shop.owner_id == customer_id)
        )
    ).first()
    if row is None or row[1].status == ListingStatus.CLOSED:
        raise not_found("PRODUCT_NOT_FOUND")
    return row[0], row[1]


async def _check_media_owner(db: AsyncSession, customer_id: uuid.UUID, urls: list[str]) -> None:
    """Uploaded files may only be used by the customer who uploaded them."""
    names = [u.removeprefix("/media/") for u in urls if u.startswith("/media/")]
    if not names:
        return
    owned = set(await db.scalars(select(MediaUpload.name).where(MediaUpload.name.in_(names), MediaUpload.customer_id == customer_id)))
    if owned != set(names):
        raise bad_request("MEDIA_NOT_FOUND")


def _record(db: AsyncSession, product: Product, kind: StockKind, quantity: int, unit_price: int, note: str) -> None:
    if product.stock + quantity < 0:
        raise bad_request("STOCK_NOT_ENOUGH")
    product.stock += quantity
    db.add(StockMovement(shop_id=product.shop_id, product_id=product.id, kind=kind, quantity=quantity, unit_price_uzs=unit_price, note=note))


def _product_counts():
    return select(Product.shop_id, func.count().label("n")).where(Product.active.is_(True)).group_by(Product.shop_id).subquery()


# ------------------------------------------------------------------ public


@router.get("/shops")
async def list_shops(
    current: CustomerDep,
    db: DbDep,
    region: Region,
    q: Annotated[str, StringConstraints(strip_whitespace=True, max_length=60)] = "",
    offset: Annotated[int, Query(ge=0)] = 0,
) -> list[dict[str, Any]]:
    counts = _product_counts()
    stmt = (
        select(Shop, func.coalesce(counts.c.n, 0))
        .outerjoin(counts, counts.c.shop_id == Shop.id)
        .where(Shop.status == ListingStatus.APPROVED, Shop.region == region)
    )
    if q:
        stmt = stmt.where(Shop.name.ilike(f"%{q.replace('%', '').replace('_', '')}%"))
    rows = await db.execute(stmt.order_by(Shop.updated_at.desc()).offset(offset).limit(PAGE_SIZE))
    return [shop_out(shop, product_count=n) for shop, n in rows.all()]


@router.get("/shops/{shop_id}")
async def shop_detail(shop_id: uuid.UUID, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    shop = await db.get(Shop, shop_id)
    if shop is None or (shop.status != ListingStatus.APPROVED and shop.owner_id != current.id):
        raise not_found("SHOP_NOT_FOUND")
    products = await db.scalars(
        select(Product).where(Product.shop_id == shop.id, Product.active.is_(True)).order_by(Product.created_at.desc())
    )
    return shop_out(shop) | {"products": [product_out(p) for p in products]}


# ------------------------------------------------------------------ my shops


@router.get("/me/shops")
async def my_shops(current: CustomerDep, db: DbDep) -> dict[str, Any]:
    counts = select(Product.shop_id, func.count().label("n")).group_by(Product.shop_id).subquery()
    rows = await db.execute(
        select(Shop, func.coalesce(counts.c.n, 0))
        .outerjoin(counts, counts.c.shop_id == Shop.id)
        .where(Shop.owner_id == current.id, Shop.status != ListingStatus.CLOSED)
        .order_by(Shop.created_at)
    )
    shops = [shop_out(shop, product_count=n, private=True) for shop, n in rows.all()]
    settings = get_settings()
    next_price = settings.extra_shop_price_uzs if len(shops) >= settings.shop_free_limit else 0
    return {"shops": shops, "free_limit": settings.shop_free_limit, "next_shop_price_uzs": next_price}


@router.post("/me/shops", status_code=status.HTTP_201_CREATED)
async def create_shop(body: ShopIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    await rate_limit(f"shopcreate:{current.id}", limit=10, window_seconds=3600)
    await _check_media_owner(db, current.id, [body.logo_url])
    count = await db.scalar(select(func.count()).select_from(Shop).where(Shop.owner_id == current.id, Shop.status.in_(_OPEN))) or 0
    if count >= MAX_SHOPS_PER_CUSTOMER:
        raise bad_request("SHOP_LIMIT_REACHED")
    settings = get_settings()
    paid = count >= settings.shop_free_limit
    shop = Shop(
        owner_id=current.id,
        **body.model_dump(),
        price_uzs=settings.extra_shop_price_uzs if paid else 0,
        status=ListingStatus.AWAITING_PAYMENT if paid else ListingStatus.PENDING,
    )
    db.add(shop)
    await db.commit()
    await db.refresh(shop)
    return shop_out(shop, product_count=0, private=True)


@router.get("/me/shops/{shop_id}")
async def my_shop(shop_id: uuid.UUID, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    shop = await _own_shop(db, current.id, shop_id)
    products = list(await db.scalars(select(Product).where(Product.shop_id == shop.id).order_by(Product.created_at.desc())))
    return shop_out(shop, product_count=len(products), private=True) | {"products": [product_out(p, private=True) for p in products]}


@router.put("/me/shops/{shop_id}")
async def update_shop(shop_id: uuid.UUID, body: ShopIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    await rate_limit(f"shopedit:{current.id}", limit=30, window_seconds=3600)
    shop = await _own_shop(db, current.id, shop_id)
    await _check_media_owner(db, current.id, [body.logo_url])
    for field, value in body.model_dump().items():
        setattr(shop, field, value)
    # Any change is reviewed again before it is shown to others; an unpaid slot stays unpaid.
    if shop.status != ListingStatus.AWAITING_PAYMENT:
        shop.status = ListingStatus.PENDING
    shop.reject_reason = None
    await db.commit()
    await db.refresh(shop)
    return shop_out(shop, private=True)


@router.post("/me/shops/{shop_id}/receipt")
async def shop_receipt(shop_id: uuid.UUID, current: CustomerDep, db: DbDep, file: Annotated[UploadFile, File()]) -> dict[str, Any]:
    await rate_limit(f"receipt:{current.id}", limit=20, window_seconds=3600)
    shop = await _own_shop(db, current.id, shop_id)
    if shop.price_uzs == 0:
        raise conflict("SHOP_IS_FREE")
    if shop.status == ListingStatus.APPROVED:
        raise conflict("SHOP_ALREADY_APPROVED")
    shop.receipt_path = await save_receipt(file)
    shop.status = ListingStatus.PENDING
    shop.reject_reason = None
    await db.commit()
    return shop_out(shop, private=True)


@router.post("/me/shops/{shop_id}/close-request")
async def request_close(shop_id: uuid.UUID, body: CloseIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    shop = await _own_shop(db, current.id, shop_id)
    shop.close_requested_at = datetime.now(UTC)
    shop.close_reason = body.reason
    await db.commit()
    return shop_out(shop, private=True)


@router.delete("/me/shops/{shop_id}/close-request")
async def cancel_close(shop_id: uuid.UUID, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    shop = await _own_shop(db, current.id, shop_id)
    shop.close_requested_at = None
    shop.close_reason = None
    await db.commit()
    return shop_out(shop, private=True)


# ------------------------------------------------------------------ products


@router.post("/me/shops/{shop_id}/products", status_code=status.HTTP_201_CREATED)
async def add_product(shop_id: uuid.UUID, body: NewProductIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    await rate_limit(f"product:{current.id}", limit=120, window_seconds=3600)
    shop = await _own_shop(db, current.id, shop_id)
    await _check_media_owner(db, current.id, [m.url for m in body.media])
    count = await db.scalar(select(func.count()).select_from(Product).where(Product.shop_id == shop.id)) or 0
    if count >= MAX_PRODUCTS_PER_SHOP:
        raise bad_request("PRODUCT_LIMIT_REACHED")
    data = body.model_dump(exclude={"initial_stock"})
    product = Product(shop_id=shop.id, **data, stock=0)
    db.add(product)
    await db.flush()
    if body.initial_stock:
        _record(db, product, StockKind.IN, body.initial_stock, 0, "")
    await db.commit()
    await db.refresh(product)
    return product_out(product, private=True)


@router.put("/me/products/{product_id}")
async def update_product(product_id: uuid.UUID, body: ProductIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    product, _ = await _own_product(db, current.id, product_id)
    await _check_media_owner(db, current.id, [m.url for m in body.media])
    for field, value in body.model_dump().items():
        setattr(product, field, value)
    await db.commit()
    await db.refresh(product)
    return product_out(product, private=True)


@router.delete("/me/products/{product_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_product(product_id: uuid.UUID, current: CustomerDep, db: DbDep) -> None:
    product, _ = await _own_product(db, current.id, product_id)
    await db.delete(product)
    await db.commit()


# ------------------------------------------------------------------ warehouse and accounting


@router.post("/me/products/{product_id}/stock")
async def move_stock(product_id: uuid.UUID, body: StockIn, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    product, _ = await _own_product(db, current.id, product_id)
    sign = {StockKind.IN: 1, StockKind.RETURN: 1, StockKind.SALE: -1, StockKind.ADJUST: body.direction}[body.kind]
    unit_price = body.unit_price_uzs or (product.price_uzs if body.kind in (StockKind.SALE, StockKind.RETURN) else 0)
    _record(db, product, body.kind, sign * body.quantity, unit_price, body.note)
    await db.commit()
    await db.refresh(product)
    return product_out(product, private=True)


@router.get("/me/shops/{shop_id}/stock")
async def stock_history(
    shop_id: uuid.UUID,
    current: CustomerDep,
    db: DbDep,
    limit: Annotated[int, Query(ge=1, le=200)] = 100,
    before_id: Annotated[int | None, Query(ge=1)] = None,
) -> list[dict[str, Any]]:
    shop = await _own_shop(db, current.id, shop_id)
    stmt = (
        select(StockMovement, Product.title)
        .join(Product, Product.id == StockMovement.product_id)
        .where(StockMovement.shop_id == shop.id)
    )
    if before_id:
        stmt = stmt.where(StockMovement.id < before_id)
    rows = await db.execute(stmt.order_by(StockMovement.id.desc()).limit(limit))
    return [movement_out(m, title) for m, title in rows.all()]


@router.get("/me/shops/{shop_id}/stats")
async def shop_stats(shop_id: uuid.UUID, current: CustomerDep, db: DbDep) -> dict[str, Any]:
    shop = await _own_shop(db, current.id, shop_id)
    products = (
        await db.execute(
            select(
                func.count(),
                func.count().filter(Product.active.is_(True)),
                func.coalesce(func.sum(Product.stock), 0),
                func.coalesce(func.sum(Product.stock * Product.price_uzs), 0),
            ).where(Product.shop_id == shop.id)
        )
    ).one()

    since = datetime.now(UTC) - timedelta(days=30)
    # Sales are negative quantities, returns positive: revenue = -(quantity * unit price).
    revenue = -StockMovement.quantity * StockMovement.unit_price_uzs
    sold = -StockMovement.quantity  # net units: sales minus returns
    is_trade = StockMovement.kind.in_((StockKind.SALE, StockKind.RETURN))
    sales = (
        await db.execute(
            select(
                func.coalesce(func.sum(revenue).filter(is_trade), 0),
                func.coalesce(func.sum(sold).filter(is_trade), 0),
                func.coalesce(func.sum(revenue).filter(is_trade, StockMovement.created_at >= since), 0),
                func.coalesce(func.sum(sold).filter(is_trade, StockMovement.created_at >= since), 0),
            ).where(StockMovement.shop_id == shop.id)
        )
    ).one()
    low = await db.scalars(
        select(Product).where(Product.shop_id == shop.id, Product.active.is_(True), Product.stock <= LOW_STOCK).order_by(Product.stock).limit(20)
    )
    return {
        "products": products[0],
        "active_products": products[1],
        "stock_units": int(products[2]),
        "stock_value_uzs": int(products[3]),
        "revenue_total_uzs": int(sales[0]),
        "units_sold_total": int(sales[1]),
        "revenue_30d_uzs": int(sales[2]),
        "units_sold_30d": int(sales[3]),
        "low_stock": [{"id": str(p.id), "title": p.title, "stock": p.stock} for p in low],
    }
