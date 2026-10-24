import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/chat_sounds.dart';

void main() {
  test('every sound except none is short, audible and within range', () {
    for (final id in ChatSounds.ids.where((id) => id != 'none')) {
      final samples = ChatSounds.synthesize(id);
      expect(samples.length, inInclusiveRange(1000, 44100), reason: id);
      expect(samples.every((s) => s.abs() <= 1), isTrue, reason: id);
      expect(samples.any((s) => s.abs() > 0.2), isTrue, reason: id);
    }
  });

  test('wav header describes 16-bit mono PCM', () {
    final bytes = ChatSounds.wav(Float64List.fromList([0, 0.5, -0.5]));
    final data = ByteData.sublistView(bytes);
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
    expect(data.getUint16(22, Endian.little), 1);
    expect(data.getUint16(34, Endian.little), 16);
    expect(data.getUint32(40, Endian.little), 6);
    expect(bytes.length, 44 + 6);
  });
}
