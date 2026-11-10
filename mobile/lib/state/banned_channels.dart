import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../core/api/sado_api.dart';
import 'settings.dart';
import 'telegram.dart';

/// Cyrillic letters that look like Latin ones; banned channels often mix them to dodge exact matches.
const _lookAlike = {
  'а': 'a', 'е': 'e', 'о': 'o', 'р': 'p', 'с': 'c', 'у': 'y', 'х': 'x', 'к': 'k', 'м': 'm', 'т': 't', 'н': 'h', 'в': 'b', 'і': 'i', //
};
final _letterOrDigit = RegExp(r'^[\p{L}\p{N}]$', unicode: true);

/// Styled letters that Telegram titles use to slip past filters (𝐉𝐀𝐍𝐍𝐀𝐓𝐆𝐀, 𝕵𝖆𝖓…, ｊａｎ…) as plain ASCII.
int _plainLetter(int rune) => switch (rune) {
      // Mathematical Alphanumeric Symbols: 13 styles of A–Z then a–z, 52 code points each.
      >= 0x1D400 && <= 0x1D6A3 => (rune - 0x1D400) % 52 < 26 ? 0x41 + (rune - 0x1D400) % 52 : 0x61 + (rune - 0x1D400) % 52 - 26,
      >= 0x1D7CE && <= 0x1D7FF => 0x30 + (rune - 0x1D7CE) % 10, // styled digits
      >= 0xFF01 && <= 0xFF5E => rune - 0xFEE0, // full-width ASCII
      _ => rune,
    };

/// "Jannatga  Oshiqlar!", "jannatga oshiqlar" (even with Cyrillic "а") and "𝐉𝐀𝐍𝐍𝐀𝐓𝐆𝐀 𝐎𝐒𝐇𝐈𝐐𝐋𝐀𝐑 🌙" compare equal.
String normalizeChannelTitle(String title) {
  final out = StringBuffer();
  for (final rune in title.runes) {
    final c = String.fromCharCode(_plainLetter(rune)).toLowerCase();
    final plain = _lookAlike[c] ?? c;
    if (_letterOrDigit.hasMatch(plain)) out.write(plain);
  }
  return out.toString();
}

/// The banned-sources list (Supreme Court list, kept by UZARO admins). An entry with a username matches by it
/// alone; title-only entries match a channel or group (never a person) whose whole title is the same.
@immutable
class BannedChannels {
  const BannedChannels({this.usernames = const {}, this.titles = const {}});

  final Set<String> usernames; // lowercase; "+hash" for invite links
  final Set<String> titles; // normalized

  bool matches(Iterable<String> chatUsernames, String title, {required bool person}) =>
      chatUsernames.any((name) => usernames.contains(name.toLowerCase())) || (!person && titles.contains(normalizeChannelTitle(title)));

  bool hides(TelegramAccount account, td.Chat chat) {
    final user = account.privateUser(chat);
    final names = user?.usernames ?? account.supergroupOf(chat)?.usernames;
    final all = [...?names?.activeUsernames, ...?names?.disabledUsernames, if (names != null && names.editableUsername.isNotEmpty) names.editableUsername];
    return matches(all, chat.title, person: user != null);
  }

  /// Same check by chat id; a chat TDLib has not loaded is not hidden.
  bool hidesId(TelegramAccount account, int chatId) => switch (account.chats[chatId]) {
    final chat? => hides(account, chat),
    null => false,
  };

  /// "+hash" (or "joinchat/hash") of a t.me invite link.
  bool hidesInvite(String inviteLink) {
    final hash = RegExp(r'(?:\+|joinchat/)([\w-]+)').firstMatch(inviteLink)?.group(1);
    return hash != null && usernames.contains('+${hash.toLowerCase()}');
  }
}

final bannedChannelsProvider = NotifierProvider<BannedChannelsNotifier, BannedChannels>(BannedChannelsNotifier.new);

/// Starts from the copy saved on this device (so the filter works offline) and refreshes it from the server.
class BannedChannelsNotifier extends Notifier<BannedChannels> {
  static const _usernamesKey = 'banned.usernames';
  static const _titlesKey = 'banned.titles';

  @override
  BannedChannels build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    unawaited(Future.microtask(_refresh));
    return BannedChannels(usernames: (prefs.getStringList(_usernamesKey) ?? const []).toSet(), titles: (prefs.getStringList(_titlesKey) ?? const []).toSet());
  }

  Future<void> _refresh() async {
    final api = ref.read(sadoApiProvider);
    if (!api.configured) return;
    try {
      final (:usernames, :titles) = await api.bannedChannels();
      final next = BannedChannels(
        usernames: {for (final u in usernames) u.toLowerCase()},
        titles: {for (final t in titles) normalizeChannelTitle(t)}..remove(''),
      );
      final prefs = ref.read(sharedPreferencesProvider);
      await prefs.setStringList(_usernamesKey, next.usernames.toList());
      await prefs.setStringList(_titlesKey, next.titles.toList());
      state = next;
    } on ApiException catch (error) {
      debugPrint('banned channels refresh failed, keeping the saved list: $error');
    }
  }
}
