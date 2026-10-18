"""Shared rules for the marketplace and hub ads: regions, URL and text validation, serializers."""

from typing import Annotated, Any, Literal

from pydantic import AfterValidator, BaseModel, StringConstraints

from app.models import AdCampaign, CustomerProfile, Product, Shop, StockMovement

# Regions of Uzbekistan as the app shows them; ads and shops are targeted by these exact names.
REGIONS = (
    "Toshkent",
    "Toshkent viloyati",
    "Andijon",
    "Farg'ona",
    "Namangan",
    "Samarqand",
    "Buxoro",
    "Navoiy",
    "Qashqadaryo",
    "Surxondaryo",
    "Jizzax",
    "Sirdaryo",
    "Xorazm",
    "Qoraqalpog'iston",
)

# Product categories, as keys the app translates.
CATEGORIES = (
    "electronics",
    "phones",
    "clothes",
    "shoes",
    "beauty",
    "home",
    "kitchen",
    "kids",
    "food",
    "flowers",
    "sport",
    "auto",
    "books",
    "health",
    "other",
)


def _known_region(value: str) -> str:
    if value not in REGIONS:
        raise ValueError("unknown region")
    return value


def _known_category(value: str) -> str:
    if value and value not in CATEGORIES:
        raise ValueError("unknown category")
    return value


Region = Annotated[str, AfterValidator(_known_region)]
Category = Annotated[str, AfterValidator(_known_category)]
# Only https links: the app loads them directly, so no plain-http (or javascript:/data:) URLs.
HttpsUrl = Annotated[str, StringConstraints(strip_whitespace=True, max_length=500, pattern=r"^https://[^\s<>\"']+$")]
OptionalHttpsUrl = Annotated[str, StringConstraints(strip_whitespace=True, max_length=500, pattern=r"^(https://[^\s<>\"']+)?$")]
# A product photo/video: an upload on this server ("/media/<name>") or an external https link.
MediaUrl = Annotated[
    str,
    StringConstraints(strip_whitespace=True, max_length=500, pattern=r"^(https://[^\s<>\"']+|/media/[0-9a-f-]{36}\.(jpg|png|webp|mp4))$"),
]
OptionalMediaUrl = Annotated[
    str,
    StringConstraints(strip_whitespace=True, max_length=500, pattern=r"^(https://[^\s<>\"']+|/media/[0-9a-f-]{36}\.(jpg|png|webp|mp4))?$"),
]
Telegram = Annotated[str, StringConstraints(strip_whitespace=True, pattern=r"^([A-Za-z][A-Za-z0-9_]{3,31})?$")]
Phone = Annotated[str, StringConstraints(strip_whitespace=True, pattern=r"^(\+?[0-9 ()-]{7,20})?$")]


class MediaItem(BaseModel):
    type: Literal["image", "video"]
    url: MediaUrl


def shop_out(shop: Shop, *, product_count: int | None = None, private: bool = False) -> dict[str, Any]:
    out: dict[str, Any] = {
        "id": str(shop.id),
        "name": shop.name,
        "description": shop.description,
        "region": shop.region,
        "phone": shop.phone,
        "telegram": shop.telegram,
        "logo_url": shop.logo_url,
    }
    if product_count is not None:
        out["product_count"] = product_count
    if private:
        out |= {
            "status": shop.status.value,
            "reject_reason": shop.reject_reason,
            "price_uzs": shop.price_uzs,
            "has_receipt": shop.receipt_path is not None,
            "close_requested": shop.close_requested_at is not None,
            "close_reason": shop.close_reason,
            "created_at": shop.created_at.isoformat() if shop.created_at else None,
        }
    return out


def product_out(product: Product, *, private: bool = False) -> dict[str, Any]:
    media = list(product.media or [])
    cover = next((m["url"] for m in media if m.get("type") == "image"), "")
    out: dict[str, Any] = {
        "id": str(product.id),
        "shop_id": str(product.shop_id),
        "title": product.title,
        "description": product.description,
        "category": product.category,
        "price_uzs": product.price_uzs,
        "old_price_uzs": product.old_price_uzs,
        "media": media,
        "image_url": cover,
        "stock": product.stock,
        "active": product.active,
    }
    if private:
        out["sku"] = product.sku
    return out


def movement_out(movement: StockMovement, product_title: str) -> dict[str, Any]:
    return {
        "id": movement.id,
        "product_id": str(movement.product_id),
        "product_title": product_title,
        "kind": movement.kind.value,
        "quantity": movement.quantity,
        "unit_price_uzs": movement.unit_price_uzs,
        "note": movement.note,
        "created_at": movement.created_at.isoformat() if movement.created_at else None,
    }


def profile_out(profile: CustomerProfile | None) -> dict[str, Any] | None:
    if profile is None:
        return None
    return {"first_name": profile.first_name, "last_name": profile.last_name, "username": profile.username, "phone": profile.phone}


def ad_out(ad: AdCampaign, *, private: bool = False) -> dict[str, Any]:
    out: dict[str, Any] = {
        "id": str(ad.id),
        "title": ad.title,
        "text": ad.text,
        "media_type": ad.media_type,
        "media_url": ad.media_url,
        "link_url": ad.link_url,
    }
    if private:
        out |= {
            "regions": ad.regions,
            "days": ad.days,
            "price_uzs": ad.price_uzs,
            "status": ad.status.value,
            "has_receipt": ad.receipt_path is not None,
            "reject_reason": ad.reject_reason,
            "starts_at": ad.starts_at.isoformat() if ad.starts_at else None,
            "ends_at": ad.ends_at.isoformat() if ad.ends_at else None,
            "created_at": ad.created_at.isoformat() if ad.created_at else None,
        }
    return out
