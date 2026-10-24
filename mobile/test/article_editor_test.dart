import 'package:flutter_test/flutter_test.dart';
import 'package:sado/features/chat/article_editor.dart';

void main() {
  test('title goes in bold above the body', () {
    expect(articleMarkdown(' Yangilik ', 'Matn\nikkinchi qator'), '**Yangilik**\n\nMatn\nikkinchi qator');
  });

  test('missing title or body leaves just the other', () {
    expect(articleMarkdown('', 'faqat matn'), 'faqat matn');
    expect(articleMarkdown('Faqat sarlavha', '  '), '**Faqat sarlavha**');
    expect(articleMarkdown(' ', ''), '');
  });
}
