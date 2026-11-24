import 'package:flutter_test/flutter_test.dart';
import 'package:sado/features/chat/video_note_view.dart';

void main() {
  test('a finger on the ring maps to the note clockwise from 12 o\'clock', () {
    const d = 200.0;
    expect(videoNoteTurnAt(const Offset(100, 0), d), closeTo(0, 1e-9));
    expect(videoNoteTurnAt(const Offset(200, 100), d), closeTo(0.25, 1e-9));
    expect(videoNoteTurnAt(const Offset(100, 200), d), closeTo(0.5, 1e-9));
    expect(videoNoteTurnAt(const Offset(0, 100), d), closeTo(0.75, 1e-9));
    expect(videoNoteTurnAt(const Offset(99, 0), d), greaterThan(0.99), reason: 'just left of the top is the very end');
  });
}
