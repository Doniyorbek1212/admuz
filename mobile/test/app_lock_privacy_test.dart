import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/app_lock.dart';

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

bool _covered(WidgetTester tester) => find.byType(ColoredBox).evaluate().any((e) => e.findAncestorWidgetOfExactType<AppLockGate>() != null);

void main() {
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
