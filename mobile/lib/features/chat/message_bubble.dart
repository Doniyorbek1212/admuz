import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/link_safety.dart';
import '../../core/tdlib/td_client.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/link_policy.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../state/telegram.dart' show TelegramAccount;
import '../../widgets/common.dart';
import 'bot_keyboard.dart';
import 'comments.dart';
import 'link_preview_card.dart';
import 'message_content.dart';
import 'message_tools.dart';

/// Narrowest a captioned photo/video bubble gets, so the caption under a tall portrait stays readable.
const _captionMinWidth = 240.0;
const _longCaptionChars = 80;

/// The message a reply points to, resolved by TDLib from the reply itself (works across chats and threads).
final _replyTargetProvider = FutureProvider.autoDispose.family<td.Message?, (int, int)>((ref, key) async {
  try {
    return await ref.watch(accountProvider).send<td.Message>(td.GetRepliedMessage(chatId: key.$1, messageId: key.$2));
  } on TdException {
    return null;
  }
});

/// Message effects (the animated emoji a sender attached), fetched once per effect id.
final messageEffectProvider = FutureProvider.family<td.MessageEffect?, int>((ref, effectId) async {
  try {
    return await ref.watch(accountProvider).send<td.MessageEffect>(td.GetMessageEffect(effectId: effectId));
  } on TdException {
    return null;
  }
});

/// Text translations the user requested in this session (message id → translated text).
class TranslationsNotifier extends Notifier<Map<int, String>> {
  @override
  Map<int, String> build() => const {};

  void set(int messageId, String? text) {
    final next = Map.of(state);
    if (text == null) {
      next.remove(messageId);
    } else {
      next[messageId] = text;
    }
    state = next;
  }
}

final translationsProvider = NotifierProvider<TranslationsNotifier, Map<int, String>>(TranslationsNotifier.new);

/// Messages with dangerous links the user chose to see anyway, this session.
final _revealedRiskyProvider = NotifierProvider<_RevealedRisky, Set<String>>(_RevealedRisky.new);

class _RevealedRisky extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void reveal(String key) => state = {...state, key};
}

/// Every version of an edited message, oldest first, ending with the current one.
Future<void> showEditHistory(BuildContext context, TelegramAccount account, td.Message message) {
  final s = context.s;
  final versions = [
    ...account.archive.versionsOf(message.chatId, message.id),
    (content: message.content, date: message.editDate > 0 ? message.editDate : message.date),
  ];
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(s.t('edit_history')),
      content: SizedBox(
        width: 420,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final (index, version) in versions.indexed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: SelectableText(contentPreview(version.content, s) ?? ''),
                subtitle: Text([
                  index == versions.length - 1 ? s.t('edit_history_current') : s.t('edit_history_version', {'n': '${index + 1}'}),
                  '${formatDayHeader(version.date, s)} ${formatTime(version.date, s.locale)}',
                ].join(' · ')),
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('ok')))],
    ),
  );
}

/// The text an edited message had before its last edit, inside the bubble; tapping it shows every version.
class _PreviousVersion extends ConsumerWidget {
  const _PreviousVersion({required this.message, required this.textColor});

  final td.Message message;
  final Color textColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final versions = account.archive.versionsOf(message.chatId, message.id);
    if (versions.isEmpty) return const SizedBox.shrink();
    final s = context.s;
    final accent = Theme.of(context).brightness == Brightness.dark ? const Color(0xFFFFC857) : const Color(0xFFB7791F);
    final label = versions.length > 1 ? '${s.t('edit_before')} · ${s.t('edit_versions', {'n': '${versions.length}'})}' : s.t('edit_before');
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      child: Material(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => showEditHistory(context, account, message),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(8, 5, 8, 6),
            decoration: BoxDecoration(border: Border(left: BorderSide(color: accent, width: 3))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.history_rounded, size: 14, color: accent),
                    const SizedBox(width: 4),
                    Flexible(child: Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: accent))),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  contentPreview(versions.last.content, s) ?? '',
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, height: 1.25, color: textColor.withValues(alpha: 0.75)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder for a folded message: why it is hidden and a button to show it.
class _FoldedRiskyText extends StatelessWidget {
  const _FoldedRiskyText({required this.onShow});

  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(context.t('link_hidden_message'), style: TextStyle(color: Theme.of(context).hintColor, fontStyle: FontStyle.italic)),
          TextButton(onPressed: onShow, child: Text(context.t('link_show_message'))),
        ]),
      );
}

/// Entity text, clamped so a malformed offset can never throw.
String _slice(String text, td.TextEntity e) {
  final start = e.offset.clamp(0, text.length);
  return text.substring(start, (e.offset + e.length).clamp(start, text.length));
}

/// Red "Dangerous link" label on top of a message whose links phish or hijack accounts.
class _DangerousLinkChip extends StatelessWidget {
  const _DangerousLinkChip();

  @override
  Widget build(BuildContext context) {
    final danger = Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: danger.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: danger.withValues(alpha: 0.5)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.warning_amber_rounded, size: 15, color: danger),
            const SizedBox(width: 4),
            Text(context.t('link_dangerous_label'), style: TextStyle(color: danger, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
          ]),
        ),
      ),
    );
  }
}

class ServiceMessage extends ConsumerWidget {
  const ServiceMessage({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 32),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(14)),
          child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w500)),
        ),
      );
}

class MessageBubble extends ConsumerWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.chat,
    required this.showSender,
    required this.showTail,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onReplyTap,
    this.onInsertText,
    this.album,
  });

  final td.Message message;
  final td.Chat chat;
  final bool showSender;
  final bool showTail;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final void Function(int messageId) onReplyTap;
  final InsertText? onInsertText;

  /// All messages of the media album this bubble stands for (oldest first), or null.
  final List<td.Message>? album;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final settings = ref.watch(settingsProvider);
    final translation = ref.watch(translationsProvider.select((t) => t[message.id]));
    final colors = context.chatColors;
    final outgoing = message.isOutgoing && !message.isChannelPost;
    final isChannel = account.isChannel(chat);
    final screenWidth = MediaQuery.sizeOf(context).width;
    // Capped so bubbles stay readable in wide desktop windows.
    final maxWidth = (screenWidth * (screenWidth > 600 ? 0.6 : 0.78)).clamp(0.0, 480.0);
    final content = message.content;
    final bareMedia = content is td.MessageSticker || content is td.MessageAnimatedEmoji || content is td.MessageDice ||
        content is td.MessageVideoNote;
    final isMediaBubble = content is td.MessagePhoto || content is td.MessageVideo || content is td.MessageAnimation || isVideoDocument(content);
    final album = this.album;
    final text = album != null
        ? album.map((m) => captionOf(m.content)).firstWhere((c) => c != null && c.text.isNotEmpty, orElse: () => null)
        : switch (content) {
            td.MessageText(:final text) => text,
            _ => captionOf(content),
          };
    final hasText = text != null && text.text.isNotEmpty;
    // Captioned photo/video: the bubble is as wide as the media and the caption wraps under it (Telegram);
    // a narrow portrait one widens to a readable caption width and is cropped to fill it.
    // A long caption takes the full bubble width instead of wrapping into a narrow column.
    final naturalMedia = album == null && hasText ? mediaWidth(content, maxWidth) : null;
    final captionedMediaWidth = naturalMedia == null
        ? null
        : (text?.text.length ?? 0) > _longCaptionChars
            ? maxWidth
            : naturalMedia < _captionMinWidth
                ? (_captionMinWidth > maxWidth ? maxWidth : _captionMinWidth)
                : naturalMedia;
    final bubbleMaxWidth = captionedMediaWidth ?? maxWidth;
    // Time sits at the end of the last text line when it fits (Telegram layout).
    final policy = ref.watch(linkPolicyProvider);
    final linkRisk = text == null
        ? LinkRisk.safe
        : worstLinkRisk([
            for (final e in text.entities)
              if (e.type case td.TextEntityTypeUrl()) (_slice(text.text, e), null)
              else if (e.type case td.TextEntityTypeTextUrl(:final url)) (url, _slice(text.text, e)),
          ], policy: policy);
    // "Hide messages with dangerous links": the text stays folded until the user asks to see it.
    final folded = linkRisk.isDangerous && policy.hideMessages && !ref.watch(_revealedRiskyProvider).contains('${message.chatId}:${message.id}');
    final inlineFooter = hasText && translation == null && !folded;
    // Photos and videos without a caption carry the time on the media itself, edge to edge (Telegram/aka layout).
    final footerOnMedia = isMediaBubble && !hasText && translation == null;
    final textColor = outgoing ? colors.outgoingText : colors.incomingText;
    final radius = Radius.circular(settings.bubbleRadius);
    final small = Radius.circular(settings.bubbleRadius / 3.5);
    final showGroupAvatar = !outgoing && account.isGroup(chat);
    final archived = (
      deleted: account.archive.isDeleted(message.chatId, message.id),
      hasVersions: account.archive.versionsOf(message.chatId, message.id).isNotEmpty,
    );

    Widget? senderLabel;
    if (showSender && !outgoing && (account.isGroup(chat) || isChannel && (message.authorSignature ?? '').isNotEmpty)) {
      final name = isChannel ? (message.authorSignature ?? '') : account.senderName(message.senderId);
      final seed = account.senderKey(message.senderId);
      final label = Text(
        name,
        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: _nameColors[seed.abs() % _nameColors.length]),
      );
      senderLabel = isChannel
          ? label
          : GestureDetector(onTap: () => openSenderProfile(context, account, message.senderId), child: label);
    }

    final children = <Widget>[
      if (linkRisk.isDangerous) const _DangerousLinkChip(),
      if (senderLabel != null) Padding(padding: const EdgeInsets.fromLTRB(10, 6, 10, 0), child: senderLabel),
      if (message.forwardInfo != null) _ForwardHeader(info: message.forwardInfo!, outgoing: outgoing),
      if (message.replyTo case final td.MessageReplyToMessage reply)
        _ReplyHeader(message: message, reply: reply, outgoing: outgoing, onTap: () => onReplyTap(reply.messageId)),
      if (!bareMedia && content is! td.MessageText)
        Padding(
          padding: isMediaBubble ? EdgeInsets.zero : const EdgeInsets.fromLTRB(10, 8, 10, 0),
          child: ClipRRect(
            borderRadius: isMediaBubble && senderLabel == null && message.replyTo == null && message.forwardInfo == null
                ? BorderRadius.vertical(top: radius, bottom: hasText ? Radius.zero : radius)
                : BorderRadius.zero,
            child: Stack(
              children: [
                album != null
                    ? AlbumGrid(messages: album, maxWidth: maxWidth)
                    : MessageMedia(message: message, maxWidth: bubbleMaxWidth, fillWidth: captionedMediaWidth != null),
                if (footerOnMedia)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: _Footer(message: message, chat: chat, outgoing: outgoing, isChannel: isChannel, archived: archived, onMedia: true),
                  ),
              ],
            ),
          ),
        ),
      if (archived.hasVersions && !archived.deleted && !folded) _PreviousVersion(message: message, textColor: textColor),
      if (hasText && folded)
        _FoldedRiskyText(onShow: () => ref.read(_revealedRiskyProvider.notifier).reveal('${message.chatId}:${message.id}'))
      else if (hasText && inlineFooter)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 8, 5),
          child: Stack(
            children: [
              FormattedTextView(
                text: text,
                style: TextStyle(color: textColor, fontSize: 15.5 * settings.textScale, height: 1.3),
                trailingSpace: _footerWidth(message, outgoing: outgoing, isChannel: isChannel, archived: archived) * MediaQuery.textScalerOf(context).scale(1),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: _Footer(message: message, chat: chat, outgoing: outgoing, isChannel: isChannel, archived: archived),
              ),
            ],
          ),
        )
      else if (hasText)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
          child: FormattedTextView(
            text: text,
            style: TextStyle(color: textColor, fontSize: 15.5 * settings.textScale, height: 1.3),
          ),
        ),
      if (content case td.MessageText(:final linkPreview?) when !folded) LinkPreviewCard(preview: linkPreview, textColor: textColor),
      if (translation != null)
        Container(
          margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
          padding: const EdgeInsets.only(left: 8),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2))),
          child: FormattedTextView(text: linkified(translation), style: TextStyle(color: textColor, fontSize: 15 * settings.textScale, fontStyle: FontStyle.italic)),
        ),
      if (message.factCheck case final factCheck?)
        Container(
          margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.error.withValues(alpha: 0.08),
            border: Border(left: BorderSide(color: Theme.of(context).colorScheme.error, width: 2)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(context.t('fact_check'), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.error)),
            FormattedTextView(text: factCheck.text, style: TextStyle(color: textColor, fontSize: 14 * settings.textScale)),
          ]),
        ),
      if (!inlineFooter && !footerOnMedia)
        Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 8, 5),
            child: _Footer(message: message, chat: chat, outgoing: outgoing, isChannel: isChannel, archived: archived),
          ),
        ),
      if (message.interactionInfo?.reactions?.reactions.isNotEmpty ?? false)
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
          child: _Reactions(message: message, outgoing: outgoing),
        ),
      if (message.interactionInfo?.replyInfo case final replyInfo? when isChannel) CommentsBar(message: message, replyInfo: replyInfo),
    ];

    final bubble = bareMedia
        ? Column(
            crossAxisAlignment: outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (message.replyTo case final td.MessageReplyToMessage reply)
                _ReplyHeader(message: message, reply: reply, outgoing: outgoing, onTap: () => onReplyTap(reply.messageId)),
              // Round videos carry the time on their bottom-right edge, as in Telegram.
              if (content is td.MessageVideoNote)
                Stack(
                  children: [
                    MessageMedia(message: message, maxWidth: maxWidth),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: _Footer(message: message, chat: chat, outgoing: outgoing, isChannel: isChannel, archived: archived, onMedia: true),
                    ),
                  ],
                )
              else ...[
                MessageMedia(message: message, maxWidth: maxWidth),
                _Footer(message: message, chat: chat, outgoing: outgoing, isChannel: isChannel, archived: archived, onMedia: true),
              ],
            ],
          )
        : Container(
            constraints: BoxConstraints(maxWidth: bubbleMaxWidth, minWidth: 80),
            decoration: BoxDecoration(
              color: outgoing ? colors.outgoingBubble : colors.incomingBubble,
              borderRadius: BorderRadius.only(
                topLeft: radius,
                topRight: radius,
                bottomLeft: outgoing || !showTail ? radius : small,
                bottomRight: outgoing && showTail ? small : radius,
              ),
              boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 1.5, offset: Offset(0, 1))],
            ),
            child: IntrinsicWidth(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children),
            ),
          );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      onDoubleTap: () => guard(context, () => account.toggleReaction(message, settings.quickReaction)),
      child: Container(
        color: selected ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.18) : Colors.transparent,
        padding: EdgeInsets.fromLTRB(showGroupAvatar ? 6 : 8, showTail ? 2 : 1, 8, showTail ? 4 : 1),
        child: Row(
          mainAxisAlignment: outgoing ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (showGroupAvatar)
              SizedBox(
                width: 40,
                child: showTail && message.senderId is td.MessageSenderUser
                    ? GestureDetector(
                        onTap: () => openSenderProfile(context, account, message.senderId),
                        child: UserAvatar(userId: (message.senderId as td.MessageSenderUser).userId, size: 34, showOnline: false),
                      )
                    : null,
              ),
            Flexible(
              child: switch (message.replyMarkup) {
                td.ReplyMarkupInlineKeyboard(:final rows) when rows.isNotEmpty => Column(
                      crossAxisAlignment: outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        bubble,
                        const SizedBox(height: 2),
                        InlineKeyboardView(message: message, rows: rows, maxWidth: maxWidth, onInsertText: onInsertText),
                      ],
                    ),
                _ => bubble,
              },
            ),
          ],
        ),
      ),
    );
  }

  static const _nameColors = [
    Color(0xFFE17076),
    Color(0xFFF39C3D),
    Color(0xFF9B6CE0),
    Color(0xFF4FAD4F),
    Color(0xFF3FB3C7),
    Color(0xFF3D8AD8),
    Color(0xFFD46BA4),
  ];
}

/// What the local archive knows about a message: deleted by someone else, earlier versions kept.
typedef _Archived = ({bool deleted, bool hasVersions});

/// Room reserved at the end of the text for the time/status footer.
double _footerWidth(td.Message message, {required bool outgoing, required bool isChannel, required _Archived archived}) {
  var width = 40.0; // "16:09" + gap
  if (message.isOutgoing && !isChannel) width += 18;
  if (message.editDate > 0) width += 52;
  if (archived.hasVersions) width += 14;
  if (archived.deleted) width += 82;
  if (message.isPinned) width += 15;
  final views = message.interactionInfo?.viewCount ?? 0;
  if (isChannel && views > 0) width += 24 + 7.0 * formatCount(views).length;
  return width;
}

class _Footer extends ConsumerWidget {
  const _Footer({
    required this.message,
    required this.chat,
    required this.outgoing,
    required this.isChannel,
    required this.archived,
    this.onMedia = false,
  });

  final td.Message message;
  final td.Chat chat;
  final bool outgoing;
  final bool isChannel;
  final _Archived archived;
  final bool onMedia;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final color = onMedia ? Colors.white : context.metaColor(outgoing);
    // Saved Messages has no reader: Telegram shows its messages as read.
    final savedMessages = switch (chat.type) {
      td.ChatTypePrivate(:final userId) => userId == ref.read(accountProvider).myId,
      _ => false,
    };
    final views = message.interactionInfo?.viewCount ?? 0;
    final style = TextStyle(fontSize: 11.5, color: color);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (message.isPinned) Padding(padding: const EdgeInsets.only(right: 3), child: Icon(Icons.push_pin_rounded, size: 12, color: color)),
        if (isChannel && views > 0) ...[
          Icon(Icons.visibility_rounded, size: 13, color: color),
          const SizedBox(width: 2),
          Text(formatCount(views), style: style),
          const SizedBox(width: 6),
        ],
        if (archived.deleted) ...[
          Icon(Icons.delete_outline_rounded, size: 13, color: onMedia ? Colors.white : Theme.of(context).colorScheme.error),
          Text('${s.t('deleted_label')} ', style: style.copyWith(color: onMedia ? null : Theme.of(context).colorScheme.error)),
        ],
        if (archived.hasVersions) Padding(padding: const EdgeInsets.only(right: 2), child: Icon(Icons.history_rounded, size: 12, color: color)),
        if (message.effectId != 0)
          if (ref.watch(messageEffectProvider(message.effectId)).value case final effect?)
            Padding(padding: const EdgeInsets.only(right: 3), child: Text(effect.emoji, style: const TextStyle(fontSize: 12))),
        if (message.editDate > 0) Text('${s.t('edited')} ', style: style),
        Text(formatTime(message.date, s.locale), style: style),
        if (message.isOutgoing && !isChannel) ...[
          const SizedBox(width: 3),
          _statusIcon(color, alwaysRead: savedMessages),
        ],
      ],
    );
    if (!onMedia) return row;
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(10)),
      child: row,
    );
  }

  Widget _statusIcon(Color color, {required bool alwaysRead}) {
    final state = message.sendingState;
    if (state is td.MessageSendingStateFailed) return const Icon(Icons.error_rounded, size: 14, color: Colors.redAccent);
    if (state is td.MessageSendingStatePending) return Icon(Icons.schedule_rounded, size: 13, color: color);
    final read = alwaysRead || message.id <= chat.lastReadOutboxMessageId;
    return Icon(read ? Icons.done_all_rounded : Icons.done_rounded, size: 15, color: color);
  }
}

class _ForwardHeader extends ConsumerWidget {
  const _ForwardHeader({required this.info, required this.outgoing});

  final td.MessageForwardInfo info;
  final bool outgoing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final color = Theme.of(context).colorScheme.primary;
    const avatarSize = 20.0;
    // Name, avatar and where a tap leads: the person's profile, or the channel at the original post.
    final (String name, Widget? avatar, VoidCallback? onTap) = switch (info.origin) {
      td.MessageOriginUser(:final senderUserId) => (
          account.userName(senderUserId),
          UserAvatar(userId: senderUserId, size: avatarSize, showOnline: false),
          () => openSenderProfile(context, account, td.MessageSenderUser(userId: senderUserId)),
        ),
      td.MessageOriginChat(:final senderChatId) => (
          account.chats[senderChatId]?.title ?? '',
          ChatAvatar(chatId: senderChatId, size: avatarSize, showOnline: false),
          () => openChatFromContent(context, senderChatId),
        ),
      td.MessageOriginChannel(:final chatId, :final messageId) => (
          account.chats[chatId]?.title ?? '',
          ChatAvatar(chatId: chatId, size: avatarSize, showOnline: false),
          () => openChatFromContent(context, chatId, messageId: messageId),
        ),
      td.MessageOriginHiddenUser(:final senderName) => (senderName, null, null),
      _ => ('', null, null),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(context.t('forwarded_from'), style: TextStyle(fontSize: 13.5, color: color)),
          const SizedBox(height: 3),
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(avatarSize / 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (avatar != null) ...[avatar, const SizedBox(width: 6)],
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _ReplyHeader extends ConsumerWidget {
  const _ReplyHeader({required this.message, required this.reply, required this.outgoing, required this.onTap});

  final td.Message message;
  final td.MessageReplyToMessage reply;
  final bool outgoing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final repliedState = ref.watch(_replyTargetProvider((message.chatId, message.id)));
    final replied = repliedState.value;
    final primary = Theme.of(context).colorScheme.primary;
    // Replies to messages from other chats (or not yet loaded) carry their origin and content inline.
    final originName = switch (reply.origin) {
      td.MessageOriginUser(:final senderUserId) => account.userName(senderUserId),
      td.MessageOriginChat(:final senderChatId) => account.chats[senderChatId]?.title ?? '',
      td.MessageOriginChannel(:final chatId) => account.chats[chatId]?.title ?? '',
      td.MessageOriginHiddenUser(:final senderName) => senderName,
      _ => '',
    };
    final name = replied != null ? account.senderName(replied.senderId) : originName;
    final inlineContent = reply.content;
    final preview = reply.quote?.text.text ??
        (replied != null
            ? messagePreview(replied, account, s)
            : (inlineContent != null
                ? (contentPreview(inlineContent, s) ?? s.t('message'))
                : (repliedState.isLoading ? '…' : s.t('deleted_message'))));
    final thumb = replyThumb(replied?.content ?? inlineContent);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (name.isNotEmpty)
          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: primary, fontWeight: FontWeight.w600, fontSize: 13.5)),
        Text(
          (thumb == null ? preview : withoutMediaEmoji(preview)).replaceAll('\n', ' '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13.5),
        ),
      ],
    );
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(6, 6, 6, 0),
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        decoration: BoxDecoration(
          color: primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
          border: Border(left: BorderSide(color: primary, width: 3)),
        ),
        child: thumb == null
            ? text
            : Row(mainAxisSize: MainAxisSize.min, children: [thumb, const SizedBox(width: 8), Flexible(child: text)]),
      ),
    );
  }
}

class _Reactions extends ConsumerWidget {
  const _Reactions({required this.message, required this.outgoing});

  final td.Message message;
  final bool outgoing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final primary = Theme.of(context).colorScheme.primary;
    final reactions = message.interactionInfo!.reactions!.reactions;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final reaction in reactions)
          if (reaction.type is td.ReactionTypePaid)
            GestureDetector(
              onTap: () => sendPaidReaction(context, account, message),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: reaction.isChosen ? const Color(0xFFF5A623) : const Color(0xFFF5A623).withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  '⭐ ${formatCount(reaction.totalCount)}',
                  style: TextStyle(fontSize: 13, color: reaction.isChosen ? Colors.white : const Color(0xFFB7791F), fontWeight: FontWeight.w600),
                ),
              ),
            )
          else if (reaction.type case td.ReactionTypeEmoji(:final emoji))
            GestureDetector(
              onTap: () => guard(context, () => account.toggleReaction(message, emoji)),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: reaction.isChosen ? primary : primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  '$emoji ${formatCount(reaction.totalCount)}',
                  style: TextStyle(fontSize: 13, color: reaction.isChosen ? Colors.white : primary, fontWeight: FontWeight.w600),
                ),
              ),
            ),
      ],
    );
  }
}
