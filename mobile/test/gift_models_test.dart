import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/api/gift_models.dart';

void main() {
  test('rendered gifts carry sound, length, tier and names per language', () {
    final gift = GiftItem.fromJson({
      'id': 'a1', 'title': 'Atirgul', 'price_uzs': 5000, 'animation_url': '/media/icon.webp', 'effect': 'rose_bloom',
      'show_url': '/media/show.webp', 'sound_url': '/media/s.mp3', 'duration_ms': 3500, 'tier': 1,
      'titles': {'uz': 'Atirgul', 'ru': 'Роза', 'en': 'Rose'},
    });
    expect(gift.premium, isTrue);
    expect((gift.durationMs, gift.tier), (3500, 1));
    expect(gift.soundUrl, endsWith('/media/s.mp3'));
    expect(gift.titleFor('ru'), 'Роза');
    expect(gift.titleFor('de'), 'Atirgul'); // unknown language falls back to the Uzbek name
  });

  test('older gifts without the new fields still parse', () {
    final gift = GiftItem.fromJson({'id': 'b', 'title': 'Yurak', 'price_uzs': 1000, 'animation_url': '/media/h.webp'});
    expect((gift.soundUrl, gift.durationMs, gift.tier, gift.premium), (null, null, null, false));
    expect(gift.titleFor('en'), 'Yurak');
  });

  test('wallet history parses, and older servers without it give an empty list', () {
    final wallet = Wallet.fromJson({
      'balance_uzs': 2000,
      'entries': [
        {'delta_uzs': -5000, 'kind': 'gift', 'created_at': '2026-11-13T10:00:00+00:00'},
        {'delta_uzs': 7000, 'kind': 'topup', 'created_at': '2026-11-12T09:00:00+00:00'},
      ],
    });
    expect([for (final e in wallet.entries) (e.kind, e.deltaUzs)], [('gift', -5000), ('topup', 7000)]);
    expect(wallet.entries.first.createdAt?.toUtc(), DateTime.utc(2026, 11, 13, 10));
    expect(Wallet.fromJson({'balance_uzs': 0}).entries, isEmpty);
    expect(Wallet.fromJson({'balance_uzs': 0}).payme, isFalse);
    expect(Wallet.fromJson({'balance_uzs': 0, 'payme': true}).payme, isTrue);
  });

  test('history lines carry the gift name per language, recipient and payment method', () {
    final page = WalletHistoryPage.fromJson({
      'items': [
        {'delta_uzs': -5000, 'kind': 'gift', 'created_at': '2026-11-13T10:00:00+00:00', 'title': 'Atirgul',
         'titles': {'uz': 'Atirgul', 'ru': 'Роза'}, 'recipient_id': 42, 'to_self': true},
        {'delta_uzs': 7000, 'kind': 'topup', 'created_at': '2026-11-12T09:00:00+00:00', 'method': 'payme'},
      ],
      'has_more': true,
    });
    final (gift, topup) = (page.items[0], page.items[1]);
    expect((gift.titleFor('ru'), gift.titleFor('en'), gift.recipientId, gift.toSelf), ('Роза', 'Atirgul', 42, true));
    expect((topup.method, topup.title, topup.toSelf), ('payme', null, false));
    expect(page.hasMore, isTrue);
  });
}
