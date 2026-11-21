import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sado/features/chat/file_sheet.dart';

void main() {
  Future<void> pump(WidgetTester tester, String name) =>
      tester.pumpWidget(MaterialApp(home: FileTypeBadge(fileName: name)));

  testWidgets('shows the extension in capitals', (tester) async {
    await pump(tester, 'Report.final.PDF');
    expect(find.text('PDF'), findsOneWidget);
  });

  testWidgets('falls back to an icon without a short extension', (tester) async {
    for (final name in ['README', 'archive.', 'notes.markdown']) {
      await pump(tester, name);
      expect(find.byIcon(Icons.insert_drive_file_rounded), findsOneWidget, reason: name);
    }
  });
}
