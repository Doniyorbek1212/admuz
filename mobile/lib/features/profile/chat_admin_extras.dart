import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../state/actions.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../chat/composer_panels.dart' show StickerThumb;
import '../chat/sticker_extras.dart' show customReactionEffectsProvider, emojiReactionProvider;
import '../settings/privacy_screen.dart' show promptText;

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
                // Telegram's own name for the reaction ("Thumbs Up", …) on long press.
                Tooltip(
                  message: ref.watch(emojiReactionProvider(emoji)).value?.title ?? emoji,
                  child: FilterChip(
                    label: Text(emoji, style: const TextStyle(fontSize: 22)),
                    selected: _chosen.contains(emoji),
                    onSelected: (on) => setState(() => _chosen = on ? {..._chosen, emoji} : ({..._chosen}..remove(emoji))),
                  ),
                ),
            ]),
          ),
        if (_mode == 'all')
          switch (ref.watch(customReactionEffectsProvider).value) {
            final effects? when effects.isNotEmpty => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SectionHeader(s.t('reaction_effects')),
                SizedBox(
                  height: 72,
                  child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                    for (final sticker in effects.take(20)) Padding(padding: const EdgeInsets.all(4), child: SizedBox.square(dimension: 60, child: StickerThumb(sticker: sticker))),
                  ]),
                ),
                GroupHint(s.t('reaction_effects_hint')),
              ]),
            _ => const SizedBox.shrink(),
          },
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

/// Admin: messages a group or channel sends to everyone who joins (add, edit, delete, clear all).
class WelcomeMessagesScreen extends ConsumerStatefulWidget {
  const WelcomeMessagesScreen({super.key, required this.chatId});

  final int chatId;

  @override
  ConsumerState<WelcomeMessagesScreen> createState() => _WelcomeMessagesScreenState();
}

class _WelcomeMessagesScreenState extends ConsumerState<WelcomeMessagesScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);

  @override
  void initState() {
    super.initState();
    // The list arrives as updateChatWelcomeMessages.
    _account.send<td.Ok>(td.LoadChatWelcomeMessages(chatId: widget.chatId)).catchError((Object error) {
      if (mounted) showError(context, error);
      return const td.Ok();
    });
  }

  td.InputMessageContent _content(String text) => td.InputMessageText(text: formattedText(text), linkPreviewOptions: null, clearDraft: false);

  Future<void> _add() async {
    final s = context.s;
    final text = await promptText(context, title: s.t('welcome_message_add'), label: s.t('message_hint'));
    if (text == null || text.isEmpty || !mounted) return;
    await guard(context, () => _account.send<td.Ok>(td.AddChatWelcomeMessage(chatId: widget.chatId, inputMessageContent: _content(text))));
  }

  Future<void> _edit(td.WelcomeMessage message) async {
    final s = context.s;
    final current = message.content is td.MessageText ? (message.content as td.MessageText).text.text : '';
    final text = await promptText(context, title: s.t('edit'), label: s.t('message_hint'), initial: current);
    if (text == null || text.isEmpty || !mounted) return;
    await guard(
      context,
      () => _account.send<td.Ok>(td.EditChatWelcomeMessage(chatId: widget.chatId, welcomeMessageId: message.id, inputMessageContent: _content(text))),
    );
  }

  Future<void> _delete(td.WelcomeMessage message) async {
    if (!await confirm(context, title: context.t('delete'), destructive: true) || !mounted) return;
    await guard(context, () => _account.send<td.Ok>(td.DeleteChatWelcomeMessage(chatId: widget.chatId, welcomeMessageId: message.id)));
  }

  Future<void> _deleteAll() async {
    final s = context.s;
    if (!await confirm(context, title: s.t('welcome_messages_delete_all'), destructive: true) || !mounted) return;
    await guard(context, () => _account.send<td.Ok>(td.DeleteAllChatWelcomeMessages(chatId: widget.chatId)));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return ValueListenableBuilder<int>(
      valueListenable: _account.welcomeMessagesRevision,
      builder: (context, _, _) {
        final messages = _account.welcomeMessages[widget.chatId];
        return Scaffold(
          appBar: AppBar(
            title: Text(s.t('welcome_messages')),
            actions: [
              if (messages?.isNotEmpty ?? false)
                IconButton(icon: const Icon(Icons.delete_sweep_outlined), tooltip: s.t('welcome_messages_delete_all'), onPressed: _deleteAll),
            ],
          ),
          floatingActionButton: FloatingActionButton(onPressed: _add, tooltip: s.t('welcome_message_add'), child: const Icon(Icons.add_rounded)),
          body: messages == null
              ? const Center(child: CircularProgressIndicator())
              : messages.isEmpty
                  ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(s.t('welcome_messages_empty'), textAlign: TextAlign.center)))
                  : ListView(children: [
                      for (final message in messages)
                        ListTile(
                          leading: const Icon(Icons.waving_hand_outlined),
                          title: Text(contentPreview(message.content, s) ?? '', maxLines: 3, overflow: TextOverflow.ellipsis),
                          onTap: message.content is td.MessageText ? () => _edit(message) : null,
                          trailing: IconButton(icon: const Icon(Icons.delete_outline_rounded), tooltip: s.t('delete'), onPressed: () => _delete(message)),
                        ),
                    ]),
        );
      },
    );
  }
}
