import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android keep-alive service (KeepAliveService.kt): holds the process so TDLib stays connected
/// and messages keep notifying while the app is closed. No-op elsewhere.
abstract final class KeepAliveService {
  static const _channel = MethodChannel('uz.sado.app/keepalive');

  static Future<void> setEnabled(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setEnabled', enabled);
    } on PlatformException catch (error) {
      // The preference is already saved; the service follows it on the next app start.
      debugPrint('keep-alive toggle failed: $error');
    }
  }

  /// Battery charge in percent (Android only; null elsewhere or when unknown). Served by the same channel.
  static Future<int?> batteryLevel() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<int>('batteryLevel');
    } on PlatformException catch (error) {
      debugPrint('battery level unavailable: $error');
      return null;
    }
  }
}
