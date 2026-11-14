import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/app_lock.dart';
import 'package:sado/state/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Passcode set and already entered: the chats are on screen.
class _UnlockedLock extends AppLockNotifier {
  _UnlockedLock(this.enabled);

  final bool enabled;

  @override
  AppLockState build() => AppLockState(enabled: enabled, locked: false, autoLockMinutes: 5);
}

Future<void> _pumpGate(WidgetTester tester, {required bool passcode}) => tester.pumpWidget(
      ProviderScope(
        overrides: [appLockProvider.overrideWith(() => _UnlockedLock(passcode))],
        child: const MaterialApp(home: AppLockGate(child: Text('secret chat'))),
      ),
    );

/// Locked with an old 4-digit PIN "1234"; records the PIN that replaces it.
class _LegacyLock extends AppLockNotifier {
  String? stored;

  @override
  AppLockState build() => const AppLockState(enabled: true, locked: true, autoLockMinutes: 5, pinLength: 4);

  @override
  Future<bool> verify(String pin) async => pin == '1234';

  @override
  Future<void> enable(String pin) async {
    stored = pin;
    state = state.copyWith(locked: false, pinLength: pin.length);
  }
}

Future<void> _type(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(find.text(d));
    await tester.pump();
  }
  await tester.pump();
}

bool _covered(WidgetTester tester) => find.byType(ColoredBox).evaluate().any((e) => e.findAncestorWidgetOfExactType<AppLockGate>() != null);

void main() {
  testWidgets('an old 4-digit PIN unlocks only after a new 6-digit PIN replaces it', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final lock = _LegacyLock();
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs), appLockProvider.overrideWith(() => lock)],
      child: const MaterialApp(home: AppLockGate(child: Text('secret chat'))),
    ));
    expect(find.text('secret chat'), findsNothing);

    await _type(tester, '1234');
    expect(find.text('secret chat'), findsNothing, reason: 'still locked: the 4-digit PIN must be replaced');

    await _type(tester, '135790');
    await _type(tester, '135791'); // mismatch: asked for the new PIN again
    expect(lock.stored, isNull);

    await _type(tester, '135790');
    await _type(tester, '135790');
    expect(lock.stored, '135790');
    expect(find.text('secret chat'), findsOneWidget);
  });

  testWidgets('iOS hides the chats from the app switcher while a passcode is set', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await _pumpGate(tester, passcode: true);
    expect(_covered(tester), isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(_covered(tester), isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(_covered(tester), isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('without a passcode the app-switcher snapshot is left alone', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await _pumpGate(tester, passcode: false);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(_covered(tester), isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    debugDefaultTargetPlatformOverride = null;
  });
}
