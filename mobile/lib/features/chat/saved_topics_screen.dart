import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../settings/privacy_screen.dart';

/// Saved Messages grouped by the chat each message was saved from. Pops with a message id to jump to.
class SavedTopicsScreen extends ConsumerStatefulWidget {
  const SavedTopicsScreen({super.key});

  @override
  ConsumerState<SavedTopicsScreen> createState() => _SavedTopicsScreenState();
}

class _SavedTopicsScreenState extends ConsumerState<SavedTopicsScreen> {
  final Map<int, td.SavedMessagesTopic> _topics = {};
  StreamSubscription<td.Update>? _updates;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final account = ref.read(accountProvider);
    _updates = account.messageEvents.listen((update) {
      if (update is td.UpdateSavedMessagesTopic && mounted) setState(() => _topics[update.topic.id] = update.topic);
    });
    _load(account);
  }

  @override
  void dispose() {
    _updates?.cancel();
    super.dispose();
  }

  // TDLib answers with updateSavedMessagesTopic for each topic, then a 404 once all are loaded.
  Future<void> _load(TelegramAccount account) async {
    try {
      for (var i = 0; i < 20; i++) {
        await account.send<td.Ok>(const td.LoadSavedMessagesTopics(limit: 100));
      }
    } on TdException {
      // All topics loaded.
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _menu(td.SavedMessagesTopic topic, String title) async {
    final s = context.s;
    final account = ref.read(accountProvider);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(topic.isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded),
              title: Text(s.t(topic.isPinned ? 'unpin' : 'pin')),
              onTap: () => Navigator.pop(context, 'pin'),
            ),
            if (topic.isPinned) ListTile(leading: const Icon(Icons.swap_vert_rounded), title: Text(s.t('pinned_reorder')), onTap: () => Navigator.pop(context, 'order')),
            ListTile(leading: const Icon(Icons.date_range_rounded), title: Text(s.t('clear_by_date')), onTap: () => Navigator.pop(context, 'by_date')),
            ListTile(
              leading: Icon(Icons.delete_outline_rounded, color: Theme.of(context).colorScheme.error),
              title: Text(s.t('delete'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'order') {
      await _reorderPinned();
      return;
    }
    if (action == 'by_date') {
      final range = await showDateRangePicker(context: context, firstDate: DateTime(2013, 8), lastDate: DateTime.now(), helpText: s.t('clear_by_date'), saveText: s.t('delete'));
      if (range == null || !mounted) return;
      final ok = await confirm(context, title: title, message: s.t('clear_history_confirm'), destructive: true);
      if (!ok || !mounted) return;
      await guard(
        context,
        () => account.send<td.Ok>(td.DeleteSavedMessagesTopicMessagesByDate(
          savedMessagesTopicId: topic.id,
          minDate: range.start.millisecondsSinceEpoch ~/ 1000,
          maxDate: DateTime(range.end.year, range.end.month, range.end.day, 23, 59, 59).millisecondsSinceEpoch ~/ 1000,
        )),
      );
      return;
    }
    if (action == 'pin') {
      await guard(context, () => account.send<td.Ok>(td.ToggleSavedMessagesTopicIsPinned(savedMessagesTopicId: topic.id, isPinned: !topic.isPinned)));
    } else if (action == 'delete') {
      final ok = await confirm(context, title: title, message: s.t('saved_topic_delete_hint'), destructive: true);
      if (!ok || !mounted) return;
      final done = await guard(context, () async {
        await account.send<td.Ok>(td.DeleteSavedMessagesTopicHistory(savedMessagesTopicId: topic.id));
        return true;
      });
      if (done == true && mounted) setState(() => _topics.remove(topic.id));
    }
  }

  Future<void> _reorderPinned() async {
    final s = context.s;
    final account = ref.read(accountProvider);
    var pinned = _topics.values.where((t) => t.isPinned && t.order != 0).toList()..sort((a, b) => b.order.compareTo(a.order));
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
            child: ReorderableListView(
              shrinkWrap: true,
              onReorderItem: (from, to) {
                setSheetState(() => pinned = [...pinned]..insert(to, pinned.removeAt(from)));
                guard(context, () => account.send<td.Ok>(td.SetPinnedSavedMessagesTopics(savedMessagesTopicIds: [for (final t in pinned) t.id])));
              },
              children: [
                for (final t in pinned)
                  ListTile(key: ValueKey(t.id), title: Text(savedTopicTitle(t, account, s)), trailing: const Icon(Icons.drag_handle_rounded)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    // Topics with order 0 are no longer in the list.
    final topics = _topics.values.where((t) => t.order != 0).toList()..sort((a, b) => b.order.compareTo(a.order));
    return Scaffold(
      appBar: AppBar(title: Text(s.t('saved_by_chat'))),
      body: topics.isEmpty
          ? Center(child: _loading ? const CircularProgressIndicator() : Text(s.t('nothing_here')))
          : ListView.builder(
              itemCount: topics.length,
              itemBuilder: (context, index) {
                final topic = topics[index];
                final title = savedTopicTitle(topic, account, s);
                final last = topic.lastMessage;
                return ListTile(
                  leading: switch (topic.type) {
                    td.SavedMessagesTopicTypeSavedFromChat(:final chatId) => ChatAvatar(chatId: chatId, size: 46, showOnline: false),
                    td.SavedMessagesTopicTypeAuthorHidden() => const CircleAvatar(radius: 23, child: Icon(Icons.person_off_rounded)),
                    _ => const CircleAvatar(radius: 23, child: Icon(Icons.bookmark_rounded)),
                  },
                  title: Row(children: [
                    Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    if (topic.isPinned) Icon(Icons.push_pin_rounded, size: 16, color: Theme.of(context).hintColor),
                  ]),
                  subtitle: last == null ? null : Text(messagePreview(last, account, s), maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: last == null ? null : Text(formatChatTime(last.date, s.locale), style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                  onLongPress: () => _menu(topic, title),
                  onTap: () async {
                    final id = await Navigator.of(context).push<int>(MaterialPageRoute(builder: (_) => SavedTopicMessagesScreen(topic: topic, title: title)));
                    if (id != null && context.mounted) Navigator.pop(context, id);
                  },
                );
              },
            ),
    );
  }
}

String savedTopicTitle(td.SavedMessagesTopic topic, TelegramAccount account, Strings s) => switch (topic.type) {
      td.SavedMessagesTopicTypeSavedFromChat(:final chatId) => account.chats[chatId] == null ? '' : chatTitle(account.chats[chatId]!, account, s),
      td.SavedMessagesTopicTypeAuthorHidden() => s.t('saved_author_hidden'),
      _ => s.t('saved_my_notes'),
    };

String _tagEmoji(td.ReactionType tag) => switch (tag) {
      td.ReactionTypeEmoji(:final emoji) => emoji,
      _ => '⭐',
    };

/// Messages of one Saved Messages topic, filterable by tag or text. Pops with the tapped message id.
class SavedTopicMessagesScreen extends ConsumerStatefulWidget {
  const SavedTopicMessagesScreen({super.key, required this.topic, required this.title});

  final td.SavedMessagesTopic topic;
  final String title;

  @override
  ConsumerState<SavedTopicMessagesScreen> createState() => _SavedTopicMessagesScreenState();
}

class _SavedTopicMessagesScreenState extends ConsumerState<SavedTopicMessagesScreen> {
  List<td.Message>? _messages;
  List<td.SavedMessagesTag> _tags = const [];
  td.ReactionType? _tag;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadTags();
    _load();
  }

  Future<void> _loadTags() async {
    try {
      final tags = await ref.read(accountProvider).send<td.SavedMessagesTags>(td.GetSavedMessagesTags(savedMessagesTopicId: widget.topic.id));
      if (mounted) setState(() => _tags = tags.tags);
    } on TdException {
      // Tags are a Premium feature; without them the screen is just a list.
    }
  }

  Future<void> _load() async {
    final account = ref.read(accountProvider);
    final id = widget.topic.id;
    final result = await guard(context, () async {
      if (_tag == null && _query.isEmpty) {
        return (await account.send<td.Messages>(td.GetSavedMessagesTopicHistory(savedMessagesTopicId: id, fromMessageId: 0, offset: 0, limit: 100))).messages;
      }
      return (await account.send<td.FoundChatMessages>(
        td.SearchSavedMessages(savedMessagesTopicId: id, tag: _tag, query: _query, fromMessageId: 0, offset: 0, limit: 100),
      ))
          .messages;
    });
    if (mounted) setState(() => _messages = [for (final m in result ?? const <td.Message?>[]) ?m]);
  }

  Future<void> _renameTag(td.SavedMessagesTag tag) async {
    final s = context.s;
    final label = await promptText(context, title: s.t('saved_tag_name'), label: _tagEmoji(tag.tag), initial: tag.label);
    if (label == null || !mounted) return;
    await guard(context, () => ref.read(accountProvider).send<td.Ok>(td.SetSavedMessagesTagLabel(tag: tag.tag, label: label.trim())));
    await _loadTags();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final messages = _messages;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: s.t('go_to_date'),
            icon: const Icon(Icons.calendar_month_rounded),
            onPressed: () async {
              final picked = await showDatePicker(context: context, firstDate: DateTime(2013, 8), lastDate: DateTime.now(), initialDate: DateTime.now());
              if (picked == null || !context.mounted) return;
              final message = await guard(
                context,
                () => account.send<td.Message>(
                  td.GetSavedMessagesTopicMessageByDate(savedMessagesTopicId: widget.topic.id, date: DateTime(picked.year, picked.month, picked.day, 23, 59, 59).millisecondsSinceEpoch ~/ 1000),
                ),
              );
              if (message != null && context.mounted) Navigator.pop(context, message.id);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: s.t('search')),
              onSubmitted: (value) {
                _query = value.trim();
                _load();
              },
            ),
          ),
          if (_tags.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final tag in _tags)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: GestureDetector(
                        onLongPress: () => _renameTag(tag),
                        child: FilterChip(
                          label: Text('${_tagEmoji(tag.tag)} ${tag.label.isEmpty ? '' : '${tag.label} '}${tag.count}'),
                          selected: _tag == tag.tag,
                          onSelected: (on) {
                            setState(() => _tag = on ? tag.tag : null);
                            _load();
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: messages == null
                ? const Center(child: CircularProgressIndicator())
                : messages.isEmpty
                    ? Center(child: Text(s.t('nothing_here')))
                    : ListView.separated(
                        itemCount: messages.length,
                        separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
                        itemBuilder: (context, index) {
                          final message = messages[index];
                          return ListTile(
                            title: Text(messagePreview(message, account, s), maxLines: 3, overflow: TextOverflow.ellipsis),
                            trailing: Text(formatChatTime(message.date, s.locale), style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                            onTap: () => Navigator.pop(context, message.id),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
