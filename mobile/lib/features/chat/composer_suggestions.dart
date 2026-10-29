import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import 'composer_panels.dart' show StickerThumb;

/// A message that is nothing but emoji (no letters, digits or spaces).
final _onlyEmoji = RegExp(r'^[^\p{L}\p{N}\s]{1,8}$', unicode: true);

/// ":word" at the cursor: Telegram's emoji search.
final _emojiQuery = RegExp(r'(?:^|\s):([\p{L}\p{N}_]{2,})$', unicode: true);

/// "#tag" at the cursor: hashtags the user typed before.
final _hashtagQuery = RegExp(r'(?:^|\s)#([\p{L}\p{N}_]+)$', unicode: true);

/// Telegram-style row above the composer: stickers for a lone emoji, emoji for ":word", recent hashtags for "#tag".
class EmojiStickerSuggestions extends ConsumerStatefulWidget {
  const EmojiStickerSuggestions({super.key, required this.controller, required this.chatId, required this.onSticker});

  final TextEditingController controller;
  final int chatId;
  final void Function(td.Sticker sticker) onSticker;

  @override
  ConsumerState<EmojiStickerSuggestions> createState() => _EmojiStickerSuggestionsState();
}

class _EmojiStickerSuggestionsState extends ConsumerState<EmojiStickerSuggestions> {
  Timer? _timer;
  String _key = '';
  List<td.Sticker> _stickers = const [];
  List<String> _emojis = const [];
  List<String> _hashtags = const [];
  // The big animated version of a lone emoji; sending the emoji as text plays it.
  td.Sticker? _animated;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.controller.removeListener(_onText);
    super.dispose();
  }

  void _onText() {
    final text = widget.controller.text;
    final cursor = widget.controller.selection.baseOffset;
    final before = cursor >= 0 && cursor <= text.length ? text.substring(0, cursor) : text;
    final trimmed = text.trim();
    final emojiWord = _emojiQuery.firstMatch(before)?.group(1);
    final tagWord = _hashtagQuery.firstMatch(before)?.group(1);
    final key = _onlyEmoji.hasMatch(trimmed)
        ? 's:$trimmed'
        : emojiWord != null
            ? 'e:$emojiWord'
            : (tagWord != null ? 'h:$tagWord' : '');
    if (key == _key) return;
    _key = key;
    _timer?.cancel();
    if (key.isEmpty) {
      if (_stickers.isNotEmpty || _emojis.isNotEmpty || _hashtags.isNotEmpty) {
        setState(() {
          _stickers = const [];
          _emojis = const [];
          _hashtags = const [];
          _animated = null;
        });
      }
      return;
    }
    _timer = Timer(const Duration(milliseconds: 300), () => _load(key));
  }

  Future<void> _load(String key) async {
    final account = ref.read(accountProvider);
    final languages = [Localizations.localeOf(context).languageCode];
    try {
      if (key.startsWith('h:')) {
        final found = await account.send<td.Hashtags>(td.SearchHashtags(prefix: key.substring(2), limit: 10));
        if (mounted && key == _key) {
          setState(() {
            _stickers = const [];
            _animated = null;
            _emojis = const [];
            _hashtags = found.hashtags.where((tag) => tag != key.substring(2)).toList();
          });
        }
      } else if (key.startsWith('s:')) {
        final found = await account.send<td.Stickers>(td.GetStickers(stickerType: const td.StickerTypeRegular(), query: key.substring(2), limit: 20, chatId: widget.chatId));
        td.Sticker? animated;
        try {
          animated = (await account.send<td.AnimatedEmoji>(td.GetAnimatedEmoji(emoji: key.substring(2)))).sticker;
        } on TdException {
          animated = null; // Not every emoji has an animated version.
        }
        if (mounted && key == _key) {
          setState(() {
            _animated = animated;
            _stickers = found.stickers;
            _emojis = const [];
            _hashtags = const [];
          });
        }
      } else {
        final results = await Future.wait([
          account.send<td.EmojiKeywords>(td.SearchEmojis(text: key.substring(2), inputLanguageCodes: languages)),
          account.send<td.Emojis>(td.GetKeywordEmojis(text: key.substring(2), inputLanguageCodes: languages)),
        ]);
        // Exact keyword hits first, then prefix matches.
        final emojis = {...(results[1] as td.Emojis).emojis, for (final k in (results[0] as td.EmojiKeywords).emojiKeywords) k.emoji}.toList();
        if (mounted && key == _key) {
          setState(() {
            _stickers = const [];
            _animated = null;
            _emojis = emojis;
            _hashtags = const [];
          });
        }
      }
    } on TdException catch (error) {
      debugPrint('suggestions failed: $error');
    }
  }

  /// Replaces the ":word" / "#word" being typed (from its [marker]) with [value].
  void _replaceWord(String marker, String value) {
    final c = widget.controller;
    final cursor = c.selection.baseOffset.clamp(0, c.text.length);
    final before = c.text.substring(0, cursor);
    final start = before.lastIndexOf(marker);
    if (start < 0) return;
    final next = c.text.substring(0, start) + value + c.text.substring(cursor);
    c.value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: start + value.length));
  }

  @override
  Widget build(BuildContext context) {
    if (_stickers.isEmpty && _emojis.isEmpty && _hashtags.isEmpty && _animated == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SizedBox(
        height: _stickers.isNotEmpty || _animated != null ? 76 : 48,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          children: [
            if (_animated case final animated?)
              InkWell(
                borderRadius: BorderRadius.circular(8),
                // Leaves the emoji in the field: sent as text, Telegram shows it big and animated.
                onTap: () => setState(() => _animated = null),
                child: SizedBox.square(dimension: 68, child: StickerThumb(sticker: animated)),
              ),
            for (final sticker in _stickers)
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  widget.controller.clear();
                  widget.onSticker(sticker);
                  // Picked from suggestions, so make it show up under "Recent" like a panel pick.
                  ref
                      .read(accountProvider)
                      .send<td.Stickers>(td.AddRecentSticker(isAttached: false, sticker: td.InputFileRemote(id: sticker.sticker.remote.id)))
                      .ignore();
                },
                child: SizedBox.square(dimension: 68, child: StickerThumb(sticker: sticker)),
              ),
            for (final emoji in _emojis)
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _replaceWord(':', emoji),
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Center(child: Text(emoji, style: const TextStyle(fontSize: 26)))),
              ),
            for (final tag in _hashtags)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                // Long press forgets the hashtag, like Telegram's recent hashtag list.
                child: GestureDetector(
                  onLongPress: () async {
                    await ref.read(accountProvider).send<td.Ok>(td.RemoveRecentHashtag(hashtag: tag)).catchError((Object _) => const td.Ok());
                    if (mounted) setState(() => _hashtags = [..._hashtags]..remove(tag));
                  },
                  child: ActionChip(label: Text('#$tag'), onPressed: () => _replaceWord('#', '#$tag ')),
                ),
              ),
            if (_emojis.isNotEmpty)
              Center(child: Padding(padding: const EdgeInsets.all(8), child: Text(context.t('emoji'), style: TextStyle(color: theme.hintColor, fontSize: 12)))),
          ],
        ),
      ),
    );
  }
}
