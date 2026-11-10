import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/gift_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
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

/// Picks this user's profile background (needs the bot-proven Telegram id) and saves it on the server.
Future<void> showProfileBackgroundPicker(BuildContext context, WidgetRef ref) async {
  final picked = await showModalBottomSheet<(String?,)>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final s = context.s;
      Widget swatch(String? value, {required Widget child, required String label}) => Semantics(
            button: true,
            label: label,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => Navigator.pop(context, (value,)),
              child: child,
            ),
          );
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.t('gifts_background'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(s.t('gifts_background_hint'), style: TextStyle(color: Theme.of(context).hintColor)),
            const SizedBox(height: 16),
            Wrap(spacing: 14, runSpacing: 14, children: [
              swatch(
                null,
                label: s.t('gifts_background_none'),
                child: CircleAvatar(
                  radius: 26,
                  backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.block_rounded),
                ),
              ),
              for (final value in profileBackgrounds)
                swatch(
                  value,
                  label: value,
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(colors: [for (final c in parseBackground(value)!) Color(c)]),
                    ),
                  ),
                ),
            ]),
          ]),
        ),
      );
    },
  );
  if (picked == null || !context.mounted) return;
  if (!await ensureGiftsLinked(context, ref) || !context.mounted) return;
  final done = await apiGuard(context, () async {
    await ref.read(sadoApiProvider).setProfileBackground(picked.$1);
    return true;
  });
  if (done == true) ref.invalidate(userGiftsProvider(ref.read(accountProvider).myId));
}
