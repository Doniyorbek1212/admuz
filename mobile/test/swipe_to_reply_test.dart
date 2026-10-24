import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sado/widgets/swipe_to_reply.dart';

void main() {
  Future<int> swipe(WidgetTester tester, double dx) async {
    var replies = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SwipeToReply(onReply: () => replies++, child: const SizedBox(width: 300, height: 60, child: Text('message'))),
        ),
      ),
    ));
    await tester.drag(find.text('message'), Offset(dx, 0));
    await tester.pumpAndSettle();
    return replies;
  }

  testWidgets('a long swipe to the left starts a reply', (tester) async {
    expect(await swipe(tester, -200), 1);
  });

  testWidgets('a short swipe or a swipe to the right does nothing', (tester) async {
    expect(await swipe(tester, -30), 0);
    expect(await swipe(tester, 200), 0);
  });
}
