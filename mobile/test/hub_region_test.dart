import 'package:flutter_test/flutter_test.dart';
import 'package:sado/features/hub/hub_catalog.dart';

void main() {
  test('maps positions to the region they are in', () {
    expect(regionForPosition(41.30, 69.24), 'Toshkent'); // Tashkent centre
    expect(regionForPosition(41.01, 70.14), 'Toshkent viloyati'); // Angren
    expect(regionForPosition(40.99, 71.48), 'Namangan'); // Chust
    expect(regionForPosition(39.65, 66.96), 'Samarqand');
    expect(regionForPosition(42.46, 59.61), "Qoraqalpog'iston"); // Nukus
    expect(regionForPosition(41.38, 60.36), 'Xorazm'); // Urgench
  });

  test('returns null far outside Uzbekistan', () {
    expect(regionForPosition(55.75, 37.62), isNull); // Moscow
  });
}
