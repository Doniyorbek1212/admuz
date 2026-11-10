import 'package:flutter_test/flutter_test.dart';
import 'package:sado/features/hub/hub_catalog.dart';

void main() {
  test('a position picks the region the user stands in, not the default Tashkent', () {
    expect(regionForPosition(41.003, 71.237), 'Namangan'); // Chust
    expect(regionForPosition(41.311, 69.279), 'Toshkent');
    expect(regionForPosition(40.383, 71.783), "Farg'ona");
    expect(regionForPosition(39.654, 66.975), 'Samarqand');
    expect(regionForPosition(48.85, 2.35), isNull); // abroad
  });
}
