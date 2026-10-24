import 'package:flutter_test/flutter_test.dart';
import 'package:sado/features/chat/location_picker.dart';

void main() {
  test('no drag keeps the centre', () {
    final (lat, lon) = shiftCenter(41.0, 71.5, 16, 0, 0);
    expect(lat, closeTo(41.0, 1e-9));
    expect(lon, closeTo(71.5, 1e-9));
  });

  test('moving right goes east, moving down goes south', () {
    final (lat, lon) = shiftCenter(41.0, 71.5, 16, 100, 100);
    expect(lon, greaterThan(71.5));
    expect(lat, lessThan(41.0));
  });

  test('one world width at zoom 0 wraps longitude back', () {
    final (_, lon) = shiftCenter(0, 10, 0, 256, 0);
    expect(lon, closeTo(10, 1e-6));
  });
}
