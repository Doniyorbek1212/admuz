import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/push.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('server id of a TDLib message id; local messages have none', () {
    expect(NotifiedMessages.serverId(42 << 20), 42);
    expect(NotifiedMessages.serverId((42 << 20) + 1), 0);
  });

  test('one message rings once, older ones after it stay quiet', () async {
    expect(await NotifiedMessages.claim(7, 100), isTrue);
    expect(await NotifiedMessages.claim(7, 100), isFalse); // the push after the live update
    expect(await NotifiedMessages.claim(7, 99), isFalse); // backlog after a reconnect
    expect(await NotifiedMessages.claim(7, 101), isTrue);
    expect(await NotifiedMessages.claim(8, 100), isTrue); // other chats are separate
  });
}
