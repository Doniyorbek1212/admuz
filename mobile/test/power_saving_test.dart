import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sado/state/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ProviderContainer> _container({required int level, int? battery}) async {
  SharedPreferences.setMockInitialValues({'flutter.powerSaveLevel': level});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    batteryLevelProvider.overrideWithValue(AsyncValue.data(battery)),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('off never saves, always-on always saves', () async {
    expect((await _container(level: 0, battery: 1)).read(powerSavingProvider), isFalse);
    expect((await _container(level: 100, battery: 99)).read(powerSavingProvider), isTrue);
  });

  test('threshold compares with the battery and ignores an unknown level', () async {
    expect((await _container(level: 15, battery: 15)).read(powerSavingProvider), isTrue);
    expect((await _container(level: 15, battery: 16)).read(powerSavingProvider), isFalse);
    expect((await _container(level: 15)).read(powerSavingProvider), isFalse);
  });

  test('power saving switches every animation off', () async {
    final motion = (await _container(level: 100)).read(motionProvider);
    expect([motion.stickers, motion.videos, motion.gifs, motion.transitions], everyElement(isFalse));
  });
}
