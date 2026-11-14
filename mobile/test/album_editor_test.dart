import 'package:flutter_test/flutter_test.dart';
import 'package:sado/features/chat/album_editor.dart';
import 'package:tdlib_ex/td_api.dart' as td;

td.Message _photo(int id, [String caption = '']) => td.Message.fromJson(<String, dynamic>{
      '@type': 'message',
      'id': id,
      'sender_id': {'@type': 'messageSenderUser', 'user_id': 1},
      'chat_id': 1,
      'is_outgoing': true,
      'date': 0,
      'edit_date': 0,
      'media_album_id': '7',
      'content': {
        '@type': 'messagePhoto',
        'photo': {'@type': 'photo', 'has_stickers': false, 'sizes': <Object>[]},
        'caption': {'@type': 'formattedText', 'text': caption, 'entities': <Object>[]},
        'show_caption_above_media': false,
        'has_spoiler': false,
        'is_secret': false,
      },
    })!;

void main() {
  const caption = td.FormattedText(text: 'Halloween', entities: []);

  test('unchanged album needs no edits', () {
    final album = [_photo(1, 'Halloween'), _photo(2), _photo(3)];
    expect(planAlbumEdits(album, album, caption), isEmpty);
  });

  test('swapping two items rewrites both slots and keeps the caption on the first', () {
    final album = [_photo(1, 'Halloween'), _photo(2), _photo(3)];
    final edits = planAlbumEdits(album, [album[1], album[0], album[2]], caption);

    expect(edits, hasLength(2));
    final first = edits[0] as AlbumMediaEdit;
    expect((first.messageId, first.source.id, first.caption.text), (1, 2, 'Halloween'));
    final second = edits[1] as AlbumMediaEdit;
    // The old caption holder gives the caption up when it leaves the first slot.
    expect((second.messageId, second.source.id, second.caption.text), (2, 1, ''));
  });

  test('removing an item frees the last slot', () {
    final album = [_photo(1), _photo(2), _photo(3)];
    final edits = planAlbumEdits(album, [album[0], album[2]], const td.FormattedText(text: '', entities: []));

    expect(edits.whereType<AlbumRemoval>().map((e) => e.messageId), [3]);
    expect(edits.whereType<AlbumMediaEdit>().single.source.id, 3);
  });

  test('a new caption alone is a caption edit', () {
    final album = [_photo(1), _photo(2)];
    final edits = planAlbumEdits(album, album, caption);
    expect(edits.single, isA<AlbumCaptionEdit>());
  });
}
