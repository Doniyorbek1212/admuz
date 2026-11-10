import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/time_capsule.dart';
import 'package:sado/state/actions.dart';
import 'package:tdlib_ex/td_api.dart' as td;

void main() {
  const body = td.FormattedText(
    text: 'Look under the porch',
    entities: [td.TextEntity(offset: 0, length: 4, type: td.TextEntityTypeBold())],
  );

  test('a sealed capsule keeps its body and opening time', () {
    final until = DateTime(2030, 1, 1);
    final sealed = sealCapsule(body, until, 'Time capsule');

    expect(capsuleUnlockAt(sealed), until);
    expect(isSealedCapsule(sealed, now: DateTime(2029)), isTrue);
    expect(isSealedCapsule(sealed, now: DateTime(2030, 1, 2)), isFalse);
    // Other apps see the body behind a spoiler.
    expect(sealed.entities.any((e) => e.type is td.TextEntityTypeSpoiler && sealed.text.substring(e.offset) == body.text), isTrue);

    final opened = capsuleBody(sealed);
    expect(opened.text, body.text);
    expect(opened.entities, hasLength(1));
    expect(opened.entities.single.type, isA<td.TextEntityTypeBold>());
    expect(opened.entities.single.offset, 0);
  });

  test('ordinary messages are not capsules', () {
    expect(capsuleUnlockAt(body), isNull);
    expect(isSealedCapsule(body), isFalse);
    expect(capsuleBody(body), same(body));
  });

  test('composer tags become underline and collapsed-section entities', () {
    final text = composerTags('a <u>bc</u> ${collapsedTags.$1}Head\nx <u>y</u>${collapsedTags.$2}');

    expect(text.text, 'a bc Head\nx y');
    final underline = text.entities.where((e) => e.type is td.TextEntityTypeUnderline).toList();
    expect(underline.map((e) => text.text.substring(e.offset, e.offset + e.length)), ['bc', 'y']);
    final section = text.entities.singleWhere((e) => e.type is td.TextEntityTypeExpandableBlockQuote);
    expect(text.text.substring(section.offset), 'Head\nx y');
  });

  test('text without composer tags is left as typed', () {
    final text = composerTags('2 < 3 and <b>html</b>');
    expect(text.text, '2 < 3 and <b>html</b>');
    expect(text.entities, isEmpty);
  });
}
