from app.models import PlaceCategory
from app.services.osm_import import classify, match_district, nearest, normalize, overpass_query, place_fields


def test_classify_maps_osm_tags_to_categories():
    assert classify({"amenity": "pharmacy"}) == (PlaceCategory.PHARMACY, "Dorixona")
    assert classify({"tourism": "guest_house"}) == (PlaceCategory.HOTEL, "Mehmon uyi")
    assert classify({"amenity": "bench"}) is None


def test_place_fields_reads_contacts_hours_and_position():
    element = {
        "type": "node",
        "id": 42,
        "lat": 41.0,
        "lon": 71.2,
        "tags": {
            "amenity": "restaurant",
            "name": "Golden Fish",
            "name:uz": "Oltin baliq",
            "phone": "+998 90 123 45 67;bad;+998712000000",
            "opening_hours": "24/7",
            "addr:street": "Chustiy",
            "addr:housenumber": "69",
            "website": "http://insecure.example",
            "contact:telegram": "https://t.me/oltinbaliq",
        },
    }
    f = place_fields(element)
    assert f is not None
    assert f["name"] == "Oltin baliq"
    assert f["category"] == PlaceCategory.FOOD and f["subcategory"] == "Restoran"
    assert f["phones"] == ["+998 90 123 45 67", "+998712000000"]
    assert f["is_24h"] is True
    assert f["address"] == "Chustiy 69"
    assert f["website"] == ""  # only https links are kept
    assert f["telegram"] == "oltinbaliq"
    assert f["source_ref"] == "osm:node/42"


def test_place_fields_skips_unnamed_or_unplaced_elements():
    assert place_fields({"type": "node", "id": 1, "lat": 1, "lon": 1, "tags": {"amenity": "pharmacy"}}) is None
    assert place_fields({"type": "way", "id": 2, "tags": {"amenity": "pharmacy", "name": "X"}}) is None
    way = place_fields({"type": "way", "id": 3, "center": {"lat": 40.5, "lon": 71.0}, "tags": {"amenity": "bank", "name": "Bank"}})
    assert way is not None and way["latitude"] == 40.5


def test_district_matching_tolerates_apostrophes_and_suffixes():
    assert normalize("To‘raqo‘rg‘on tumani") == normalize("To'raqo'rg'on tumani")
    assert match_district("Namangan", ["Chust tumani"]) == "Chust tumani"
    assert match_district("Namangan", ["To‘raqo‘rg‘on tumani"]) == "To'raqo'rg'on tumani"
    assert match_district("Namangan", ["Atlantis"]) is None
    # The city split into two districts in OSM is still "Namangan shahri".
    assert match_district("Namangan", ["Yangi Namangan tumani"]) == "Namangan shahri"
    # A district our list does not know keeps its OSM name, with a plain apostrophe.
    assert match_district("Andijon", ["Yangiobodʻ tumani"]) == "Yangiobod' tumani"


def test_nearest_district_centre():
    centres = [("A", 41.0, 71.0), ("B", 40.0, 72.0)]
    assert nearest(40.9, 71.1, centres) == "A"
    assert nearest(40.1, 71.9, centres) == "B"


def test_query_targets_the_region_area():
    q = overpass_query("UZ-NG")
    assert '"ISO3166-2"="UZ-NG"' in q and "admin_level" in q and "out center tags" in q
