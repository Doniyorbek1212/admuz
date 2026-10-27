"""Fills the "Region" directory from OpenStreetMap (Overpass API): one query per region, upserted by OSM id.

Admin edits to verified/featured/active/sort_order survive re-imports; the OSM data fields are refreshed.
"""

import asyncio
import json
import logging
import math
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Place, PlaceCategory
from app.places_regions import DISTRICTS, ISO_CODES, OSM_ALIASES

log = logging.getLogger(__name__)

# Public Overpass instances, tried in turn: each one is often busy (429/502/504) for a while.
OVERPASS_URLS = (
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
)
USER_AGENT = "UZARO-places-import/1.0 (https://sado.voxo.uz)"

# OSM tag value -> (category, Uzbek label shown under the name).
_TAGS: dict[tuple[str, str], tuple[PlaceCategory, str]] = {
    ("amenity", "taxi"): (PlaceCategory.TAXI, "Taksi"),
    ("office", "taxi"): (PlaceCategory.TAXI, "Taksi xizmati"),
    ("amenity", "pharmacy"): (PlaceCategory.PHARMACY, "Dorixona"),
    ("amenity", "hospital"): (PlaceCategory.DOCTOR, "Shifoxona"),
    ("amenity", "clinic"): (PlaceCategory.DOCTOR, "Klinika"),
    ("amenity", "doctors"): (PlaceCategory.DOCTOR, "Shifokor"),
    ("amenity", "dentist"): (PlaceCategory.DOCTOR, "Stomatologiya"),
    ("amenity", "bank"): (PlaceCategory.BANK, "Bank"),
    ("amenity", "bureau_de_change"): (PlaceCategory.BANK, "Valyuta ayirboshlash"),
    ("amenity", "restaurant"): (PlaceCategory.FOOD, "Restoran"),
    ("amenity", "cafe"): (PlaceCategory.FOOD, "Kafe"),
    ("amenity", "fast_food"): (PlaceCategory.FOOD, "Fast-fud"),
    ("amenity", "car_wash"): (PlaceCategory.CAR_SERVICE, "Avtomoyka"),
    ("shop", "car_repair"): (PlaceCategory.CAR_SERVICE, "Avtoservis"),
    ("shop", "tyres"): (PlaceCategory.CAR_SERVICE, "Shinalar"),
    ("amenity", "fuel"): (PlaceCategory.CAR_SERVICE, "Yoqilg'i quyish shoxobchasi"),
    ("tourism", "hotel"): (PlaceCategory.HOTEL, "Mehmonxona"),
    ("tourism", "hostel"): (PlaceCategory.HOTEL, "Hostel"),
    ("tourism", "guest_house"): (PlaceCategory.HOTEL, "Mehmon uyi"),
    ("tourism", "motel"): (PlaceCategory.HOTEL, "Motel"),
    ("tourism", "attraction"): (PlaceCategory.TRAVEL, "Diqqatga sazovor joy"),
    ("tourism", "museum"): (PlaceCategory.TRAVEL, "Muzey"),
    ("tourism", "viewpoint"): (PlaceCategory.TRAVEL, "Manzarali joy"),
    ("historic", "monument"): (PlaceCategory.TRAVEL, "Yodgorlik"),
}


def overpass_query(iso_code: str) -> str:
    by_key: dict[str, list[str]] = {}
    for key, value in _TAGS:
        by_key.setdefault(key, []).append(value)
    selectors = "".join(f'nwr["{key}"~"^({"|".join(values)})$"]["name"](area.r);' for key, values in by_key.items())
    return (
        f'[out:json][timeout:240];rel["ISO3166-2"="{iso_code}"]["admin_level"="4"];map_to_area->.r;'
        f"({selectors});out center tags;"
        f'rel["boundary"="administrative"]["admin_level"="6"](area.r);out center tags;'
    )


def classify(tags: dict[str, str]) -> tuple[PlaceCategory, str] | None:
    for (key, value), result in _TAGS.items():
        if tags.get(key) == value:
            return result
    return None


_APOSTROPHES = re.compile(r"[ʻʼ’‘`´']")


def normalize(name: str) -> str:
    """Comparable form of an Uzbek place name: lower case, every apostrophe variant dropped."""
    return _APOSTROPHES.sub("", name).lower().strip()


def match_district(region: str, osm_names: list[str]) -> str | None:
    """Our district name for an OSM boundary: an alias (city split into districts), a name from the region's list,
    or else the boundary's own Latin "… tumani/shahri" name with plain apostrophes, so new districts still show up."""
    aliases = {normalize(k): v for k, v in OSM_ALIASES.get(region, {}).items()}
    known = {normalize(d): d for d in DISTRICTS.get(region, ())}
    for name in osm_names:
        n = normalize(name)
        if n in aliases:
            return aliases[n]
        if n in known:
            return known[n]
        # OSM sometimes writes "Chust" or "Chust tumani"/"Chust shahri" differently from our list.
        for key, district in known.items():
            if key.split(" ")[0] == n.split(" ")[0] and key.endswith(n.split(" ")[-1]):
                return district
    for name in osm_names:
        if re.fullmatch(r"[A-Za-zʻʼ’‘'`\- ]+ (tumani|shahri)", name.strip()):
            return _APOSTROPHES.sub("'", name.strip())[:80]
    return None


def nearest(lat: float, lon: float, centres: list[tuple[str, float, float]]) -> str | None:
    """District whose centre is closest.
    shortcut: nearest centre, not the real boundary; can misplace places near a border. Upgrade to polygons if users report it."""
    best, best_d = None, math.inf
    k = math.cos(math.radians(lat))
    for district, clat, clon in centres:
        d = (clat - lat) ** 2 + ((clon - lon) * k) ** 2
        if d < best_d:
            best, best_d = district, d
    return best


def _username(value: str) -> str:
    value = value.strip().rstrip("/")
    value = value.rsplit("/", 1)[-1].lstrip("@")
    return value if re.fullmatch(r"[A-Za-z0-9._]{3,32}", value) else ""


def place_fields(element: dict[str, Any]) -> dict[str, Any] | None:
    """Directory fields for one Overpass element, or None when it is not a usable place."""
    tags: dict[str, str] = element.get("tags") or {}
    kind = classify(tags)
    name = tags.get("name:uz") or tags.get("name") or tags.get("name:ru") or tags.get("name:en") or ""
    lat = element.get("lat", (element.get("center") or {}).get("lat"))
    lon = element.get("lon", (element.get("center") or {}).get("lon"))
    if kind is None or not name.strip() or lat is None or lon is None:
        return None
    phones: list[str] = []
    for key in ("phone", "contact:phone", "contact:mobile", "mobile"):
        for phone in tags.get(key, "").split(";"):
            phone = phone.strip()
            if re.fullmatch(r"\+?[0-9 ()-]{5,20}", phone) and phone not in phones:
                phones.append(phone)
    street = " ".join(p for p in (tags.get("addr:street", ""), tags.get("addr:housenumber", "")) if p)
    website = tags.get("website") or tags.get("contact:website") or ""
    hours = tags.get("opening_hours", "")
    return {
        "category": kind[0],
        "subcategory": kind[1],
        "name": name.strip()[:200],
        "address": (tags.get("addr:full") or street)[:300],
        "phones": phones[:6],
        "website": website[:300] if website.startswith("https://") else "",
        "telegram": _username(tags.get("contact:telegram", "")),
        "instagram": _username(tags.get("contact:instagram", "")),
        "working_hours": hours[:200],
        "is_24h": hours.strip() == "24/7",
        "description": (tags.get("description") or "")[:3000],
        "latitude": float(lat),
        "longitude": float(lon),
        "source_ref": f"osm:{element['type']}/{element['id']}",
    }


def _fetch(query: str, rounds: int = 3) -> dict[str, Any]:
    data = urllib.parse.urlencode({"data": query}).encode()
    last: Exception | None = None
    for attempt in range(rounds):
        for url in OVERPASS_URLS:
            request = urllib.request.Request(url, data=data, headers={"User-Agent": USER_AGENT})
            try:
                with urllib.request.urlopen(request, timeout=300) as response:
                    return json.load(response)
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
                log.warning("overpass %s failed (round %d): %s", url, attempt + 1, error)
                last = error
        time.sleep(20 * (attempt + 1))
    raise RuntimeError(f"all Overpass servers failed: {last}")


async def import_region(db: AsyncSession, region: str) -> int:
    """Imports one region; returns how many places it now holds from OSM."""
    payload = await asyncio.to_thread(_fetch, overpass_query(ISO_CODES[region]))
    elements = payload.get("elements", [])
    centres: list[tuple[str, float, float]] = []
    for el in elements:
        if el.get("type") == "relation" and (el.get("tags") or {}).get("admin_level") == "6" and el.get("center"):
            tags = el["tags"]
            district = match_district(region, [tags.get(k, "") for k in ("name:uz", "name", "name:en", "name:uz-Latn") if tags.get(k)])
            if district:
                centres.append((district, el["center"]["lat"], el["center"]["lon"]))
    fields = [f for el in elements if el.get("type") != "relation" or (el.get("tags") or {}).get("admin_level") != "6" if (f := place_fields(el))]
    existing = {p.source_ref: p for p in await db.scalars(select(Place).where(Place.source_ref.in_([f["source_ref"] for f in fields])))}
    for f in fields:
        f["region"] = region
        f["district"] = nearest(f["latitude"], f["longitude"], centres) if centres else None
        place = existing.get(f["source_ref"])
        if place is None:
            db.add(Place(**f))
        else:
            for key, value in f.items():
                setattr(place, key, value)
    await db.commit()
    log.info("imported %s: %d places, %d districts matched", region, len(fields), len(centres))
    return len(fields)
