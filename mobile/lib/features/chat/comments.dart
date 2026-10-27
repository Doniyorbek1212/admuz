import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'chat_screen.dart';

/// Opens the discussion-group thread of a channel post.
Future<void> openComments(BuildContext context, td.Message post) async {
  final account = ProviderScope.containerOf(context, listen: false).read(accountProvider);
  final info = await guard(context, () => account.send<td.MessageThreadInfo>(td.GetMessageThread(chatId: post.chatId, messageId: post.id)));
  if (info == null || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => ChatScreen(
      chatId: info.chatId,
      threadId: info.messageThreadId,
      threadRoots: info.messages,
      topicName: context.s.count('comments', info.replyInfo?.replyCount ?? 0),
    ),
  ));
}

/// "12 comments" strip under a channel post with a linked discussion group.
class CommentsBar extends StatelessWidget {
  const CommentsBar({super.key, required this.message, required this.replyInfo});

  final td.Message message;
  final td.MessageReplyInfo replyInfo;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final primary = Theme.of(context).colorScheme.primary;
    final count = replyInfo.replyCount;
    final unread = replyInfo.lastMessageId > replyInfo.lastReadInboxMessageId && count > 0;
    return InkWell(
      onTap: () => openComments(context, message),
      child: Container(
        decoration: BoxDecoration(border: Border(top: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.4)))),
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        child: Row(children: [
          for (final sender in replyInfo.recentReplierIds.take(3))
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: switch (sender) {
                td.MessageSenderUser(:final userId) => UserAvatar(userId: userId, size: 22, showOnline: false),
                td.MessageSenderChat(:final chatId) => ChatAvatar(chatId: chatId, size: 22, showOnline: false),
                _ => const SizedBox.shrink(),
              },
            ),
          if (replyInfo.recentReplierIds.isEmpty) Icon(Icons.chat_bubble_outline_rounded, size: 18, color: primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              count == 0 ? s.t('comments_leave') : s.count('comments', count),
              style: TextStyle(color: primary, fontWeight: FontWeight.w600),
            ),
          ),
          if (unread) Container(width: 8, height: 8, decoration: BoxDecoration(color: primary, shape: BoxShape.circle)),
          Icon(Icons.chevron_right_rounded, color: primary),
        ]),
      ),
    );
  }
}
