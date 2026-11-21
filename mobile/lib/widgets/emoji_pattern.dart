import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../core/tdlib/td_client.dart';
import '../core/theme.dart' show brandGold;
import '../l10n/strings.dart';
import '../state/providers.dart';
import 'custom_emoji.dart';

/// One spot of a pattern: where, how big, how strong.
typedef PatternSpot = (Alignment alignment, double size, double opacity);

/// Over a chat row: bigger and stronger at the right edge, fading towards the name.
const rowPatternSpots = <PatternSpot>[
  (Alignment(0.97, -0.5), 28, 0.72),
  (Alignment(0.83, 0.62), 22, 0.6),
  (Alignment(0.69, -0.45), 19, 0.48),
  (Alignment(0.55, 0.6), 16, 0.38),
  (Alignment(0.41, -0.4), 14, 0.28),
  (Alignment(0.27, 0.55), 12, 0.2),
];

/// Over a profile header: two mirrored wings around the avatar in the middle, like Telegram's profile pattern.
const headerPatternSpots = <PatternSpot>[
  (Alignment(-0.5, -0.62), 30, 0.55),
  (Alignment(0.5, -0.62), 30, 0.55),
  (Alignment(-0.62, -0.05), 26, 0.48),
  (Alignment(0.62, -0.05), 26, 0.48),
  (Alignment(-0.48, 0.5), 24, 0.42),
  (Alignment(0.48, 0.5), 24, 0.42),
  (Alignment(-0.88, -0.38), 22, 0.32),
  (Alignment(0.88, -0.38), 22, 0.32),
  (Alignment(-0.9, 0.3), 20, 0.26),
  (Alignment(0.9, 0.3), 20, 0.26),
  (Alignment(-0.22, -0.92), 18, 0.3),
  (Alignment(0.22, -0.92), 18, 0.3),
];

/// [pattern] (a custom emoji id as digits, or a plain emoji) scattered at [spots]; still pictures, no taps.
class EmojiPattern extends StatelessWidget {
  const EmojiPattern({super.key, required this.pattern, this.spots = rowPatternSpots, this.scale = 1});

  final String pattern;
  final List<PatternSpot> spots;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final customEmoji = int.tryParse(pattern);
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Stack(fit: StackFit.expand, children: [
          for (final (alignment, size, opacity) in spots)
            Align(
              alignment: alignment,
              child: Opacity(
                opacity: opacity,
                child: customEmoji != null
                    ? CustomEmojiView(id: customEmoji, size: size * scale)
                    : Text(pattern, style: TextStyle(fontSize: size * scale * 0.82, height: 1)),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Stickers (Telegram's colorful status emoji) or plain emoji to pick a pattern from; [onPicked] gets null to clear.
class EmojiPatternPicker extends ConsumerStatefulWidget {
  const EmojiPatternPicker({super.key, required this.selected, required this.onPicked});

  final String? selected;
  final ValueChanged<String?> onPicked;

  @override
  ConsumerState<EmojiPatternPicker> createState() => _EmojiPatternPickerState();
}

class _EmojiPatternPickerState extends ConsumerState<EmojiPatternPicker> {
  late final Future<List<int>> _stickers = _loadStickers();
  bool _emoji = false;

  Future<List<int>> _loadStickers() async {
    final account = ref.read(accountProvider);
    try {
      final lists = await Future.wait([
        account.send<td.EmojiStatusCustomEmojis>(const td.GetThemedEmojiStatuses()),
        account.send<td.EmojiStatusCustomEmojis>(const td.GetDefaultEmojiStatuses()),
      ]);
      return {for (final list in lists) ...list.customEmojiIds}.toList();
    } on TdException catch (error) {
      debugPrint('pattern stickers unavailable: $error');
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Row(children: [
          Expanded(
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: false, icon: const Icon(Icons.emoji_nature_rounded), label: Text(s.t('chat_pattern_stickers'))),
                ButtonSegment(value: true, icon: const Icon(Icons.emoji_emotions_outlined), label: Text(s.t('chat_pattern_emoji'))),
              ],
              selected: {_emoji},
              onSelectionChanged: (value) => setState(() => _emoji = value.first),
            ),
          ),
          if (widget.selected != null)
            IconButton(tooltip: s.t('chat_sticker_none'), icon: const Icon(Icons.block_rounded), onPressed: () => widget.onPicked(null)),
        ]),
      ),
      Expanded(child: _emoji ? _emojiPicker(theme) : _stickerGrid(s)),
    ]);
  }

  Widget _stickerGrid(Strings s) => FutureBuilder<List<int>>(
        future: _stickers,
        builder: (context, snapshot) {
          final ids = snapshot.data;
          if (ids == null) return const Center(child: CircularProgressIndicator());
          return GridView.count(
            crossAxisCount: 6,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final id in ids)
                PatternChoice(
                  selected: '$id' == widget.selected,
                  onTap: () => widget.onPicked('$id'),
                  label: s.t('chat_pattern_stickers'),
                  child: CustomEmojiView(id: id, size: 30),
                ),
            ],
          );
        },
      );

  Widget _emojiPicker(ThemeData theme) => LayoutBuilder(
        builder: (context, box) => EmojiPicker(
          onEmojiSelected: (_, emoji) => widget.onPicked(emoji.emoji),
          config: Config(
            height: box.maxHeight,
            emojiViewConfig: EmojiViewConfig(backgroundColor: theme.colorScheme.surface, emojiSizeMax: 30),
            categoryViewConfig: CategoryViewConfig(
              backgroundColor: theme.colorScheme.surface,
              indicatorColor: brandGold,
              iconColorSelected: brandGold,
            ),
            bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
            searchViewConfig: SearchViewConfig(backgroundColor: theme.colorScheme.surface),
          ),
        ),
      );
}

/// One pickable swatch, sticker or emoji; the picked one gets a gold frame.
class PatternChoice extends StatelessWidget {
  const PatternChoice({super.key, required this.selected, required this.onTap, required this.label, required this.child});

  final bool selected;
  final VoidCallback onTap;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: selected ? brandGold : Colors.transparent, width: 2),
            ),
            child: child,
          ),
        ),
      );
}
