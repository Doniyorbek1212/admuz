import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/phone_numbers.dart';

void main() {
  test('finds Uzbek numbers in any common spelling', () {
    expect(phoneNumbersIn('Ali: +998 90 123-45-67'), ['998901234567']);
    expect(phoneNumbersIn('tel 90 123 45 67 ga qo\'ng\'iroq qiling'), ['998901234567']);
    expect(phoneNumbersIn('998(93)555-11-22'), ['998935551122']);
    expect(phoneNumbersIn('901234567'), ['998901234567']);
  });

  test('finds international and Russian numbers', () {
    expect(phoneNumbersIn('+44 20 7946 0958'), ['442079460958']);
    expect(phoneNumbersIn('8 916 123 45 67'), ['79161234567']);
  });

  test('ignores card numbers, dates, ids and duplicates', () {
    expect(phoneNumbersIn('Karta 8600 1234 5678 9012'), isEmpty);
    expect(phoneNumbersIn('Buyurtma #12345678, 02.11.2026'), isEmpty);
    expect(phoneNumbersIn('id12345678901'), isEmpty);
    expect(phoneNumbersIn('+998901234567 va 90 123 45 67'), ['998901234567']);
  });
}
