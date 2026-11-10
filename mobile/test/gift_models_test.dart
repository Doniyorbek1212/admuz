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
}
