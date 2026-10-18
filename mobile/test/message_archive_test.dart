import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sado/state/message_archive.dart';
import 'package:tdlib_ex/td_api.dart' as td;

Map<String, dynamic> _text(String text) => {
      '@type': 'messageText',
      'text': {'@type': 'formattedText', 'text': text, 'entities': <Object>[]},
    };

td.Message _message(int id, String text, {bool outgoing = false, int chatId = 7}) => td.Message.fromJson({
      '@type': 'message',
      'id': id,
      'sender_id': {'@type': 'messageSenderUser', 'user_id': outgoing ? 1 : 2},
      'chat_id': chatId,
      'is_outgoing': outgoing,
      'date': 1000,
      'edit_date': 0,
      'content': _text(text),
    })!;

td.MessageContent _content(String text) => td.MessageText.fromJson(_text(text))!;

void main() {
  late Directory dir;
  late MessageArchive archive;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sado_archive');
    archive = MessageArchive('${dir.path}/archive.json');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('keeps messages others delete, not own or self-deleted ones', () {
    archive.rememberAll([_message(1, 'hi'), _message(2, 'mine', outgoing: true), _message(3, 'bye')]);
    archive.markOwnDelete(7, [3]);
    archive.onDeleted(7, [1, 2, 3]);
    expect(archive.isDeleted(7, 1), isTrue);
    expect(archive.isDeleted(7, 2), isFalse);
    expect(archive.isDeleted(7, 3), isFalse);
    expect(archive.deletedIn(7).map((m) => m.id), [1]);
    archive.keepDeleted = false;
    expect(archive.isDeleted(7, 1), isFalse);
  });

  test('records earlier text versions only when the text changes', () {
    archive.remember(_message(1, 'first'));
    archive.onContentChanged(7, 1, _content('first'));
    expect(archive.versionsOf(7, 1), isEmpty);
    archive.onContentChanged(7, 1, _content('second'));
    archive.onEdited(7, 1, 2000);
    archive.onContentChanged(7, 1, _content('third'));
    final versions = archive.versionsOf(7, 1);
    expect(versions.map((v) => (v.content as td.MessageText).text.text), ['first', 'second']);
    expect(versions.map((v) => v.date), [1000, 2000]);
  });

  test('clearing a chat drops its copies and ignores the deletions that follow', () {
    archive.rememberAll([_message(1, 'a'), _message(2, 'b')]);
    archive.onDeleted(7, [1]);
    archive.markChatCleared(7);
    archive.onDeleted(7, [2]);
    expect(archive.deletedIn(7), isEmpty);
  });

  test('survives a save and reload', () async {
    archive.rememberAll([_message(1, 'kept')]);
    archive.onContentChanged(7, 1, _content('kept, edited'));
    archive.onDeleted(7, [1]);
    await archive.save();
    final reloaded = MessageArchive('${dir.path}/archive.json');
    await reloaded.load();
    expect(reloaded.isDeleted(7, 1), isTrue);
    expect((reloaded.deletedIn(7).single.content as td.MessageText).text.text, 'kept, edited');
    expect(reloaded.versionsOf(7, 1).single.content, isA<td.MessageText>());
  });
}
