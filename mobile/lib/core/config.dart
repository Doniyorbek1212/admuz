import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Telegram API credentials from https://my.telegram.org (API development tools).
class TelegramCredentials {
  const TelegramCredentials(this.apiId, this.apiHash);

  final int apiId;
  final String apiHash;

  bool get isValid => apiId > 0 && RegExp(r'^[0-9a-f]{32}$').hasMatch(apiHash);
}

class AppConfig {
  static const String appName = 'UZARO';
  /// Shown in Telegram's device list next to the app name; keep in step with `version:` in pubspec.yaml.
  // Keep in sync with `version:` in pubspec.yaml.
  static const String appVersion = '1.1.3';

  /// UZARO server (shops, hub ads, admin review): --dart-define=SADO_API_URL=https://api.example.uz
  /// Empty disables those features. Plain http is allowed only for the emulator host (network_security_config).
  static const String apiUrl = String.fromEnvironment('SADO_API_URL');

  // Prefer baking credentials into release builds:
  //   flutter build apk --dart-define=TG_API_ID=12345 --dart-define=TG_API_HASH=0123abcd...
  static const int _definedApiId = int.fromEnvironment('TG_API_ID');
  static const String _definedApiHash = String.fromEnvironment('TG_API_HASH');

  /// Use Telegram's test data centers (for development accounts only).
  static const bool useTestDc = bool.fromEnvironment('TG_TEST_DC');

  static const _storage = FlutterSecureStorage();
  static const _idKey = 'sado.tg.api_id';
  static const _hashKey = 'sado.tg.api_hash';

  static bool get hasBuiltInCredentials => _definedApiId > 0 && _definedApiHash.isNotEmpty;

  /// Build-time credentials win; otherwise the ones the user entered on the setup screen.
  static Future<TelegramCredentials?> loadCredentials() async {
    if (hasBuiltInCredentials) return const TelegramCredentials(_definedApiId, _definedApiHash);
    final id = int.tryParse(await _storage.read(key: _idKey) ?? '');
    final hash = await _storage.read(key: _hashKey);
    if (id == null || hash == null) return null;
    final credentials = TelegramCredentials(id, hash);
    return credentials.isValid ? credentials : null;
  }

  static Future<void> saveCredentials(TelegramCredentials credentials) async {
    await _storage.write(key: _idKey, value: '${credentials.apiId}');
    await _storage.write(key: _hashKey, value: credentials.apiHash);
  }
}
