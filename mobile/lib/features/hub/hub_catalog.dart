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

final hubRegionProvider = NotifierProvider<HubRegionNotifier, String>(HubRegionNotifier.new);

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
