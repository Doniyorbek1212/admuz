import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sado/features/hub/hub_quick_links.dart';
import 'package:sado/state/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('four slots: old gapless lists fill the first ones, a link lands in the tapped slot, removing leaves a gap', () async {
    SharedPreferences.setMockInitialValues({
      'flutter.hubQuickLinks': jsonEncode([{'name': 'Uzum', 'url': 'https://uzum.uz'}]),
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    final links = container.read(quickLinksProvider.notifier);

    expect(container.read(quickLinksProvider).map((l) => l?.name), ['Uzum', null, null, null]);
    expect(links.add(const QuickLink('Olx', 'https://olx.uz'), slot: 3), isTrue);
    expect(links.add(const QuickLink('Olx', 'https://olx.uz'), slot: 1), isFalse, reason: 'already pinned');
    expect(links.add(const QuickLink('Kun', 'https://kun.uz'), slot: 0), isTrue, reason: 'taken slot falls back to the first free one');
    expect(container.read(quickLinksProvider).map((l) => l?.name), ['Uzum', 'Kun', null, 'Olx']);
    links.remove(const QuickLink('Uzum', 'https://uzum.uz'));
    expect(container.read(quickLinksProvider).map((l) => l?.name), [null, 'Kun', null, 'Olx']);
  });
}
