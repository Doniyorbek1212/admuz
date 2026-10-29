import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/custom_emoji.dart';
import '../chat/sticker_extras.dart' show pickBackgroundEmoji;

Color _rgb(int value) => Color(0xFF000000 | value);

/// Name color (shown on replies and links) and profile color, for the user or — with [chatId] — a channel.
/// Telegram asks for Premium (users) or boost levels (channels) and reports an error otherwise.
class ProfileColorsScreen extends ConsumerWidget {
  const ProfileColorsScreen({super.key, this.chatId});

  final int? chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final chat = chatId == null ? null : ref.watch(chatProvider(chatId!));
    final me = ref.watch(meProvider);
    final nameColor = chat?.accentColorId ?? me?.accentColorId ?? 0;
    final profileColor = chat?.profileAccentColorId ?? me?.profileAccentColorId ?? -1;
    // Changing a color keeps the chosen background emoji, and the other way round.
    final nameEmoji = chat?.backgroundCustomEmojiId ?? me?.backgroundCustomEmojiId ?? 0;
    final profileEmoji = chat?.profileBackgroundCustomEmojiId ?? me?.profileBackgroundCustomEmojiId ?? 0;

    Future<void> setName(int id, {int? emoji}) => guard(
          context,
          () => account.send<td.Ok>(chatId == null
              ? td.SetAccentColor(accentColorId: id, backgroundCustomEmojiId: emoji ?? nameEmoji)
              : td.SetChatAccentColor(chatId: chatId!, accentColorId: id, backgroundCustomEmojiId: emoji ?? nameEmoji)),
        );
    Future<void> setProfile(int id, {int? emoji}) => guard(
          context,
          () => account.send<td.Ok>(chatId == null
              ? td.SetProfileAccentColor(profileAccentColorId: id, profileBackgroundCustomEmojiId: emoji ?? profileEmoji)
              : td.SetChatProfileAccentColor(chatId: chatId!, profileAccentColorId: id, profileBackgroundCustomEmojiId: emoji ?? profileEmoji)),
        );
    Widget emojiTile(String label, int current, Future<void> Function(int emoji) set) => ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          trailing: current == 0 ? Text(s.t('none')) : CustomEmojiView(id: current, size: 26),
          onTap: () async {
            final picked = await pickBackgroundEmoji(context, account);
            if (picked != null) await set(picked);
          },
        );

    Widget swatch(List<int> colors, bool selected, VoidCallback onTap) => GestureDetector(
          onTap: onTap,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: colors.length > 1 ? LinearGradient(colors: [for (final c in colors) _rgb(c)]) : null,
              color: colors.length == 1 ? _rgb(colors.first) : null,
              border: selected ? Border.all(color: Theme.of(context).colorScheme.onSurface, width: 3) : null,
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: Text(s.t('profile_colors'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (chatId == null && me?.isPremium != true) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(s.t('profile_colors_premium'))),
        Text(s.t('name_color'), style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, children: [
          for (final color in account.accentColors)
            swatch(dark ? color.darkThemeColors : color.lightThemeColors, color.id == nameColor, () => setName(color.id)),
        ]),
        emojiTile(s.t('background_emoji'), nameEmoji, (emoji) => setName(nameColor, emoji: emoji)),
        const SizedBox(height: 24),
        Text(s.t('profile_color'), style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, children: [
          GestureDetector(
            onTap: () => setProfile(-1),
            child: CircleAvatar(radius: 22, child: Icon(profileColor == -1 ? Icons.check_rounded : Icons.block_rounded)),
          ),
          for (final color in account.profileAccentColors)
            swatch(
              (dark ? color.darkThemeColors : color.lightThemeColors).backgroundColors,
              color.id == profileColor,
              () => setProfile(color.id),
            ),
        ]),
        if (profileColor != -1) emojiTile(s.t('background_emoji'), profileEmoji, (emoji) => setProfile(profileColor, emoji: emoji)),
      ]),
    );
  }
}
