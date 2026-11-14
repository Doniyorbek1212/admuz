import 'package:tdlib_ex/td_api.dart' as td;

/// "Time capsule" messages: the text stays sealed until a chosen moment.
///
/// Telegram has no such message type, so a capsule is an ordinary text message:
///   `⏳ label\nbody` where the header carries a text link `capsulePrefix + unix seconds` and the body is
///   wrapped in a spoiler. UZARO reads the link and keeps the body frozen until then; other apps show the header
///   and a spoiler (still hidden until tapped).
const capsulePrefix = 'https://uzaromessenger.uz/capsule?t=';

/// When the capsule in [text] opens, or null when [text] is not a capsule.
DateTime? capsuleUnlockAt(td.FormattedText text) {
  for (final entity in text.entities) {
    if (entity.offset != 0) continue;
    final type = entity.type;
    if (type is! td.TextEntityTypeTextUrl || !type.url.startsWith(capsulePrefix)) continue;
    final seconds = int.tryParse(type.url.substring(capsulePrefix.length));
    return seconds == null ? null : DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }
  return null;
}

/// Whether [text] is a capsule that has not opened yet.
bool isSealedCapsule(td.FormattedText text, {DateTime? now}) {
  final at = capsuleUnlockAt(text);
  return at != null && (now ?? DateTime.now()).isBefore(at);
}

/// Seals [body] until [until]; [label] is the header other apps see.
td.FormattedText sealCapsule(td.FormattedText body, DateTime until, String label) {
  final header = '⏳ $label\n';
  final seconds = until.millisecondsSinceEpoch ~/ 1000;
  return td.FormattedText(
    text: header + body.text,
    entities: [
      td.TextEntity(offset: 0, length: header.length - 1, type: td.TextEntityTypeTextUrl(url: '$capsulePrefix$seconds')),
      if (body.text.isNotEmpty) td.TextEntity(offset: header.length, length: body.text.length, type: const td.TextEntityTypeSpoiler()),
      for (final e in body.entities) e.copyWith(offset: e.offset + header.length),
    ],
  );
}

/// The message inside a capsule (header and the sealing spoiler removed); [text] itself when not a capsule.
td.FormattedText capsuleBody(td.FormattedText text) {
  if (capsuleUnlockAt(text) == null) return text;
  final cut = text.text.indexOf('\n') + 1;
  if (cut <= 0) return const td.FormattedText(text: '', entities: []);
  final length = text.text.length - cut;
  return td.FormattedText(
    text: text.text.substring(cut),
    entities: [
      for (final e in text.entities)
        if (e.offset >= cut && !(e.type is td.TextEntityTypeSpoiler && e.offset == cut && e.length == length)) e.copyWith(offset: e.offset - cut),
    ],
  );
}
