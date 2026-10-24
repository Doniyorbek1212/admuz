import 'package:flutter_test/flutter_test.dart';
import 'package:sado/state/playback.dart';
import 'package:tdlib_ex/td_api.dart' as td;

td.Message _message(int id) => td.Message.fromJson({
      '@type': 'message',
      'id': id,
      'sender_id': {'@type': 'messageSenderUser', 'user_id': 2},
      'chat_id': 7,
      'date': 1000,
      'edit_date': 0,
      'content': {
        '@type': 'messageText',
        'text': {'@type': 'formattedText', 'text': '', 'entities': <Object>[]},
      },
    })!;

void main() {
  // TDLib returns newest first and may or may not include the current message.
  final window = [_message(50), _message(40), _message(30), _message(20)];

  test('next track is the closest newer message', () {
    expect(pickNeighbor(window, 30, newer: true)?.id, 40);
  });

  test('previous track is the closest older message', () {
    expect(pickNeighbor(window, 40, newer: false)?.id, 30);
  });

  test('no neighbour at the ends of the chat', () {
    expect(pickNeighbor(window, 50, newer: true), isNull);
    expect(pickNeighbor(window, 20, newer: false), isNull);
  });
}
