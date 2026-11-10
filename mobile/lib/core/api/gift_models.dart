import 'market_models.dart';

/// A gift in the UZARO catalog (/v1/gifts/catalog): an animated WebP/GIF bought from the UZARO balance.
class GiftItem {
  const GiftItem({
    required this.id,
    required this.title,
    required this.priceUzs,
    required this.animationUrl,
    this.videoUrl,
    this.effect,
    this.showUrl,
    this.soundUrl,
    this.durationMs,
    this.tier,
    this.titles = const {},
  });

  factory GiftItem.fromJson(Map<String, dynamic> j) => GiftItem(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        priceUzs: j['price_uzs'] as int? ?? 0,
        animationUrl: resolveMediaUrl(j['animation_url'] as String? ?? ''),
        videoUrl: switch (j['video_url']) { final String url => resolveMediaUrl(url), _ => null },
        effect: switch (j['effect']) { final String e when e.isNotEmpty => e, _ => null },
        showUrl: switch (j['show_url']) { final String url => resolveMediaUrl(url), _ => null },
        soundUrl: switch (j['sound_url']) { final String url => resolveMediaUrl(url), _ => null },
        durationMs: j['duration_ms'] as int?,
        tier: j['tier'] as int?,
        titles: {for (final MapEntry(:key, :value) in ((j['titles'] as Map?) ?? const {}).entries) key as String: value as String},
      );

  final String id;

  /// The Uzbek name; [titleFor] picks the reader's language.
  final String title;

  /// Names by language code (uz, ru, en) for rendered-show gifts; empty for older ones.
  final Map<String, String> titles;

  /// Rendered-show gifts: their sound (played with the first frame), show length and tier 1–4.
  final String? soundUrl;
  final int? durationMs;
  final int? tier;

  String titleFor(String languageCode) => titles[languageCode] ?? title;
  final int priceUzs;
  final String animationUrl;

  /// Premium gifts: an MP4 with sound played full screen on the recipient's profile.
  final String? videoUrl;

  /// Premium gifts the app draws over the screen ("lion", "plane", "helicopter"); see gift_effects.dart.
  final String? effect;

  /// The effect's rendered show: a transparent animated WebP played full screen; null = drawn by the app.
  final String? showUrl;

  /// Gold bubble, and a full-screen show when someone opens the recipient's profile.
  bool get premium => effect != null || videoUrl != null;
}

/// What UZARO users see on someone's profile: their visible gifts and the background they picked.
class ProfileGifts {
  const ProfileGifts(this.gifts, this.background);

  static const empty = ProfileGifts([], null);

  factory ProfileGifts.fromJson(Map<String, dynamic> j) => ProfileGifts(
        [for (final g in j['items'] as List? ?? const []) SentGift.fromJson(g as Map<String, dynamic>)],
        parseBackground(j['background'] as String?),
      );

  final List<SentGift> gifts;

  /// Header gradient as ARGB colors (one or two), or null for none.
  final List<int>? background;
}

/// "#rrggbb" or "#rrggbb,#rrggbb" to opaque ARGB ints; null when empty or malformed.
List<int>? parseBackground(String? value) {
  if (value == null || !RegExp(r'^#[0-9a-f]{6}(,#[0-9a-f]{6})?$').hasMatch(value)) return null;
  return [for (final hex in value.split(',')) 0xFF000000 | int.parse(hex.substring(1), radix: 16)];
}

/// A gift someone received; shown on their profile to UZARO users unless [hidden].
class SentGift {
  const SentGift({
    required this.id,
    required this.gift,
    required this.senderTelegramId,
    required this.recipientTelegramId,
    required this.text,
    required this.hidden,
    required this.createdAt,
  });

  factory SentGift.fromJson(Map<String, dynamic> j) => SentGift(
        id: j['id'] as String,
        gift: GiftItem.fromJson(j['gift'] as Map<String, dynamic>),
        senderTelegramId: j['sender_telegram_id'] as int? ?? 0,
        recipientTelegramId: j['recipient_telegram_id'] as int? ?? 0,
        text: j['text'] as String? ?? '',
        hidden: j['hidden'] as bool? ?? false,
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now(),
      );

  final String id;
  final GiftItem gift;
  final int senderTelegramId;
  final int recipientTelegramId;
  final String text;
  final bool hidden;
  final DateTime createdAt;
}

class WalletTopup {
  const WalletTopup({required this.id, required this.amountUzs, required this.status, required this.rejectReason});

  factory WalletTopup.fromJson(Map<String, dynamic> j) => WalletTopup(
        id: j['id'] as String,
        amountUzs: j['amount_uzs'] as int? ?? 0,
        status: j['status'] as String? ?? 'pending',
        rejectReason: j['reject_reason'] as String? ?? '',
      );

  final String id;
  final int amountUzs;

  /// pending | approved | rejected
  final String status;
  final String rejectReason;
}

/// The UZARO balance in so'm and where to transfer money to top it up.
class Wallet {
  const Wallet({required this.balanceUzs, required this.card, required this.cardHolder, required this.topups});

  factory Wallet.fromJson(Map<String, dynamic> j) => Wallet(
        balanceUzs: j['balance_uzs'] as int? ?? 0,
        card: j['card'] as String? ?? '',
        cardHolder: j['card_holder'] as String? ?? '',
        topups: [for (final t in j['topups'] as List? ?? const []) WalletTopup.fromJson(t as Map<String, dynamic>)],
      );

  final int balanceUzs;
  final String card;
  final String cardHolder;
  final List<WalletTopup> topups;
}

/// A one-time code the app sends to the gifts bot as "/start <code>" to prove the user's Telegram id.
class TelegramLinkCode {
  const TelegramLinkCode(this.code, this.botUsername);

  factory TelegramLinkCode.fromJson(Map<String, dynamic> j) => TelegramLinkCode(j['code'] as String, j['bot_username'] as String);

  final String code;
  final String botUsername;
}

/// A UZARO @name and the Telegram account it leads to; [contactToken] opens people who have no shared chat.
class UzaroName {
  const UzaroName(this.username, this.telegramUserId, this.contactToken);

  factory UzaroName.fromJson(Map<String, dynamic> j) =>
      UzaroName(j['username'] as String, j['telegram_user_id'] as int, j['contact_token'] as String?);

  final String username;
  final int telegramUserId;
  final String? contactToken;
}
