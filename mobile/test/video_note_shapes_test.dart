import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/video_note_crop.dart';
import 'package:sado/features/chat/video_note_shapes.dart';

void main() {
  test('shape survives the round trip through the video note length', () {
    for (final shape in VideoNoteShape.values) {
      expect(VideoNoteShape.fromLength(shape.length), shape);
      expect(shape.length, lessThanOrEqualTo(640)); // Telegram's limit
    }
    expect(VideoNoteShape.circle.length, videoNoteSize); // plain notes stay as before
  });

  test('shape survives inside the file after the server resets the length', () async {
    final dir = await Directory.systemTemp.createTemp('note');
    addTearDown(() => dir.delete(recursive: true));
    final video = File('${dir.path}/v.mp4')..writeAsBytesSync(List.filled(200, 7));
    expect(await VideoNoteShape.readMarker(video.path), isNull); // plain file: no marker
    await VideoNoteShape.heart.writeMarker(video.path);
    expect(await VideoNoteShape.readMarker(video.path), VideoNoteShape.heart);
    final bytes = video.readAsBytesSync();
    expect(bytes.sublist(204, 208), 'free'.codeUnits); // a valid trailing MP4 box: size then type
    expect(bytes.length - 200, bytes[203]);
    final plain = File('${dir.path}/c.mp4')..writeAsBytesSync(List.filled(10, 1));
    await VideoNoteShape.circle.writeMarker(plain.path);
    expect(plain.lengthSync(), 10); // circles stay untouched
  });

  test('notes from other apps (any other length) are circles', () {
    for (final length in [240, 384, 400, 479, 512, 640]) {
      expect(VideoNoteShape.fromLength(length), VideoNoteShape.circle);
    }
    expect(VideoNoteShape.byName('nope'), VideoNoteShape.circle);
  });

  test('every shape fills its box and stays inside it', () {
    const size = Size(200, 200);
    for (final shape in VideoNoteShape.values) {
      final bounds = shape.path(size).getBounds();
      expect(bounds.left, greaterThanOrEqualTo(-0.5), reason: shape.name);
      expect(bounds.top, greaterThanOrEqualTo(-0.5), reason: shape.name);
      expect(bounds.right, lessThanOrEqualTo(200.5), reason: shape.name);
      expect(bounds.bottom, lessThanOrEqualTo(200.5), reason: shape.name);
      expect(bounds.width * bounds.height, greaterThan(200 * 200 * 0.6), reason: shape.name);
      expect(shape.path(size).contains(const Offset(100, 110)), isTrue, reason: '${shape.name} centre');
    }
  });
}
