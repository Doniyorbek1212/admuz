import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/api/gift_models.dart';
import 'package:sado/features/gifts/gift_effects.dart';
import 'package:sado/state/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

// A drawn show (no render to download), so the test needs no network.
const _gift = GiftItem(id: '1', title: 'Pop', priceUzs: 1000, animationUrl: '', effect: 'pop');

class _Routes extends NavigatorObserver {
  int pushed = 0;
  int open = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed++;
    open++;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => open--;

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => open--;
}

void main() {
  testWidgets('a second show asked for while one plays is skipped, and the show leaves no page behind', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final routes = _Routes();
    late BuildContext page;
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        navigatorObservers: [routes],
        home: Builder(builder: (context) {
          page = context;
          return const Scaffold();
        }),
      ),
    ));
    expect((routes.pushed, routes.open), (1, 1));

    // Right after sending, the shop and the recipient's profile both ask for the gift's show.
    final first = showPremiumGift(page, _gift);
    final second = showPremiumGift(page, _gift);
    await tester.pump();
    await tester.pump();
    expect((routes.pushed, routes.open), (2, 2), reason: 'only one show page opened');

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    await first;
    await second;
    expect(routes.open, 1, reason: 'the finished show closed its own page');
    expect(ModalRoute.of(page)!.isCurrent, isTrue);
  });
}
