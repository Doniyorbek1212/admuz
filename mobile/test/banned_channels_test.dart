import 'package:flutter_test/flutter_test.dart';
import 'package:sado/state/banned_channels.dart';

void main() {
  final banned = BannedChannels(usernames: {'abuxolid88', '+ohdkqijajmo30duy'}, titles: {normalizeChannelTitle('Jannatga Oshiqlar')});

  test('title match ignores case, spacing, punctuation and Cyrillic look-alike letters', () {
    expect(banned.matches(const [], 'JANNATGA  oshiqlar!', person: false), isTrue);
    expect(banned.matches(const [], 'Jаnnаtgа Oshiqlаr', person: false), isTrue); // Cyrillic "а"
    expect(banned.matches(const [], 'Jannatga Oshiqlar 2', person: false), isFalse);
    expect(banned.matches(const [], '🌙𝐉𝐀𝐍𝐍𝐀𝐓𝐆𝐀 𝐎𝐒𝐇𝐈𝐐𝐋𝐀𝐑 🌙', person: false), isTrue); // math-bold letters
    expect(banned.matches(const [], 'ＪＡＮＮＡＴＧＡ ｏｓｈｉｑｌａｒ', person: false), isTrue); // full-width
  });

  test('titles never hide a person, usernames do', () {
    expect(banned.matches(const [], 'Jannatga Oshiqlar', person: true), isFalse);
    expect(banned.matches(const ['AbuXolid88'], 'Anyone', person: true), isTrue);
  });

  test('invite links match by hash', () {
    expect(banned.hidesInvite('https://t.me/+OhDKQIjAJMo30DUy'), isTrue);
    expect(banned.hidesInvite('https://t.me/joinchat/OhDKQIjAJMo30DUy'), isTrue);
    expect(banned.hidesInvite('https://t.me/+other'), isFalse);
  });
}
