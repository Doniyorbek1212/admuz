import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/gift_models.dart';
import '../../core/api/sado_api.dart';
import '../../core/theme.dart' show brandGold;
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/emoji_pattern.dart';
import '../business/business_widgets.dart';
import 'gift_widgets.dart';

/// Backgrounds a user can put on their profile (what the server stores: "#rrggbb,#rrggbb").
const profileBackgrounds = [
  '#ff5c8a,#8b6cff', '#3d8bff,#26c6b0', '#ffb020,#ff5c39', '#0f8f7e,#26c6b0',
  '#8b6cff,#3d1e8f', '#ff7043,#c2185b', '#1f2a44,#3d5a80', '#2ec27e,#0b6e4f',
  '#c9a227,#6b4f12', '#e91e63,#ff9800', '#00bcd4,#3f51b5', '#455a64,#263238',
];

/// Header gradient for [colors] (one or two ARGB ints), fading into [base] at the bottom.
LinearGradient profileGradient(List<int> colors, Color base) {
  final top = Color(colors.first);
  final middle = Color(colors.length > 1 ? colors[1] : colors.first);
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [top, middle, base],
    stops: const [0, 0.72, 1],
  );
}

/// "#rrggbb,#rrggbb" for ARGB [colors] (the server's form), or null.
String? _backgroundValue(List<int>? colors) => colors?.map((c) => '#${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}').join(',');

/// Picks this user's profile background, colors and a sticker or emoji pattern (needs the bot-proven Telegram id),
/// and saves it on the server for UZARO users to see.
Future<void> showProfileBackgroundPicker(BuildContext context, WidgetRef ref) async {
  final current = ref.read(userGiftsProvider(ref.read(accountProvider).myId)).value;
  final picked = await showModalBottomSheet<(String?, String?)>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _BackgroundSheet(background: _backgroundValue(current?.background), pattern: current?.pattern),
  );
  if (picked == null || !context.mounted) return;
  if (!await ensureGiftsLinked(context, ref) || !context.mounted) return;
  final done = await apiGuard(context, () async {
    await ref.read(sadoApiProvider).setProfileBackground(picked.$1, picked.$2);
    return true;
  });
  if (done == true) ref.invalidate(userGiftsProvider(ref.read(accountProvider).myId));
}

class _BackgroundSheet extends ConsumerStatefulWidget {
  const _BackgroundSheet({required this.background, required this.pattern});

  final String? background;
  final String? pattern;

  @override
  ConsumerState<_BackgroundSheet> createState() => _BackgroundSheetState();
}

class _BackgroundSheetState extends ConsumerState<_BackgroundSheet> {
  late String? _background = widget.background;
  late String? _pattern = widget.pattern;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final colors = parseBackground(_background);
    final pattern = _pattern;
    final me = ref.read(accountProvider).myId;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(s.t('gifts_background'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 2, 24, 0),
            child: Text(s.t('gifts_background_hint'), textAlign: TextAlign.center, style: TextStyle(color: theme.hintColor)),
          ),
          // Live preview: the header as others will see it.
          Container(
            height: 150,
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: brandGold.withValues(alpha: 0.6)),
              color: theme.colorScheme.surfaceContainerHighest,
              gradient: colors == null ? null : profileGradient(colors, theme.colorScheme.surfaceContainerHighest),
            ),
            child: Stack(fit: StackFit.expand, children: [
              if (pattern != null) EmojiPattern(pattern: pattern, spots: headerPatternSpots, scale: 0.8),
              Center(child: UserAvatar(userId: me, size: 76, showOnline: false)),
            ]),
          ),
          SizedBox(
            height: 56,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              PatternChoice(
                selected: _background == null,
                onTap: () => setState(() => _background = null),
                label: s.t('gifts_background_none'),
                child: CircleAvatar(radius: 19, backgroundColor: theme.colorScheme.surfaceContainerHighest, child: const Icon(Icons.block_rounded, size: 18)),
              ),
              for (final value in profileBackgrounds)
                PatternChoice(
                  selected: value == _background,
                  onTap: () => setState(() => _background = value),
                  label: value,
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(colors: [for (final c in parseBackground(value)!) Color(c)]),
                    ),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 8),
          Expanded(child: EmojiPatternPicker(selected: pattern, onPicked: (value) => setState(() => _pattern = value))),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: FilledButton(
              onPressed: () => Navigator.pop(context, (_background, _pattern)),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              child: Text(s.t('save')),
            ),
          ),
        ]),
      ),
    );
  }
}
