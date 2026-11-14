"""Interest learning for hub ads.

What a customer opens in the hub (a category, a place, a shop, the movies...) and which ads they tap add weight to
topics; weights fade with a configurable half-life, so the profile follows what the customer cares about now. Ads
carry topics too, and the active-ads list is ordered by how well an ad's topics match the viewer's profile, mixed
with a random share so new ads and new interests still get seen.

Only in-app hub actions are used: never Telegram chats, contacts or messages.
"""

import random
import re
import uuid
from collections.abc import Iterable, Sequence
from datetime import UTC, datetime

from sqlalchemy import delete, func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import AdCampaign, CustomerInterest

# Hub place categories first (same keys as PlaceCategory and the app's tiles), then wider shopping topics.
TOPICS: tuple[str, ...] = (
    "taxi", "pharmacy", "hotel", "doctor", "car_service", "bank", "travel", "food",
    "shops", "movies", "music", "games", "gifts",
    "tech", "fashion", "beauty", "education", "real_estate", "sport", "kids",
)
MAX_AD_TOPICS = 3

# How much one action says about an interest.
SIGNAL_WEIGHTS: dict[str, float] = {"open": 1.0, "view": 0.5, "search": 1.0, "ad_click": 3.0}
# A score never grows past this, so one obsessive day cannot pin a topic for months.
MAX_SCORE = 50.0
# Even at 100% interest weight a non-matching paid ad keeps this relative chance of being shown first.
MIN_SHARE = 0.05

# Lower-case word stems (Uzbek Latin, Russian, English) per topic for guessing an ad's topics from its text.
_KEYWORDS: dict[str, tuple[str, ...]] = {
    "taxi": ("taksi", "taxi", "такси", "yo'lovchi", "transfer"),
    "pharmacy": ("dorixona", "dori", "аптек", "лекарств", "pharm", "vitamin"),
    "hotel": ("mehmonxona", "hotel", "отел", "гостиниц", "hostel", "xostel"),
    "doctor": ("shifokor", "klinika", "clinic", "врач", "клиник", "stomatolog", "стоматолог", "tibbiy", "doctor"),
    "car_service": ("avto", "usta", "servis", "шиномонтаж", "автосервис", "ремонт авто", "moy almashtirish", "car "),
    "bank": ("bank", "банк", "kredit", "кредит", "ipoteka", "ипотек", "karta", "to'lov", "omonat", "вклад"),
    "travel": ("sayohat", "tur ", "туризм", "путешеств", "travel", "aviabilet", "авиабилет", "viza", "umra", "haj"),
    "food": (
        "taom", "osh", "kafe", "cafe", "restoran", "ресторан", "кафе", "pizza", "пицц", "burger", "lavash",
        "yetkazib", "доставк", "food", "fastfood", "somsa",
    ),
    "shops": ("do'kon", "magazin", "магазин", "chegirma", "скидк", "aksiya", "акция", "sale", "savdo", "market"),
    "movies": ("kino", "film", "фильм", "кино", "serial", "сериал", "movie"),
    "music": ("musiqa", "music", "музык", "konsert", "концерт", "qo'shiq"),
    "games": ("o'yin", "game", "игр", "pubg", "steam", "playstation", "xbox"),
    "gifts": ("sovg'a", "gift", "подар", "gul", "цвет", "flower", "tort", "торт"),
    "tech": (
        "telefon", "smartfon", "смартфон", "phone", "iphone", "samsung", "xiaomi", "noutbuk", "ноутбук", "laptop",
        "kompyuter", "компьютер", "texnika", "техник", "gadjet",
    ),
    "fashion": ("kiyim", "одежд", "fashion", "poyabzal", "обув", "ko'ylak", "платье", "brend", "moda", "мода"),
    "beauty": ("go'zallik", "salon", "салон", "kosmetik", "косметик", "parfyum", "парфюм", "sartarosh", "барбер", "barber", "manikyur", "маникюр"),
    "education": ("kurs", "курс", "o'quv", "ta'lim", "образован", "ingliz tili", "english", "repetitor", "репетитор", "maktab", "universitet", "it academy"),
    "real_estate": ("kvartira", "квартир", "uy-joy", "uy sotiladi", "ijara", "аренд", "недвижим", "novostroyka", "новострой", "yer sotiladi"),
    "sport": ("sport", "спорт", "fitnes", "фитнес", "zal", "trenajor", "futbol", "футбол", "boks", "yoga", "йога"),
    "kids": ("bolalar", "детск", "детей", "kids", "o'yinchoq", "игрушк", "bog'cha", "садик"),
}


def guess_topics(*texts: str) -> list[str]:
    """Topics whose keywords appear in the ad's title and text, best match first, at most MAX_AD_TOPICS."""
    blob = " " + re.sub(r"\s+", " ", " ".join(texts).lower().replace("’", "'").replace("ʻ", "'")) + " "
    hits = {topic: sum(blob.count(word) for word in words) for topic, words in _KEYWORDS.items()}
    ranked = sorted((t for t, n in hits.items() if n), key=lambda t: (-hits[t], TOPICS.index(t)))
    return ranked[:MAX_AD_TOPICS]


def clean_topics(topics: Iterable[str]) -> list[str]:
    """Known topics only, without duplicates, in TOPICS order, at most MAX_AD_TOPICS."""
    wanted = set(topics)
    return [t for t in TOPICS if t in wanted][:MAX_AD_TOPICS]


def _decay_factor(seconds: float, half_life_days: int) -> float:
    return 0.5 ** (max(seconds, 0.0) / (max(half_life_days, 1) * 86400))


async def record_signals(db: AsyncSession, customer_id: uuid.UUID, signals: Sequence[tuple[str, str]], half_life_days: int) -> None:
    """Adds (topic, kind) signals to the customer's profile, fading the old score first. Unknown topics are ignored."""
    gains: dict[str, float] = {}
    for topic, kind in signals:
        if topic in TOPICS and kind in SIGNAL_WEIGHTS:
            gains[topic] = gains.get(topic, 0.0) + SIGNAL_WEIGHTS[kind]
    if not gains:
        return
    seconds = func.extract("epoch", func.now() - CustomerInterest.updated_at)
    faded = CustomerInterest.score * func.power(0.5, seconds / (max(half_life_days, 1) * 86400))
    for topic, gain in gains.items():
        stmt = insert(CustomerInterest).values(customer_id=customer_id, topic=topic, score=min(gain, MAX_SCORE))
        stmt = stmt.on_conflict_do_update(
            index_elements=[CustomerInterest.customer_id, CustomerInterest.topic],
            set_={"score": func.least(faded + stmt.excluded.score, MAX_SCORE), "updated_at": func.now()},
        )
        await db.execute(stmt)


async def load_profile(db: AsyncSession, customer_id: uuid.UUID, half_life_days: int) -> dict[str, float]:
    """The customer's current (faded) score per topic."""
    now = datetime.now(UTC)
    rows = await db.scalars(select(CustomerInterest).where(CustomerInterest.customer_id == customer_id))
    return {r.topic: r.score * _decay_factor((now - r.updated_at).total_seconds(), half_life_days) for r in rows}


async def forget(db: AsyncSession, customer_id: uuid.UUID) -> None:
    await db.execute(delete(CustomerInterest).where(CustomerInterest.customer_id == customer_id))


def affinity(ad_topics: Sequence[str], profile: dict[str, float]) -> float:
    """0..1: how strongly the viewer cares about the ad's best-matching topic, relative to their top interest."""
    top = max(profile.values(), default=0.0)
    if top <= 0 or not ad_topics:
        return 0.0
    return max(profile.get(t, 0.0) for t in ad_topics) / top


def rank_ads(
    ads: Sequence[AdCampaign],
    profile: dict[str, float],
    *,
    personalized: bool,
    interest_weight_percent: int,
    rng: random.Random | None = None,
) -> list[AdCampaign]:
    """Orders ads for one viewer by weighted random sampling: an ad's chance to come first grows with how well it
    matches the viewer (interest weight %), yet every paid ad keeps a share of first slots and the system keeps
    learning. Without personalization every ad has the same chance (plain rotation)."""
    rng = rng or random.Random()
    weight = min(max(interest_weight_percent, 0), 100) / 100 if personalized else 0.0

    def key(ad: AdCampaign) -> float:
        # Efraimidis-Spirakis: sorting by u ** (1 / w) samples without replacement with probability ~ w.
        w = max((1 - weight) + weight * affinity(ad.topics or [], profile), MIN_SHARE)
        return rng.random() ** (1 / w)

    return sorted(ads, key=key, reverse=True)


def ctr_percent(views: int, clicks: int) -> float:
    return round(100 * clicks / views, 1) if views else 0.0
