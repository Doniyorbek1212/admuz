import 'package:flutter_test/flutter_test.dart';
import 'package:sado/state/telegram.dart';

void main() {
  test('a chat never read locally shows Telegram\'s count', () {
    expect(unreadAfterLocalRead(5, null), 5);
  });

  test('a local read hides what was there and counts only newer messages', () {
    expect(unreadAfterLocalRead(5, 5), 0);
    expect(unreadAfterLocalRead(7, 5), 2);
  });

  test('a real read elsewhere never goes negative', () {
    expect(unreadAfterLocalRead(0, 5), 0);
  });
}
