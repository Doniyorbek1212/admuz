import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../home/home_screen.dart';
import 'message_bubble.dart';

/// Messages the user marked as important, from every chat (aka "Belgilangan xabarlar").
class MarkedMessagesScreen extends ConsumerWidget {
  const MarkedMessagesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final marks = ref.watch(markedMessagesProvider);
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
                final message = ref.watch(repliedMessageProvider((chatId, messageId)));
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
                  onTap: () => openChat(context, chatId, messageId: messageId),
                );
              },
            ),
    );
  }
}
