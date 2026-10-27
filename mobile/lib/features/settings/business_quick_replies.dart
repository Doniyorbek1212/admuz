import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import 'business_settings.dart';
import 'privacy_screen.dart';

String quickReplyPreview(td.QuickReplyMessage message, Strings s) => (contentPreview(message.content, s) ?? '').replaceAll('\n', ' ');

/// Adds a text message to a shortcut, creating the shortcut when it does not exist yet.
Future<void> addQuickReplyText(BuildContext context, TelegramAccount account, String shortcutName, {int? editMessageId, int? shortcutId, String initial = ''}) async {
  final s = context.s;
  final text = await promptText(context, title: shortcutName, label: s.t('biz_message'), initial: initial);
  if (text == null || text.trim().isEmpty || !context.mounted) return;
  final content = td.InputMessageText(text: plainText(text.trim()), linkPreviewOptions: null, clearDraft: false);
  await guard(context, () async {
    if (editMessageId != null && shortcutId != null) {
      await account.send<td.Ok>(td.EditQuickReplyMessage(shortcutId: shortcutId, messageId: editMessageId, inputMessageContent: content));
    } else {
      await account.send<td.QuickReplyMessage>(td.AddQuickReplyShortcutMessage(shortcutName: shortcutName, replyToMessageId: 0, inputMessageContent: content));
    }
  });
}

/// Business → Quick replies: "/name" shortcuts the user can send in any chat.
class QuickRepliesScreen extends ConsumerWidget {
  const QuickRepliesScreen({super.key});

  Future<void> _create(BuildContext context, TelegramAccount account) async {
    final s = context.s;
    final name = await promptText(context, title: s.t('biz_quick_replies'), label: s.t('biz_shortcut_name'));
    final clean = name?.trim().replaceFirst('/', '') ?? '';
    if (clean.isEmpty || !context.mounted) return;
    final valid = await guard(context, () async {
      await account.send<td.Ok>(td.CheckQuickReplyShortcutName(name: clean));
      return true;
    });
    if (valid == true && context.mounted) await addQuickReplyText(context, account, clean);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    return ValueListenableBuilder(
      valueListenable: account.quickRepliesRevision,
      builder: (context, _, _) {
        final ordered = [
          for (final id in account.quickReplyOrder) ?account.quickReplies[id],
          for (final q in account.quickReplies.values) if (!account.quickReplyOrder.contains(q.id)) q,
        ].where((q) => q.name != greetingShortcut && q.name != awayShortcut).toList();
        return Scaffold(
          appBar: AppBar(title: Text(s.t('biz_quick_replies'))),
          floatingActionButton: FloatingActionButton(onPressed: () => _create(context, account), child: const Icon(Icons.add_rounded)),
          body: ordered.isEmpty
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(s.t('biz_quick_replies_sub'), textAlign: TextAlign.center)))
              : ReorderableListView(
                  onReorderItem: (from, to) {
                    final ids = [for (final q in ordered) q.id];
                    ids.insert(to, ids.removeAt(from));
                    account.send<td.Ok>(td.ReorderQuickReplyShortcuts(shortcutIds: ids)).ignore();
                  },
                  children: [
                    for (final q in ordered)
                      ListTile(
                        key: ValueKey(q.id),
                        leading: const CircleAvatar(child: Icon(Icons.quickreply_rounded)),
                        title: Text('/${q.name}', style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(quickReplyPreview(q.firstMessage, s), maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: Text('${q.messageCount}'),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => QuickReplyMessagesScreen(shortcutId: q.id))),
                      ),
                  ],
                ),
        );
      },
    );
  }
}

/// Messages of one quick reply: add, edit, delete; rename or delete the shortcut.
class QuickReplyMessagesScreen extends ConsumerStatefulWidget {
  const QuickReplyMessagesScreen({super.key, required this.shortcutId});

  final int shortcutId;

  @override
  ConsumerState<QuickReplyMessagesScreen> createState() => _QuickReplyMessagesScreenState();
}

class _QuickReplyMessagesScreenState extends ConsumerState<QuickReplyMessagesScreen> {
  List<td.QuickReplyMessage>? _messages;
  StreamSubscription<td.Update>? _updates;

  @override
  void initState() {
    super.initState();
    final account = ref.read(accountProvider);
    _updates = account.messageEvents.listen((update) {
      if (update is td.UpdateQuickReplyShortcutMessages && update.shortcutId == widget.shortcutId && mounted) {
        setState(() => _messages = update.messages);
      }
    });
    account.send<td.Ok>(td.LoadQuickReplyShortcutMessages(shortcutId: widget.shortcutId)).ignore();
  }

  @override
  void dispose() {
    _updates?.cancel();
    super.dispose();
  }

  Future<void> _menu(String action, td.QuickReplyShortcut shortcut) async {
    final s = context.s;
    final account = ref.read(accountProvider);
    if (action == 'rename') {
      final name = await promptText(context, title: s.t('rename'), label: s.t('biz_shortcut_name'), initial: shortcut.name);
      final clean = name?.trim().replaceFirst('/', '') ?? '';
      if (clean.isNotEmpty && mounted) await guard(context, () => account.send<td.Ok>(td.SetQuickReplyShortcutName(shortcutId: shortcut.id, name: clean)));
    } else {
      final ok = await confirm(context, title: '/${shortcut.name}', message: s.t('biz_shortcut_delete'), destructive: true);
      if (!ok || !mounted) return;
      final done = await guard(context, () async {
        await account.send<td.Ok>(td.DeleteQuickReplyShortcut(shortcutId: shortcut.id));
        return true;
      });
      if (done == true && mounted) Navigator.pop(context);
    }
  }

  Future<void> _messageMenu(td.QuickReplyMessage message, td.QuickReplyShortcut shortcut) async {
    final s = context.s;
    final account = ref.read(accountProvider);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (message.canBeEdited && message.content is td.MessageText)
            ListTile(leading: const Icon(Icons.edit_rounded), title: Text(s.t('edit')), onTap: () => Navigator.pop(context, 'edit')),
          ListTile(
            leading: Icon(Icons.delete_outline_rounded, color: Theme.of(context).colorScheme.error),
            title: Text(s.t('delete'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ]),
      ),
    );
    if (!mounted) return;
    if (action == 'edit') {
      final text = (message.content as td.MessageText).text.text;
      await addQuickReplyText(context, account, shortcut.name, editMessageId: message.id, shortcutId: shortcut.id, initial: text);
    } else if (action == 'delete') {
      await guard(context, () => account.send<td.Ok>(td.DeleteQuickReplyShortcutMessages(shortcutId: shortcut.id, messageIds: [message.id])));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    return ValueListenableBuilder(
      valueListenable: account.quickRepliesRevision,
      builder: (context, _, _) {
        final shortcut = account.quickReplies[widget.shortcutId];
        if (shortcut == null) return Scaffold(appBar: AppBar(), body: Center(child: Text(s.t('nothing_here'))));
        final messages = _messages;
        final reserved = shortcut.name == greetingShortcut || shortcut.name == awayShortcut;
        return Scaffold(
          appBar: AppBar(
            title: Text(reserved ? s.t(shortcut.name == awayShortcut ? 'biz_away' : 'biz_greeting') : '/${shortcut.name}'),
            actions: [
              if (!reserved)
                PopupMenuButton<String>(
                  onSelected: (action) => _menu(action, shortcut),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'rename', child: Text(s.t('rename'))),
                    PopupMenuItem(value: 'delete', child: Text(s.t('delete'))),
                  ],
                ),
            ],
          ),
          floatingActionButton: FloatingActionButton(onPressed: () => addQuickReplyText(context, account, shortcut.name), child: const Icon(Icons.add_comment_rounded)),
          body: messages == null
              ? const Center(child: CircularProgressIndicator())
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: messages.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    return ListTile(
                      title: Text(quickReplyPreview(message, s)),
                      onTap: () => _messageMenu(message, shortcut),
                    );
                  },
                ),
        );
      },
    );
  }
}
