import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sado/features/ai/ai_markdown.dart';

void main() {
  test('blocks: headings, lists, quotes, code (also unclosed while streaming), paragraphs', () {
    final blocks = parseMarkdown('# Reja\n\nBirinchi qator\nikkinchi\n- olma\n  - nok\n2. uch\n> iqtibos\n---\n```dart\nprint(1);\n```\n```py\nx = 1');
    expect(blocks.map((b) => b.runtimeType.toString()), ['MdHeading', 'MdParagraph', 'MdItem', 'MdItem', 'MdItem', 'MdQuote', 'MdCode', 'MdCode']);
    expect((blocks[1] as MdParagraph).text, 'Birinchi qator\nikkinchi');
    expect((blocks[3] as MdItem).indent, 1);
    expect((blocks[4] as MdItem).marker, '2.');
    expect((blocks[6] as MdCode).code, 'print(1);');
    expect((blocks[7] as MdCode).code, 'x = 1');
  });

  test('a one-line ```code``` does not open a fence', () {
    final blocks = parseMarkdown('```ls -la```\n\nkeyingi qator');
    expect(blocks.map((b) => b.runtimeType.toString()), ['MdParagraph', 'MdParagraph']);
  });

  test('inline bold, italic and code; lone stars stay text', () {
    String flat(String s) => inlineSpans(s, const TextStyle()).map((e) => (e as TextSpan).text).join('|');
    expect(flat('a **qalin** b *kursiv* `kod` 2*3*4'), 'a |qalin| b |kursiv| |kod| 2*3*4');
    final bold = inlineSpans('**x**', const TextStyle()).single as TextSpan;
    expect(bold.style?.fontWeight, FontWeight.w700);
  });
}
