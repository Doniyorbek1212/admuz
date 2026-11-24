import 'market_models.dart';

/// An animated avatar frame in the UZARO shop (/v1/frames/catalog), bought once from the UZARO balance.
class AvatarFrameItem {
  const AvatarFrameItem({
    required this.key,
    required this.titles,
    required this.tier,
    required this.priceUzs,
    required this.animationUrl,
    required this.smallUrl,
    this.onSale = true,
  });

  factory AvatarFrameItem.fromJson(Map<String, dynamic> j) {
    final title = j['title'] as String? ?? '';
    return AvatarFrameItem(
      key: j['key'] as String,
      titles: {'uz': title, 'ru': j['title_ru'] as String? ?? title, 'en': j['title_en'] as String? ?? title},
      tier: j['tier'] as int? ?? 1,
      priceUzs: j['price_uzs'] as int? ?? 0,
      animationUrl: resolveMediaUrl(j['animation_url'] as String? ?? ''),
      smallUrl: resolveMediaUrl(j['small_url'] as String? ?? ''),
      onSale: j['active'] as bool? ?? true,
    );
  }

  final String key;
  final Map<String, String> titles;
  final int tier;
  final int priceUzs;

  /// Profile size with the UZARO plate; [smallUrl] is the chat-list size without it.
  final String animationUrl;
  final String smallUrl;

  /// Retired frames stay in the catalog so people who own them keep showing them, but cannot be bought.
  final bool onSale;

  String titleFor(String languageCode) => titles[languageCode] ?? titles['uz'] ?? key;
}

/// The frame shop and what this customer owns and wears.
class FrameShop {
  const FrameShop({required this.items, required this.linked, required this.owned, required this.equipped, required this.balanceUzs});

  factory FrameShop.fromJson(Map<String, dynamic> j) => FrameShop(
        items: [for (final item in (j['items'] as List? ?? const [])) AvatarFrameItem.fromJson(item as Map<String, dynamic>)],
        linked: j['linked'] as bool? ?? false,
        owned: {for (final key in (j['owned'] as List? ?? const [])) key as String},
        equipped: j['equipped'] as String?,
        balanceUzs: j['balance_uzs'] as int? ?? 0,
      );

  final List<AvatarFrameItem> items;

  /// The Telegram account is proven through the gifts bot (needed to buy or wear).
  final bool linked;
  final Set<String> owned;
  final String? equipped;
  final int balanceUzs;

  AvatarFrameItem? byKey(String key) => items.where((f) => f.key == key).firstOrNull;
}
