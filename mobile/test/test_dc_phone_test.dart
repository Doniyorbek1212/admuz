import 'package:flutter_test/flutter_test.dart';
import 'package:sado/state/telegram.dart';

void main() {
  test('store review numbers go to the test servers', () {
    expect(isTestDcPhone('9996621234'), isTrue);
    expect(isTestDcPhone('+9996611234'), isTrue);
  });

  test('real numbers and malformed test numbers stay on production', () {
    expect(isTestDcPhone('+998901234567'), isFalse);
    expect(isTestDcPhone('9996641234'), isFalse);
    expect(isTestDcPhone('99966212345'), isFalse);
  });
}
