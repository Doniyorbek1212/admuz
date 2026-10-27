import 'package:flutter_test/flutter_test.dart';
import 'package:sado/features/chat/sticker_creator.dart';

void main() {
  test('scales the longer side to 512 and keeps the aspect ratio', () {
    expect(stickerSize(1024, 512), (512, 256));
    expect(stickerSize(300, 600), (256, 512));
    expect(stickerSize(100, 100), (512, 512));
  });

  test('never returns a zero side for extreme images', () {
    expect(stickerSize(5000, 1), (512, 1));
    expect(stickerSize(1, 5000), (1, 512));
  });
}
