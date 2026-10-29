import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../../widgets/custom_emoji.dart';
import 'composer_panels.dart' show StickerThumb;
import 'sticker_sets.dart' show showStickerSetSheet;

// ------------------------------------------------------------------ greeting sticker

final _greetingProvider = FutureProvider.autoDispose<td.Sticker?>((ref) async {
  final stickers = (await ref.watch(accountProvider).send<td.Stickers>(const td.GetGreetingStickers())).stickers;
  return stickers.isEmpty ? null : stickers[Random().nextInt(stickers.length)];
});

/// Empty private chat: a "say hi" sticker that is sent with one tap, as in Telegram; [fallback] until one loads.
class GreetingStickerCard extends ConsumerWidget {
  const GreetingStickerCard({super.key, required this.chatId, required this.fallback});

  final int chatId;
  final Widget fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sticker = ref.watch(_greetingProvider).value;
    if (sticker == null) return fallback;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => guard(context, () => ref.read(accountProvider).sendSticker(chatId, sticker)),
      child: Padding(padding: const EdgeInsets.all(8), child: SizedBox.square(dimension: 120, child: StickerThumb(sticker: sticker))),
    );
  }
}

// ------------------------------------------------------------------ stickers attached to a photo

/// Sticker sets used on a photo (photo.has_stickers); one opens straight away, several are listed.
Future<void> showAttachedStickerSets(BuildContext context, TelegramAccount account, int fileId) async {
  final sets = await guard(context, () => account.send<td.StickerSets>(td.GetAttachedStickerSets(fileId: fileId)));
  if (sets == null || !context.mounted) return;
  if (sets.sets.length == 1) return showStickerSetSheet(context, sets.sets.first.id);
  final picked = await showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        if (sets.sets.isEmpty) ListTile(title: Text(context.t('nothing_found'))),
        for (final set in sets.sets)
          ListTile(
            leading: set.covers.isEmpty ? const Icon(Icons.emoji_emotions_outlined) : SizedBox.square(dimension: 40, child: StickerThumb(sticker: set.covers.first)),
            title: Text(set.title),
            subtitle: Text(context.s.count('stickers_count', set.size)),
            onTap: () => Navigator.pop(context, set.id),
          ),
      ]),
    ),
  );
  if (picked != null && context.mounted) await showStickerSetSheet(context, picked);
}

// ------------------------------------------------------------------ emoji avatars

/// Profile or group photo made from an emoji on a colored background (Telegram's "Use emoji").
/// [chatId] null sets the user's own photo.
Future<void> pickEmojiPhoto(BuildContext context, TelegramAccount account, {int? chatId}) async {
  final s = context.s;
  final stickers = await guard(
    context,
    () => account.send<td.Stickers>(chatId == null ? const td.GetDefaultProfilePhotoCustomEmojiStickers() : const td.GetDefaultChatPhotoCustomEmojiStickers()),
  );
  if (stickers == null || !context.mounted) return;
  const colors = [0x5EB5F7, 0x7BC862, 0xEE7AAE, 0xFAA774, 0x6FB9F0, 0xE17076, 0x8E85EE, 0x404650];
  var color = colors.first;
  final emojiId = await showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(s.t('emoji_photo'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final c in colors)
                GestureDetector(
                  onTap: () => setSheet(() => color = c),
                  child: CircleAvatar(
                    radius: 16,
                    backgroundColor: Color(0xFF000000 | c),
                    child: c == color ? const Icon(Icons.check_rounded, size: 16, color: Colors.white) : null,
                  ),
                ),
            ]),
            Flexible(
              child: GridView.count(
                crossAxisCount: 6,
                shrinkWrap: true,
                padding: const EdgeInsets.all(12),
                children: [
                  for (final sticker in stickers.stickers)
                    if (sticker.fullType case td.StickerFullTypeCustomEmoji(:final customEmojiId))
                      InkWell(
                        onTap: () => Navigator.pop(context, customEmojiId),
                        child: CircleAvatar(
                          backgroundColor: Color(0xFF000000 | color),
                          child: CustomEmojiView(id: customEmojiId, size: 28, fallback: sticker.emoji),
                        ),
                      ),
                ],
              ),
            ),
          ]),
        ),
      ),
    ),
  );
  if (emojiId == null || !context.mounted) return;
  final photo = td.InputChatPhotoSticker(
    sticker: td.ChatPhotoSticker(type: td.ChatPhotoStickerTypeCustomEmoji(customEmojiId: emojiId), backgroundFill: td.BackgroundFillSolid(color: color)),
  );
  await guard(
    context,
    () => chatId == null
        ? account.send<td.ChatPhoto>(td.SetProfilePhoto(photo: photo, isPublic: false))
        : account.send<td.Ok>(td.SetChatPhoto(chatId: chatId, photo: photo)),
  );
}

/// Gallery or emoji: the two ways to make a new profile/group photo. Returns the gallery path, or null.
Future<String?> pickPhotoSource(BuildContext context, TelegramAccount account, {int? chatId}) async {
  final s = context.s;
  final source = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.photo_library_rounded), title: Text(s.t('choose_from_gallery')), onTap: () => Navigator.pop(context, 'gallery')),
        ListTile(leading: const Icon(Icons.emoji_emotions_outlined), title: Text(s.t('emoji_photo')), onTap: () => Navigator.pop(context, 'emoji')),
      ]),
    ),
  );
  if (source == null || !context.mounted) return null;
  if (source == 'emoji') {
    await pickEmojiPhoto(context, account, chatId: chatId);
    return null;
  }
  return pickGalleryImage();
}

// ------------------------------------------------------------------ name/profile background emoji

/// Emoji drawn as a pattern behind the user's or channel's name color; 0 removes it.
Future<int?> pickBackgroundEmoji(BuildContext context, TelegramAccount account) async {
  final stickers = await guard(context, () => account.send<td.Stickers>(const td.GetDefaultBackgroundCustomEmojiStickers()));
  if (stickers == null || !context.mounted) return null;
  return showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
        child: GridView.count(
          crossAxisCount: 6,
          shrinkWrap: true,
          padding: const EdgeInsets.all(12),
          children: [
            IconButton(tooltip: context.t('none'), icon: const Icon(Icons.block_rounded), onPressed: () => Navigator.pop(context, 0)),
            for (final sticker in stickers.stickers)
              if (sticker.fullType case td.StickerFullTypeCustomEmoji(:final customEmojiId))
                InkWell(onTap: () => Navigator.pop(context, customEmojiId), child: Center(child: CustomEmojiView(id: customEmojiId, size: 30, fallback: sticker.emoji))),
          ],
        ),
      ),
    ),
  );
}

// ------------------------------------------------------------------ outlines while a sticker loads

final _outlineProvider = FutureProvider.autoDispose.family<td.Outline?, int>((ref, fileId) async {
  try {
    return await ref.watch(accountProvider).send<td.Outline>(td.GetStickerOutline(stickerFileId: fileId, forAnimatedEmoji: false, forClickedAnimatedEmojiMessage: false));
  } on TdException {
    return null;
  }
});

final _svgOutlineProvider = FutureProvider.autoDispose.family<String?, int>((ref, fileId) async {
  try {
    return (await ref.watch(accountProvider).send<td.Text>(td.GetStickerOutlineSvgPath(stickerFileId: fileId, forAnimatedEmoji: false, forClickedAnimatedEmojiMessage: false))).text;
  } on TdException {
    return null;
  }
});

/// Grey silhouette of a sticker (from TDLib's vector outline) shown until the sticker file arrives.
class StickerOutlinePlaceholder extends ConsumerWidget {
  const StickerOutlinePlaceholder({super.key, required this.sticker, required this.size, this.useSvgPath = false});

  final td.Sticker sticker;
  final double size;

  /// Small thumbnails use TDLib's SVG path string; big stickers the structured outline.
  final bool useSvgPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = Theme.of(context).hintColor.withValues(alpha: 0.25);
    final Path? path = useSvgPath
        ? switch (ref.watch(_svgOutlineProvider(sticker.sticker.id)).value) {
            final svg? when svg.isNotEmpty => parseSvgPath(svg),
            _ => null,
          }
        : switch (ref.watch(_outlineProvider(sticker.sticker.id)).value) {
            final outline? => outlinePath(outline),
            null => null,
          };
    if (path == null) return SizedBox.square(dimension: size, child: Center(child: Text(sticker.emoji, style: TextStyle(fontSize: size * 0.5))));
    return SizedBox.square(dimension: size, child: CustomPaint(painter: _OutlinePainter(path, color)));
  }
}

/// TDLib outlines are drawn in a 512×512 box.
const _outlineBox = 512.0;

Path outlinePath(td.Outline outline) {
  final path = Path();
  for (final closed in outline.paths) {
    var first = true;
    for (final command in closed.commands) {
      switch (command) {
        case td.VectorPathCommandLine(:final endPoint):
          first ? path.moveTo(endPoint.x, endPoint.y) : path.lineTo(endPoint.x, endPoint.y);
        case td.VectorPathCommandCubicBezierCurve(:final startControlPoint, :final endControlPoint, :final endPoint):
          if (first) path.moveTo(endPoint.x, endPoint.y);
          path.cubicTo(startControlPoint.x, startControlPoint.y, endControlPoint.x, endControlPoint.y, endPoint.x, endPoint.y);
      }
      first = false;
    }
    path.close();
  }
  return path;
}

/// Minimal SVG path reader for TDLib's outlines: M/L/C/Z (absolute and relative) with numbers.
Path parseSvgPath(String data) {
  final path = Path();
  final tokens = RegExp(r'[MmLlCcZz]|-?\d*\.?\d+(?:e-?\d+)?').allMatches(data).map((m) => m.group(0)!).toList();
  var i = 0;
  var command = 'M';
  var x = 0.0, y = 0.0;
  double next() => double.parse(tokens[i++]);
  bool hasNumber() => i < tokens.length && !RegExp(r'^[A-Za-z]$').hasMatch(tokens[i]);
  while (i < tokens.length) {
    if (!hasNumber()) command = tokens[i++];
    final relative = command == command.toLowerCase();
    switch (command.toUpperCase()) {
      case 'M':
        x = (relative ? x : 0) + next();
        y = (relative ? y : 0) + next();
        path.moveTo(x, y);
        command = relative ? 'l' : 'L';
      case 'L':
        x = (relative ? x : 0) + next();
        y = (relative ? y : 0) + next();
        path.lineTo(x, y);
      case 'C':
        final ox = relative ? x : 0.0, oy = relative ? y : 0.0;
        final c1x = ox + next(), c1y = oy + next(), c2x = ox + next(), c2y = oy + next();
        x = ox + next();
        y = oy + next();
        path.cubicTo(c1x, c1y, c2x, c2y, x, y);
      case 'Z':
        path.close();
      default:
        i++;
    }
  }
  return path;
}

class _OutlinePainter extends CustomPainter {
  _OutlinePainter(this.path, this.color);

  final Path path;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / _outlineBox, size.height / _outlineBox);
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_OutlinePainter old) => old.path != path || old.color != color;
}

// ------------------------------------------------------------------ reactions

final emojiReactionProvider = FutureProvider.autoDispose.family<td.EmojiReaction?, String>((ref, emoji) async {
  try {
    return await ref.watch(accountProvider).send<td.EmojiReaction>(td.GetEmojiReaction(emoji: emoji));
  } on TdException {
    return null;
  }
});

final customReactionEffectsProvider = FutureProvider.autoDispose<List<td.Sticker>>((ref) async {
  try {
    return (await ref.watch(accountProvider).send<td.Stickers>(const td.GetCustomEmojiReactionAnimations())).stickers;
  } on TdException {
    return const [];
  }
});
