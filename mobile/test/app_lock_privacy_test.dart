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

/// Locked with a 4-digit PIN "1234"; records any PIN that would replace it.
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
  testWidgets('a 4-digit PIN unlocks as it is, without forcing a 6-digit one', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final lock = _LegacyLock();
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs), appLockProvider.overrideWith(() => lock)],
      child: const MaterialApp(home: AppLockGate(child: Text('secret chat'))),
    ));
    expect(find.text('secret chat'), findsNothing);

    await _type(tester, '1235');
    expect(find.text('secret chat'), findsNothing, reason: 'wrong PIN stays locked');

    await _type(tester, '1234');
    expect(find.text('secret chat'), findsOneWidget);
    expect(lock.stored, isNull, reason: 'no replacement PIN asked for');
  });

  testWidgets('a new PIN can be 6 digits or, after switching, 4', (tester) async {
    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await Navigator.of(context)
              .push<String>(MaterialPageRoute(builder: (_) => const PinEntryScreen(titleKey: 'passcode_new', canSwitchLength: true))),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await _type(tester, '12');
    await tester.tap(find.text('4 xonali kod'));
    await tester.pump();
    await _type(tester, '9876'); // the switch cleared the two digits typed before it
    await tester.pumpAndSettle();
    expect(result, '9876');
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
