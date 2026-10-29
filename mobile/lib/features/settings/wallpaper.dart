import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../state/telegram.dart';
import '../../widgets/chat_pattern.dart';
import '../../widgets/common.dart';
import 'gifts_extras.dart' show giftChatThemesProvider;

const _gradients = <List<Color>>[
  [Color(0xFFDCE8F5), Color(0xFFB7D3F0)],
  [Color(0xFFE8F5E9), Color(0xFFB9E4C9)],
  [Color(0xFFFFF3E0), Color(0xFFFFCC80)],
  [Color(0xFFF3E5F5), Color(0xFFD1C4E9)],
  [Color(0xFF1F2A44), Color(0xFF3A4F7A)],
  [Color(0xFF0F2027), Color(0xFF2C5364)],
];

const _solids = <Color>[
  Color(0xFFE6EBEE),
  Color(0xFFD8E4D2),
  Color(0xFFF2E6D9),
  Color(0xFFE3DCF2),
  Color(0xFF1C2733),
  Color(0xFF101418),
];

Color _argb(int rgb) => Color(0xFF000000 | rgb);

/// Decoration for a Telegram fill; freeform gradients are drawn with their first two colors.
BoxDecoration _fillDecoration(td.BackgroundFill fill) => switch (fill) {
      td.BackgroundFillSolid(:final color) => BoxDecoration(color: _argb(color)),
      td.BackgroundFillGradient(:final topColor, :final bottomColor) =>
        BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_argb(topColor), _argb(bottomColor)])),
      td.BackgroundFillFreeformGradient(:final colors) when colors.length >= 2 =>
        BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [for (final c in colors) _argb(c)])),
      _ => const BoxDecoration(),
    };

/// The chat's own Telegram background, or its emoji theme's one; null when it has neither.
td.Background? telegramBackground(TelegramAccount account, td.Chat chat, {required bool dark}) {
  if (chat.background?.background case final background?) return background;
  if (chat.theme case td.ChatThemeEmoji(:final name)) {
    final theme = account.emojiChatThemes.where((t) => t.name == name).firstOrNull;
    return (dark ? theme?.darkSettings : theme?.lightSettings)?.background;
  }
  return null;
}

/// Chat background: the chat's Telegram background when set, else the one chosen in Appearance.
class ChatBackground extends ConsumerWidget {
  const ChatBackground({super.key, required this.child, this.chatId});

  final Widget child;
  final int? chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final chat = chatId == null ? null : ref.watch(chatProvider(chatId!));
    final background = chat == null ? null : telegramBackground(ref.watch(accountProvider), chat, dark: dark);
    if (background != null) {
      final dim = dark ? (chat?.background?.darkThemeDimming ?? 0) / 100 : 0.0;
      final fill = switch (background.type) {
        td.BackgroundTypeFill(:final fill) || td.BackgroundTypePattern(:final fill) => _fillDecoration(fill),
        _ => BoxDecoration(color: context.chatColors.chatBackground),
      };
      final document = background.document;
      // shortcut: pattern backgrounds show only their fill (the pattern is a TGV/SVG file); render it if users ask.
      return DecoratedBox(
        decoration: fill,
        child: Stack(fit: StackFit.expand, children: [
          if (background.type is td.BackgroundTypeWallpaper && document != null) TdImage(file: document.document, fit: BoxFit.cover),
          if (dim > 0) ColoredBox(color: Colors.black.withValues(alpha: dim)),
          child,
        ]),
      );
    }
    final wallpaper = ref.watch(settingsProvider.select((s) => s.wallpaper));
    final fallback = context.chatColors.chatBackground;
    BoxDecoration decoration;
    if (wallpaper.startsWith('color:')) {
      decoration = BoxDecoration(color: Color(int.tryParse(wallpaper.substring(6), radix: 16) ?? fallback.toARGB32()));
    } else if (wallpaper.startsWith('gradient:')) {
      final index = (int.tryParse(wallpaper.substring(9)) ?? 0).clamp(0, _gradients.length - 1);
      decoration = BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: _gradients[index]));
    } else if (wallpaper.startsWith('file:') && File(wallpaper.substring(5)).existsSync()) {
      decoration = BoxDecoration(
        color: fallback,
        image: DecorationImage(
          image: FileImage(File(wallpaper.substring(5))),
          fit: BoxFit.cover,
          // Dim photo backgrounds in dark mode so bubbles stay readable.
          colorFilter: dark ? const ColorFilter.mode(Colors.black45, BlendMode.darken) : null,
        ),
      );
    } else {
      decoration = BoxDecoration(color: fallback);
    }
    final pattern = ref.watch(settingsProvider.select((s) => s.wallpaperPattern)) && !wallpaper.startsWith('file:');
    return DecoratedBox(
      decoration: decoration,
      child: pattern
          ? Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(
                  child: CustomPaint(painter: ChatPatternPainter(color: dark ? Colors.white.withValues(alpha: 0.035) : Colors.black.withValues(alpha: 0.055))),
                ),
                child,
              ],
            )
          : child,
    );
  }
}

final _installedBackgroundsProvider = FutureProvider.autoDispose.family<List<td.Background>, bool>(
  (ref, dark) async => (await ref.watch(accountProvider).send<td.Backgrounds>(td.GetInstalledBackgrounds(forDarkTheme: dark))).backgrounds,
);

/// Backgrounds saved to the user's Telegram account; tap applies one, long press shares or removes it.
class _InstalledBackgrounds extends ConsumerWidget {
  const _InstalledBackgrounds({required this.onPick});

  final ValueChanged<td.Background> onPick;

  Future<void> _menu(BuildContext context, WidgetRef ref, td.Background background, bool dark) async {
    final s = context.s;
    final account = ref.read(accountProvider);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.share_rounded), title: Text(s.t('share')), onTap: () => Navigator.pop(context, 'share')),
          ListTile(leading: const Icon(Icons.delete_outline_rounded), title: Text(s.t('delete')), onTap: () => Navigator.pop(context, 'delete')),
        ]),
      ),
    );
    if (action == null || !context.mounted) return;
    if (action == 'share') {
      final url = await guard(context, () => account.send<td.HttpUrl>(td.GetBackgroundUrl(name: background.name, type: background.type)));
      if (url != null) await SharePlus.instance.share(ShareParams(text: url.url));
    } else {
      await guard(context, () => account.send<td.Ok>(td.RemoveInstalledBackground(backgroundId: background.id)));
    }
    ref.invalidate(_installedBackgroundsProvider(dark));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final backgrounds = ref.watch(_installedBackgroundsProvider(dark)).value ?? const [];
    if (backgrounds.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(s.t('telegram_backgrounds'), style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600))),
        TextButton(
          onPressed: () async {
            final ok = await confirm(context, title: s.t('telegram_backgrounds_reset'), destructive: true);
            if (!ok || !context.mounted) return;
            await guard(context, () => ref.read(accountProvider).send<td.Ok>(const td.ResetInstalledBackgrounds()));
            ref.invalidate(_installedBackgroundsProvider(dark));
          },
          child: Text(s.t('wallpaper_reset')),
        ),
      ]),
      SizedBox(
        height: 120,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: backgrounds.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final b = backgrounds[index];
            final thumb = b.document?.thumbnail?.file ?? b.document?.document;
            return GestureDetector(
              onTap: () => onPick(b),
              onLongPress: () => _menu(context, ref, b, dark),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 80,
                  child: DecoratedBox(
                    decoration: switch (b.type) {
                      td.BackgroundTypeFill(:final fill) || td.BackgroundTypePattern(:final fill) => _fillDecoration(fill),
                      _ => BoxDecoration(color: context.chatColors.chatBackground),
                    },
                    child: b.type is td.BackgroundTypeWallpaper && thumb != null ? TdImage(file: thumb, fit: BoxFit.cover) : null,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

/// Appearance → Chat background for every chat, or (with [chatId]) the Telegram background and theme of one chat.
class WallpaperScreen extends ConsumerWidget {
  const WallpaperScreen({super.key, this.chatId});

  final int? chatId;

  /// Sets this chat's background on Telegram; only for the user unless it is a group/channel the user manages.
  Future<void> _setChat(BuildContext context, WidgetRef ref, {td.InputBackground? input, td.BackgroundType? type}) async {
    final account = ref.read(accountProvider);
    final chat = account.chats[chatId];
    await guard(
      context,
      () => account.send<td.Ok>(td.SetChatBackground(
        chatId: chatId!,
        background: input,
        type: type,
        darkThemeDimming: 0,
        onlyForSelf: chat != null && account.privateUser(chat) != null,
      )),
    );
  }

  Future<void> _pickPhoto(BuildContext context, WidgetRef ref) async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 2000);
    if (picked == null) return;
    if (chatId != null) {
      if (!context.mounted) return;
      return _setChat(
        context,
        ref,
        input: td.InputBackgroundLocal(background: td.InputFileLocal(path: picked.path)),
        type: const td.BackgroundTypeWallpaper(isBlurred: false, isMoving: false),
      );
    }
    final dir = await getApplicationSupportDirectory();
    final target = File('${dir.path}${Platform.pathSeparator}wallpaper_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await File(picked.path).copy(target.path);
    final previous = ref.read(settingsProvider).wallpaper;
    ref.read(settingsProvider.notifier).setWallpaper('file:${target.path}');
    if (previous.startsWith('file:')) {
      final old = File(previous.substring(5));
      if (await old.exists()) await old.delete();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final current = ref.watch(settingsProvider.select((st) => st.wallpaper));
    final notifier = ref.read(settingsProvider.notifier);
    final primary = Theme.of(context).colorScheme.primary;
    final chatId = this.chatId;
    final account = ref.watch(accountProvider);
    final chat = chatId == null ? null : ref.watch(chatProvider(chatId));
    final themeName = switch (chat?.theme) {
      td.ChatThemeEmoji(:final name) => name,
      _ => '',
    };
    // Per chat, a swatch becomes a Telegram fill of the same colors.
    void pick(String value) {
      if (chatId == null) return notifier.setWallpaper(value);
      final td.BackgroundFill fill;
      if (value.startsWith('gradient:')) {
        final colors = _gradients[int.parse(value.substring(9))];
        fill = td.BackgroundFillGradient(topColor: colors[0].toARGB32() & 0xFFFFFF, bottomColor: colors[1].toARGB32() & 0xFFFFFF, rotationAngle: 0);
      } else {
        fill = td.BackgroundFillSolid(color: (int.tryParse(value.substring(6), radix: 16) ?? 0) & 0xFFFFFF);
      }
      _setChat(context, ref, type: td.BackgroundTypeFill(fill: fill));
    }

    Widget swatch(String value, Decoration decoration, {Widget? child}) => GestureDetector(
          onTap: () => pick(value),
          child: Container(
            decoration: decoration,
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: chatId == null && current == value ? primary : Colors.transparent, width: 3),
            ),
            child: child,
          ),
        );
    return Scaffold(
      appBar: AppBar(title: Text(s.t('chat_background'))),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          SizedBox(
            height: 220,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: ChatBackground(
                chatId: chatId,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(color: context.chatColors.incomingBubble, borderRadius: BorderRadius.circular(16)),
                    child: Text(s.t('wallpaper_preview'), style: TextStyle(color: context.chatColors.incomingText)),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickPhoto(context, ref),
                  icon: const Icon(Icons.photo_library_rounded),
                  label: Text(s.t('wallpaper_from_gallery')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: chatId == null
                      ? () => notifier.setWallpaper('')
                      : () => guard(context, () => account.send<td.Ok>(td.DeleteChatBackground(chatId: chatId, restorePrevious: false))),
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: Text(s.t('wallpaper_reset')),
                ),
              ),
            ],
          ),
          if (chatId == null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(s.t('wallpaper_pattern')),
              value: ref.watch(settingsProvider.select((st) => st.wallpaperPattern)),
              onChanged: notifier.setWallpaperPattern,
            )
          else if (account.emojiChatThemes.isNotEmpty) ...[
            Padding(padding: const EdgeInsets.fromLTRB(4, 12, 4, 6), child: Text(s.t('chat_theme'), style: TextStyle(color: primary, fontWeight: FontWeight.w600))),
            SizedBox(
              height: 64,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final theme in [null, ...account.emojiChatThemes])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(theme == null ? '✖' : theme.name, style: const TextStyle(fontSize: 22)),
                      selected: (theme?.name ?? '') == themeName,
                      onSelected: (_) => guard(
                        context,
                        () => account.send<td.Ok>(td.SetChatTheme(chatId: chatId, theme: theme == null ? null : td.InputChatThemeEmoji(name: theme.name))),
                      ),
                    ),
                  ),
              ]),
            ),
          ],
          // Themes from unique gifts the user owns.
          if (chatId != null)
            if (ref.watch(giftChatThemesProvider).value case final themes? when themes.isNotEmpty)
              SizedBox(
                height: 56,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final theme in themes)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        label: Text('${theme.gift.title} #${theme.gift.number}'),
                        onPressed: () => guard(context, () => account.send<td.Ok>(td.SetChatTheme(chatId: chatId, theme: td.InputChatThemeGift(name: theme.gift.name)))),
                      ),
                    ),
                ]),
              ),
          if (chatId != null) _InstalledBackgrounds(onPick: (b) => _setChat(context, ref, input: td.InputBackgroundRemote(backgroundId: b.id), type: b.type))
          else
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.layers_clear_rounded),
              title: Text(s.t('telegram_default_bg_delete')),
              subtitle: Text(s.t('telegram_default_bg_delete_hint')),
              onTap: () async {
                final dark = Theme.of(context).brightness == Brightness.dark;
                await guard(context, () => account.send<td.Ok>(td.DeleteDefaultBackground(forDarkTheme: dark)));
                if (context.mounted) showToast(context, s.t('done'));
              },
            ),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.7,
            children: [
              for (var i = 0; i < _gradients.length; i++)
                swatch(
                  'gradient:$i',
                  BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: _gradients[i]),
                  ),
                ),
              for (final color in _solids)
                swatch(
                  'color:${color.toARGB32().toRadixString(16).padLeft(8, '0')}',
                  BoxDecoration(borderRadius: BorderRadius.circular(12), color: color),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
