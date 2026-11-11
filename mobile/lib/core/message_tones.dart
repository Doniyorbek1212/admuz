import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// New-message notification tones: 'default' (the phone's), 'none', or a ChatSounds id bundled as
/// `android/app/src/main/res/raw/tone_<id>.wav`. Chosen globally and per chat.
abstract final class MessageTones {
  static const ids = ['default', 'pop', 'ding', 'chime', 'bubble', 'swoosh', 'click', 'none'];

  static const globalKey = 'messageTone';
  static const chatKeyPrefix = 'chatTone.';
  static String chatKey(int chatId) => '$chatKeyPrefix$chatId';

  /// For the push isolate, which has no Riverpod state.
  static String fromPrefs(SharedPreferences prefs, int? chatId) =>
      (chatId == null ? null : prefs.getString(chatKey(chatId))) ?? prefs.getString(globalKey) ?? 'default';

  /// Android fixes a channel's sound when it is created, so every tone has its own channel.
  /// [silent]: the app already played the tone itself (it is on screen).
  static AndroidNotificationDetails android(String tone, {bool silent = false}) {
    final known = ids.contains(tone) ? tone : 'default';
    return AndroidNotificationDetails(
      switch (known) { 'default' => 'messages', _ => 'messages_$known' },
      switch (known) { 'default' => 'Messages', _ => 'Messages · $known' },
      channelDescription: 'New messages',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      playSound: known != 'none',
      sound: switch (known) { 'default' || 'none' => null, _ => RawResourceAndroidNotificationSound('tone_$known') },
      silent: silent,
    );
  }

  static const _channel = MethodChannel('uz.sado.app/privacy');
  static DateTime _lastPlayed = DateTime(0);

  /// Plays [tone] in the app: MIUI and others mute notification sounds of the app on screen.
  /// A burst of messages rings once.
  static Future<void> play(String tone, {bool preview = false}) async {
    if (tone == 'none' || !Platform.isAndroid) return;
    final now = DateTime.now();
    if (!preview && now.difference(_lastPlayed) < const Duration(milliseconds: 1500)) return;
    _lastPlayed = now;
    try {
      await _channel.invokeMethod<void>('playTone', {'name': ids.contains(tone) && tone != 'default' ? 'tone_$tone' : null});
    } on PlatformException catch (error) {
      debugPrint('message tone failed: $error');
    } on MissingPluginException catch (error) {
      debugPrint('message tone unavailable: $error');
    }
  }
}
