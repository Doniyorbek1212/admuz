/// A local service from the hub's "Region" directory (server: /v1/places).
class Place {
  const Place({
    required this.id,
    required this.category,
    required this.region,
    required this.district,
    required this.name,
    required this.subcategory,
    required this.description,
    required this.address,
    required this.landmark,
    required this.phones,
    required this.telegram,
    required this.instagram,
    required this.website,
    required this.workingHours,
    required this.is24h,
    required this.latitude,
    required this.longitude,
    required this.verified,
    required this.fromOsm,
    required this.distanceM,
  });

  factory Place.fromJson(Map<String, dynamic> j) => Place(
        id: j['id'] as String,
        category: j['category'] as String,
        region: j['region'] as String? ?? '',
        district: j['district'] as String?,
        name: j['name'] as String? ?? '',
        subcategory: j['subcategory'] as String? ?? '',
        description: j['description'] as String? ?? '',
        address: j['address'] as String? ?? '',
        landmark: j['landmark'] as String? ?? '',
        phones: [for (final p in j['phones'] as List? ?? const []) p as String],
        telegram: j['telegram'] as String? ?? '',
        instagram: j['instagram'] as String? ?? '',
        website: j['website'] as String? ?? '',
        workingHours: j['working_hours'] as String? ?? '',
        is24h: j['is_24h'] as bool? ?? false,
        latitude: (j['latitude'] as num?)?.toDouble(),
        longitude: (j['longitude'] as num?)?.toDouble(),
        verified: j['verified'] as bool? ?? false,
        fromOsm: j['source'] == 'osm',
        distanceM: j['distance_m'] as int?,
      );

  final String id;

  /// taxi, pharmacy, hotel, doctor, car_service, bank, travel or food.
  final String category;
  final String region;
  final String? district;
  final String name;
  final String subcategory;
  final String description;
  final String address;
  final String landmark;
  final List<String> phones;
  final String telegram;
  final String instagram;
  final String website;
  final String workingHours;
  final bool is24h;
  final double? latitude;
  final double? longitude;
  final bool verified;

  /// Imported from OpenStreetMap: the detail page credits its contributors.
  final bool fromOsm;

  /// Metres from the user, present when the list was asked nearest-first.
  final int? distanceM;

  bool get hasLocation => latitude != null && longitude != null;
}

class PlacePage {
  const PlacePage(this.items, this.nextOffset);

  factory PlacePage.fromJson(Map<String, dynamic> j) =>
      PlacePage([for (final p in j['items'] as List) Place.fromJson(p as Map<String, dynamic>)], j['next_offset'] as int?);

  final List<Place> items;
  final int? nextOffset;
}

class PlaceRegion {
  const PlaceRegion(this.name, this.districts);

  factory PlaceRegion.fromJson(Map<String, dynamic> j) => PlaceRegion(j['name'] as String, [for (final d in j['districts'] as List) d as String]);

  final String name;
  final List<String> districts;
}

/// "839 m" / "1.9 km".
String formatDistance(int metres) => metres < 1000 ? '$metres m' : '${(metres / 1000).toStringAsFixed(metres < 10000 ? 1 : 0)} km';
