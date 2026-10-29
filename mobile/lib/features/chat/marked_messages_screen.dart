import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../home/home_screen.dart';

/// Marked messages of one chat, fetched in one GetMessages call; key is (chat id, comma-joined message ids).
final _markedBatchProvider = FutureProvider.autoDispose.family<Map<int, td.Message>, (int, String)>((ref, key) async {
  final ids = [for (final id in key.$2.split(',')) int.parse(id)];
  try {
    final found = await ref.watch(accountProvider).send<td.Messages>(td.GetMessages(chatId: key.$1, messageIds: ids));
    return {for (final message in (found.messages ?? const <td.Message?>[]).whereType<td.Message>()) message.id: message};
  } on TdException {
    return const {};
  }
});

/// Messages the user marked as important, from every chat (aka "Belgilangan xabarlar").
class MarkedMessagesScreen extends ConsumerWidget {
  const MarkedMessagesScreen({super.key, this.chatId});

  /// Only this chat's marks; tapping one pops with its message id instead of opening the chat.
  final int? chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final marks = [for (final mark in ref.watch(markedMessagesProvider)) if (chatId == null || mark.$1 == chatId) mark];
    final account = ref.watch(accountProvider);
    final s = context.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('marked_messages'))),
      body: marks.isEmpty
          ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(s.t('marked_empty'), textAlign: TextAlign.center)))
          : ListView.builder(
              itemCount: marks.length,
              itemBuilder: (context, index) {
                final (chatId, messageId) = marks[index];
                final chat = account.chats[chatId];
                final ids = [for (final mark in marks) if (mark.$1 == chatId) mark.$2].join(',');
                final message = ref.watch(_markedBatchProvider((chatId, ids))).whenData((found) => found[messageId]);
                return ListTile(
                  leading: ChatAvatar(chatId: chatId, size: 46),
                  title: Text(chat == null ? '' : chatTitle(chat, account, s), maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    switch (message) {
                      AsyncData(value: final m?) => messagePreview(m, account, s),
                      AsyncData() => s.t('deleted_message'),
                      _ => '…',
                    },
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: s.t('unmark_message'),
                    icon: Icon(Icons.star_rounded, color: Theme.of(context).colorScheme.primary),
                    onPressed: () => ref.read(markedMessagesProvider.notifier).toggle(chatId, messageId),
                  ),
                  onTap: () => this.chatId != null ? Navigator.pop(context, messageId) : openChat(context, chatId, messageId: messageId),
                );
              },
            ),
    );
  }
}
