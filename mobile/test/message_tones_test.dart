import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/message_tones.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('each tone has its own channel and raw sound', () {
    final ding = MessageTones.android('ding');
    expect(ding.channelId, 'messages_ding');
    expect((ding.sound! as RawResourceAndroidNotificationSound).sound, 'tone_ding');
    expect(MessageTones.android('default').channelId, 'messages');
    expect(MessageTones.android('default').sound, isNull);
    expect(MessageTones.android('none').playSound, isFalse);
    // Unknown values (old prefs, typos) fall back to the phone's sound.
    expect(MessageTones.android('bogus').channelId, 'messages');
  });

  test('a chat tone overrides the global one', () async {
    SharedPreferences.setMockInitialValues({MessageTones.globalKey: 'chime', MessageTones.chatKey(-100): 'pop'});
    final prefs = await SharedPreferences.getInstance();
    expect(MessageTones.fromPrefs(prefs, -100), 'pop');
    expect(MessageTones.fromPrefs(prefs, 42), 'chime');
    expect(MessageTones.fromPrefs(prefs, null), 'chime');
  });
}
