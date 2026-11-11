import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/api/gift_models.dart';

void main() {
  test('reads a running badge with a custom emoji id beyond 2^53', () {
    final offer = BadgeOffer.fromJson({
      'price_uzs': 15000,
      'days': 30,
      'balance_uzs': 2000,
      'badge': {'emoji_id': '5368324170671202286', 'expires_at': '2026-12-11T10:00:00+00:00'},
    });

    expect(offer.emojiId, 5368324170671202286);
    expect(offer.expiresAt!.toUtc(), DateTime.utc(2026, 12, 11, 10));
    expect(offer.priceUzs, 15000);
  });

  test('no badge yet means no emoji and no expiry', () {
    final offer = BadgeOffer.fromJson({'price_uzs': 15000, 'days': 30, 'balance_uzs': 0, 'badge': null});

    expect(offer.emojiId, isNull);
    expect(offer.expiresAt, isNull);
  });
}
