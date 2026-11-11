import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/theme.dart' show brandGold;
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/emoji_pattern.dart';
import '../gifts/gift_showcase.dart' show GiftDrift;

/// Colors a chat row can be tinted with (Telegram's name color palette).
const chatTintColors = [0xFF3E88F7, 0xFF34C759, 0xFFFF9500, 0xFFFF3B30, 0xFFAF52DE, 0xFF20B2C4, 0xFFFF4D8D, 0xFF8E8E93];

/// Behind a chat row's content: the pattern picked for it and the drifting gifts of [giftsOf].
class ChatTileBackdrop extends StatelessWidget {
  const ChatTileBackdrop({super.key, required this.chat, this.giftsOf});

  final td.Chat chat;
  final int? giftsOf;

  @override
  Widget build(BuildContext context) {
    final pattern = localChatPattern(chat);
    final gifts = giftsOf;
    if (pattern == null && gifts == null) return const SizedBox.shrink();
    return Stack(fit: StackFit.expand, children: [
      if (pattern != null) EmojiPattern(pattern: pattern),
      if (gifts != null) GiftDrift(recipientId: gifts),
    ]);
  }
}

/// The chat's look on this device: a row color and a sticker or emoji pattern. Each tap applies at once.
Future<void> pickChatLook(BuildContext context, int chatId) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _ChatLookSheet(chatId: chatId),
    );

class _ChatLookSheet extends ConsumerWidget {
  const _ChatLookSheet({required this.chatId});

  final int chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chat = ref.watch(chatProvider(chatId));
    if (chat == null) return const SizedBox.shrink();
    final account = ref.read(accountProvider);
    final s = context.s;
    final theme = Theme.of(context);
    final color = localChatColor(chat);
    final pattern = localChatPattern(chat);
    Future<void> setColor(int? argb) => guard(context, () => account.setLocalChatColor(chat.id, argb));

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(s.t('chat_color'), textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
          // Live preview of the row.
          Container(
            height: 64,
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: color == null ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5) : Color(color).withValues(alpha: 0.14),
              border: Border.all(color: brandGold.withValues(alpha: 0.6)),
            ),
            child: Stack(fit: StackFit.expand, children: [
              if (pattern != null) EmojiPattern(pattern: pattern),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    chatTitle(chat, account, s),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16.5),
                  ),
                ),
              ),
            ]),
          ),
          Wrap(alignment: WrapAlignment.center, spacing: 6, runSpacing: 6, children: [
            PatternChoice(
              selected: color == null,
              onTap: () => setColor(null),
              label: s.t('chat_color_none'),
              child: CircleAvatar(radius: 18, backgroundColor: theme.colorScheme.surfaceContainerHighest, child: const Icon(Icons.block_rounded, size: 18)),
            ),
            for (final argb in chatTintColors)
              PatternChoice(
                selected: argb == color,
                onTap: () => setColor(argb),
                label: '#${argb.toRadixString(16).substring(2)}',
                child: CircleAvatar(radius: 18, backgroundColor: Color(argb)),
              ),
          ]),
          const SizedBox(height: 10),
          Expanded(
            child: EmojiPatternPicker(
              selected: pattern,
              onPicked: (value) => guard(context, () => account.setLocalChatPattern(chat.id, value)),
            ),
          ),
        ]),
      ),
    );
  }
}
