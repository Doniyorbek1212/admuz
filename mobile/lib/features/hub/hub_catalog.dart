import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/settings.dart';

/// What tapping a hub tile does.
enum HubAction {
  /// Telegram channels for "[query] [region]", plus a map search.
  local,

  /// Telegram channels and groups for [HubItem.query].
  search,

  /// Opens the app's theme settings.
  themes,

  /// Opens the chat with Telegram support.
  support,

  /// Opens the business profile: own shop, products and paid ads.
  business,

  /// Approved online shops of the selected region.
  shops,
}

class HubItem {
  const HubItem(this.labelKey, this.icon, this.color, {this.action = HubAction.search, this.query, this.mapQuery});

  final String labelKey;
  final IconData icon;
  final Color color;
  final HubAction action;

  /// Telegram public search terms (Uzbek, as channel names in the region are).
  final String? query;

  /// Map search terms; the region is appended.
  final String? mapQuery;
}

const hubLocalItems = [
  HubItem('hub_taxi', Icons.local_taxi_rounded, Color(0xFFFFB020), action: HubAction.local, query: 'taksi', mapQuery: 'taxi'),
  HubItem('hub_pharmacy', Icons.medical_services_rounded, Color(0xFF2EC27E), action: HubAction.local, query: 'dorixona', mapQuery: 'pharmacy'),
  HubItem('hub_hotel', Icons.king_bed_rounded, Color(0xFF8B6CFF), action: HubAction.local, query: 'mehmonxona', mapQuery: 'hotel'),
  HubItem('hub_doctors', Icons.medical_information_rounded, Color(0xFF3D8BFF), action: HubAction.local, query: 'shifokor', mapQuery: 'clinic'),
  HubItem('hub_workshops', Icons.handyman_rounded, Color(0xFFFF7043), action: HubAction.local, query: 'usta xizmati', mapQuery: 'car repair'),
  HubItem('hub_banks', Icons.credit_card_rounded, Color(0xFF26C6B0), action: HubAction.local, query: 'bank', mapQuery: 'bank'),
  HubItem('hub_travel', Icons.map_rounded, Color(0xFFFF5C8A), action: HubAction.local, query: 'sayohat', mapQuery: 'tourist attractions'),
  HubItem('hub_food', Icons.restaurant_rounded, Color(0xFFFF8A3D), action: HubAction.local, query: 'oshxona', mapQuery: 'restaurant'),
  HubItem('hub_shops', Icons.storefront_rounded, Color(0xFF3D8BFF), action: HubAction.shops),
];

const hubFunItems = [
  HubItem('hub_movies', Icons.movie_rounded, Color(0xFFE53935), query: 'kino seriallar'),
  HubItem('hub_music', Icons.music_note_rounded, Color(0xFF2EC27E), query: 'musiqa'),
  HubItem('hub_games', Icons.sports_esports_rounded, Color(0xFF8B6CFF), query: "o'yinlar"),
  HubItem('hub_stickers', Icons.emoji_emotions_rounded, Color(0xFFFFC233), query: 'stikerlar'),
  HubItem('hub_themes', Icons.palette_rounded, Color(0xFFFF5C8A), action: HubAction.themes),
  HubItem('hub_greetings', Icons.mail_rounded, Color(0xFFFF7A59), query: 'tabriklar'),
  HubItem('hub_gifts', Icons.card_giftcard_rounded, Color(0xFF26C6B0), query: "sovg'alar"),
];

const hubToolItems = [
  HubItem('hub_ai', Icons.auto_awesome_rounded, Color(0xFF8B6CFF), query: 'gpt bot'),
  HubItem('hub_business', Icons.work_rounded, Color(0xFFFF7A59), action: HubAction.business),
  HubItem('help', Icons.help_rounded, Color(0xFF3D8BFF), action: HubAction.support),
];

/// Regions of Uzbekistan, as their names are written in Uzbek.
const uzRegions = [
  'Toshkent',
  'Toshkent viloyati',
  'Andijon',
  "Farg'ona",
  'Namangan',
  'Samarqand',
  'Buxoro',
  'Navoiy',
  'Qashqadaryo',
  'Surxondaryo',
  'Jizzax',
  'Sirdaryo',
  'Xorazm',
  "Qoraqalpog'iston",
];

/// Regional centres (lat, lon), in [uzRegions] order.
const _regionCentres = [
  (41.311, 69.279), // Toshkent
  (41.000, 69.700), // Toshkent viloyati (geographic centre: the city is Tashkent itself)
  (40.783, 72.344),
  (40.386, 71.787),
  (40.998, 71.673),
  (39.655, 66.976),
  (39.775, 64.428),
  (40.103, 65.374),
  (38.861, 65.790),
  (37.224, 67.278),
  (40.116, 67.842),
  (40.489, 68.785),
  (41.550, 60.631),
  (42.460, 59.603),
];

/// Region of Uzbekistan for a position, or null when it is too far from every regional centre.
/// shortcut: nearest regional centre, not real borders; can misplace points near a boundary. Upgrade to polygons if users complain.
String? regionForPosition(double lat, double lon) {
  double km(double lat2, double lon2) {
    final dLat = (lat2 - lat) * 111.0;
    final dLon = (lon2 - lon) * 111.0 * math.cos(lat * math.pi / 180);
    return math.sqrt(dLat * dLat + dLon * dLon);
  }

  // Tashkent city is small and enclosed by its region.
  if (km(_regionCentres[0].$1, _regionCentres[0].$2) < 18) return uzRegions[0];
  var best = 1;
  for (var i = 2; i < _regionCentres.length; i++) {
    if (km(_regionCentres[i].$1, _regionCentres[i].$2) < km(_regionCentres[best].$1, _regionCentres[best].$2)) best = i;
  }
  // Qoraqalpog'iston spans ~500 km, so the cutoff is generous; beyond it the user is abroad.
  return km(_regionCentres[best].$1, _regionCentres[best].$2) < 450 ? uzRegions[best] : null;
}

final hubRegionProvider =NotifierProvider<HubRegionNotifier, String>(HubRegionNotifier.new);

/// Region used by the "Region" tiles, remembered across launches.
class HubRegionNotifier extends Notifier<String> {
  static const _key = 'hubRegion';

  @override
  String build() => ref.watch(sharedPreferencesProvider).getString(_key) ?? uzRegions.first;

  void select(String region) {
    ref.read(sharedPreferencesProvider).setString(_key, region);
    state = region;
  }
}
