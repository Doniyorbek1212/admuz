import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';

/// Telegram's default cap on different reactions under one message.
const _maxReactionCount = 11;

/// Admin: which reactions members may use — all, a chosen set, or none.
class ChatReactionsScreen extends ConsumerStatefulWidget {
  const ChatReactionsScreen({super.key, required this.chatId});

  final int chatId;

  @override
  ConsumerState<ChatReactionsScreen> createState() => _ChatReactionsScreenState();
}

class _ChatReactionsScreenState extends ConsumerState<ChatReactionsScreen> {
  late String _mode;
  late Set<String> _chosen;

  @override
  void initState() {
    super.initState();
    final current = ref.read(accountProvider).chats[widget.chatId]?.availableReactions;
    final some = current is td.ChatAvailableReactionsSome
        ? {for (final r in current.reactions) if (r case td.ReactionTypeEmoji(:final emoji)) emoji}
        : <String>{};
    _mode = current is td.ChatAvailableReactionsSome ? (some.isEmpty ? 'none' : 'some') : 'all';
    _chosen = some;
  }

  Future<void> _save() async {
    final td.ChatAvailableReactions value = switch (_mode) {
      'all' => const td.ChatAvailableReactionsAll(maxReactionCount: _maxReactionCount),
      'none' => const td.ChatAvailableReactionsSome(reactions: [], maxReactionCount: _maxReactionCount),
      _ => td.ChatAvailableReactionsSome(reactions: [for (final e in _chosen) td.ReactionTypeEmoji(emoji: e)], maxReactionCount: _maxReactionCount),
    };
    final ok = await guard(context, () async {
      await ref.read(accountProvider).send<td.Ok>(td.SetChatAvailableReactions(chatId: widget.chatId, availableReactions: value));
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final emojis = ref.watch(accountProvider).activeEmojiReactions;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('reactions')), actions: [TextButton(onPressed: _save, child: Text(s.t('save')))]),
      body: ListView(children: [
        RadioGroup<String>(
          groupValue: _mode,
          onChanged: (v) => setState(() => _mode = v ?? 'all'),
          child: Column(children: [
            RadioListTile<String>(value: 'all', title: Text(s.t('reactions_all'))),
            RadioListTile<String>(value: 'some', title: Text(s.t('reactions_some'))),
            RadioListTile<String>(value: 'none', title: Text(s.t('reactions_none'))),
          ]),
        ),
        if (_mode == 'some')
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final emoji in emojis)
                FilterChip(
                  label: Text(emoji, style: const TextStyle(fontSize: 22)),
                  selected: _chosen.contains(emoji),
                  onSelected: (on) => setState(() => _chosen = on ? {..._chosen, emoji} : ({..._chosen}..remove(emoji))),
                ),
            ]),
          ),
      ]),
    );
  }
}

/// Channel owner: link a discussion group for comments, or unlink it.
Future<void> pickDiscussionGroup(BuildContext context, TelegramAccount account, int channelChatId, {required bool linked}) async {
  final s = context.s;
  final suitable = await guard(context, () => account.send<td.Chats>(const td.GetSuitableDiscussionChats()));
  if (suitable == null || !context.mounted) return;
  final picked = await showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: ListView(shrinkWrap: true, children: [
          if (linked)
            ListTile(
              leading: Icon(Icons.link_off_rounded, color: Theme.of(context).colorScheme.error),
              title: Text(s.t('discussion_unlink'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () => Navigator.pop(context, 0),
            ),
          if (suitable.chatIds.isEmpty) ListTile(title: Text(s.t('discussion_none'))),
          for (final id in suitable.chatIds)
            ListTile(
              leading: ChatAvatar(chatId: id, size: 40, showOnline: false),
              title: Text(account.chats[id] == null ? '$id' : chatTitle(account.chats[id]!, account, s)),
              onTap: () => Navigator.pop(context, id),
            ),
        ]),
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  final done = await guard(context, () async {
    await account.send<td.Ok>(td.SetChatDiscussionGroup(chatId: channelChatId, discussionChatId: picked));
    return true;
  });
  if (done == true && context.mounted) showToast(context, s.t('done'));
}
