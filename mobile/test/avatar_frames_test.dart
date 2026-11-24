import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/api/frame_models.dart';
import 'package:sado/core/config.dart';
import 'package:sado/features/gifts/avatar_frames.dart';

const _shopJson = {
  'items': [
    {
      'key': 'gold_laurel',
      'title': 'Oltin dafna',
      'title_ru': 'Золотой лавр',
      'title_en': 'Golden Laurel',
      'tier': 4,
      'price_uzs': 75000,
      'animation_url': '/media/a.webp',
      'small_url': '/media/a_s.webp',
      'active': true,
    },
    {
      'key': 'old_frame',
      'title': 'Eski',
      'tier': 1,
      'price_uzs': 20000,
      'animation_url': '/media/b.webp',
      'small_url': '/media/b_s.webp',
      'active': false,
    },
  ],
  'linked': true,
  'owned': ['old_frame'],
  'equipped': 'old_frame',
  'balance_uzs': 5000,
};

AvatarFrameItem _frame() => FrameShop.fromJson(_shopJson).items.first;

void main() {
  test('reads the shop: titles per language, media urls, retired frames, what is owned and worn', () {
    final shop = FrameShop.fromJson(_shopJson);

    final gold = shop.byKey('gold_laurel')!;
    expect(gold.titleFor('ru'), 'Золотой лавр');
    expect(gold.titleFor('en'), 'Golden Laurel');
    expect(gold.animationUrl, '${AppConfig.apiUrl}/media/a.webp');
    expect(gold.smallUrl, '${AppConfig.apiUrl}/media/a_s.webp');
    expect(gold.onSale, isTrue);

    final old = shop.byKey('old_frame')!;
    expect(old.onSale, isFalse);
    expect(old.titleFor('en'), 'Eski'); // no translation: the Uzbek name
    expect(shop.owned, {'old_frame'});
    expect(shop.equipped, 'old_frame');
    expect(shop.byKey('missing'), isNull);
  });

  test('an unlinked customer owns and wears nothing', () {
    final shop = FrameShop.fromJson({'items': [], 'linked': false, 'owned': [], 'equipped': null, 'balance_uzs': 0});

    expect(shop.linked, isFalse);
    expect(shop.owned, isEmpty);
    expect(shop.equipped, isNull);
  });

  Future<Rect> pumpFramed(WidgetTester tester, double size) async {
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: FramedAvatar(frame: _frame(), size: size, child: const ColoredBox(color: Colors.blue, key: Key('photo'))),
      ),
    ));
    expect(tester.getSize(find.byKey(const Key('photo'))), Size.square(size)); // the photo keeps its size
    return tester.getRect(find.byType(Image));
  }

  testWidgets('the frame overflows the avatar evenly so its hole sits on the photo', (tester) async {
    final frame = await pumpFramed(tester, 116);
    final photo = tester.getRect(find.byKey(const Key('photo')));

    expect(frame.width, closeTo(116 / framePhotoShare, 0.01));
    expect(frame.center, photo.center);
    expect(tester.getSize(find.byType(FramedAvatar)), const Size.square(116)); // layout unchanged
  });

  testWidgets('profile sizes get the frame with the plate, chat lists the small one', (tester) async {
    String shown() => ((tester.widget<Image>(find.byType(Image)).image as ResizeImage).imageProvider as NetworkImage).url;

    await pumpFramed(tester, 116);
    expect(shown(), endsWith('/media/a.webp'));

    await pumpFramed(tester, 56);
    expect(shown(), endsWith('/media/a_s.webp'));
  });
}
