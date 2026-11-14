import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/formatters.dart';
import 'package:tdlib_ex/td_api.dart' as td;

Map<String, dynamic> _text(String text) => {
      '@type': 'messageText',
      'text': {'@type': 'formattedText', 'text': text, 'entities': <Object>[]},
    };

Map<String, dynamic> _keyboard(String label) => {
      '@type': 'replyMarkupInlineKeyboard',
      'rows': [
        [
          {
            '@type': 'inlineKeyboardButton',
            'text': label,
            'style': {'@type': 'buttonStyleDefault'},
            'type': {'@type': 'inlineKeyboardButtonTypeCallback', 'data': ''},
          },
        ],
      ],
    };

td.Message _message({Map<String, dynamic>? ephemeral}) => td.Message.fromJson({
      '@type': 'message',
      'id': 1 << 20,
      'sender_id': {'@type': 'messageSenderUser', 'user_id': 2},
      'chat_id': 7,
      'date': 1000,
      'content': _text('Choose a size'),
      'reply_markup': _keyboard('S'),
      'ephemeral_content': ?ephemeral,
    })!;

String _textOf(td.Message message) => (message.content as td.MessageText).text.text;

void main() {
  test('a message without ephemeral content is shown as it is', () {
    final message = _message();
    expect(identical(message.shown, message), isTrue);
  });

  test('ephemeral content and its keyboard replace what the user sees', () {
    final message = _message(ephemeral: {
      '@type': 'ephemeralMessageContent',
      'can_be_saved': false,
      'has_timestamped_media': false,
      'content': _text('Only you see this'),
      'reply_markup': _keyboard('Undo'),
    });
    final shown = message.shown;
    expect(_textOf(shown), 'Only you see this');
    expect(((shown.replyMarkup as td.ReplyMarkupInlineKeyboard).rows.first.first).text, 'Undo');
    expect(shown.id, message.id);
    // The stored message keeps its regular content for when the bot clears the ephemeral reply.
    expect(_textOf(message), 'Choose a size');
  });

  test('ephemeral content without a keyboard hides the regular one', () {
    final message = _message(ephemeral: {
      '@type': 'ephemeralMessageContent',
      'can_be_saved': true,
      'has_timestamped_media': false,
      'content': _text('Done'),
    });
    expect(message.shown.replyMarkup, isNull);
  });
}
