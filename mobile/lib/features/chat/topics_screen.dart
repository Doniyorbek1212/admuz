import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../../widgets/custom_emoji.dart';
import '../profile/chat_info_screen.dart';
import '../settings/privacy_screen.dart';
import 'chat_screen.dart';

/// Icon colors Telegram allows for new topics.
const _topicColors = [0x6FB9F0, 0xFFD67E, 0xCB86DB, 0x8EEE98, 0xFF93B2, 0xFB6F5F];

/// Topic list of a forum supergroup.
class TopicsScreen extends ConsumerStatefulWidget {
  const TopicsScreen({super.key, required this.chatId});

  final int chatId;

  @override
  ConsumerState<TopicsScreen> createState() => _TopicsScreenState();
}

class _TopicsScreenState extends ConsumerState<TopicsScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  final List<td.ForumTopic> _topics = [];
  bool _loading = false;
  bool _hasMore = true;
  String? _error;
  td.ForumTopics? _lastPage;
  Timer? _refreshDebounce;
  late final ValueNotifier<int> _chatRevision = _account.chatRevision(widget.chatId);

  @override
  void initState() {
    super.initState();
    _chatRevision.addListener(_scheduleRefresh);
    unawaited(_reload());
  }

  @override
  void dispose() {
    _chatRevision.removeListener(_scheduleRefresh);
    _refreshDebounce?.cancel();
    super.dispose();
  }

  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 800), () => unawaited(_reload()));
  }

  Future<void> _reload() async {
    try {
      final page = await _account.forumTopics(widget.chatId);
      if (!mounted) return;
      setState(() {
        _topics
          ..clear()
          ..addAll(page.topics);
        _lastPage = page;
        _hasMore = page.topics.isNotEmpty && _topics.length < page.totalCount;
        _error = null;
      });
    } on TdException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _loadMore() async {
    final last = _lastPage;
    if (_loading || !_hasMore || last == null) return;
    _loading = true;
    try {
      final page = await _account.forumTopics(
        widget.chatId,
        offsetDate: last.nextOffsetDate,
        offsetMessageId: last.nextOffsetMessageId,
        offsetTopicId: last.nextOffsetForumTopicId,
      );
      if (!mounted) return;
      setState(() {
        final known = _topics.map((t) => t.info.forumTopicId).toSet();
        _topics.addAll(page.topics.where((t) => !known.contains(t.info.forumTopicId)));
        _lastPage = page;
        _hasMore = page.topics.isNotEmpty;
      });
    } on TdException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      _loading = false;
    }
  }

  void _open(td.ForumTopic topic) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ChatScreen(chatId: widget.chatId, topicId: topic.info.forumTopicId, topicName: topic.info.name),
    ));
  }

  Future<void> _create() async {
    final s = context.s;
    final name = await promptText(context, title: s.t('topic_new'), label: s.t('topic_name'));
    if (name == null || name.isEmpty || !mounted) return;
    final emojiId = await _pickIcon();
    if (emojiId == null || !mounted) return;
    final info = await guard(
      context,
      () => _account.createTopic(widget.chatId, name, color: _topicColors[_topics.length % _topicColors.length], customEmojiId: emojiId),
    );
    if (info == null || !mounted) return;
    await _reload();
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ChatScreen(chatId: widget.chatId, topicId: info.forumTopicId, topicName: info.name),
    ));
  }

  /// Icon for a new topic from Telegram's default topic emoji; 0 keeps the colored circle, null cancels.
  Future<int?> _pickIcon() async {
    final s = context.s;
    final icons = await guard(context, () => _account.send<td.Stickers>(const td.GetForumTopicDefaultIcons()));
    if (!mounted) return null;
    if (icons == null || icons.stickers.isEmpty) return 0;
    return showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
          child: GridView.count(
            crossAxisCount: 6,
            padding: const EdgeInsets.all(12),
            shrinkWrap: true,
            children: [
              IconButton(tooltip: s.t('none'), icon: const Icon(Icons.circle_rounded, color: Color(0xFF6FB9F0)), onPressed: () => Navigator.pop(context, 0)),
              for (final sticker in icons.stickers)
                if (sticker.fullType case td.StickerFullTypeCustomEmoji(:final customEmojiId))
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => Navigator.pop(context, customEmojiId),
                    child: Center(child: CustomEmojiView(id: customEmojiId, size: 32, fallback: sticker.emoji)),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  /// Pinned topics in the user's order; dragging saves the new order.
  Future<void> _reorderPinned() async {
    final s = context.s;
    var pinned = [for (final t in _topics) if (t.isPinned) t];
    if (pinned.length < 2) {
      showToast(context, s.t('pinned_topics_min'));
      return;
    }
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
                guard(context, () => _account.send<td.Ok>(td.SetPinnedForumTopics(chatId: widget.chatId, forumTopicIds: [for (final t in pinned) t.info.forumTopicId])));
              },
              children: [
                for (final t in pinned)
                  ListTile(key: ValueKey(t.info.forumTopicId), title: Text(t.info.name), trailing: const Icon(Icons.drag_handle_rounded)),
              ],
            ),
          ),
        ),
      ),
    );
    await _reload();
  }

  /// Long-press actions; the server rejects the ones the user has no right to.
  Future<void> _showTopicMenu(td.ForumTopic cached) async {
    final s = context.s;
    // The cached row may be stale (closed, renamed by another admin); menu items follow the fresh state.
    final topic = await guard(context, () => _account.send<td.ForumTopic>(td.GetForumTopic(chatId: widget.chatId, forumTopicId: cached.info.forumTopicId))) ?? cached;
    if (!mounted) return;
    final info = topic.info;
    final muted = topic.notificationSettings.muteFor > 0;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (icon, key, value) in <(IconData, String, String)>[
                if (topic.unreadMentionCount > 0 || topic.unreadReactionCount > 0) (Icons.alternate_email_rounded, 'topic_read_mentions', 'read'),
                if (topic.unreadPollVoteCount > 0) (Icons.poll_outlined, 'topic_read_poll_votes', 'poll_votes'),
                (topic.isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded, topic.isPinned ? 'unpin' : 'pin', 'pin'),
                (muted ? Icons.notifications_rounded : Icons.notifications_off_rounded, muted ? 'unmute' : 'mute', 'mute'),
                (Icons.link_rounded, 'copy_link', 'link'),
                if (!info.isGeneral) (Icons.edit_rounded, 'topic_rename', 'rename'),
                if (info.isGeneral)
                  (info.isHidden ? Icons.visibility_rounded : Icons.visibility_off_rounded, info.isHidden ? 'topic_show_general' : 'topic_hide_general', 'hide')
                else
                  (info.isClosed ? Icons.lock_open_rounded : Icons.lock_rounded, info.isClosed ? 'topic_reopen' : 'topic_close', 'close'),
                (Icons.push_pin_outlined, 'unpin_all', 'unpin_all'),
                if (!info.isGeneral) (Icons.delete_rounded, 'topic_delete', 'delete'),
              ])
                ListTile(
                  leading: Icon(icon, color: value == 'delete' ? Theme.of(context).colorScheme.error : null),
                  title: Text(s.t(key), style: value == 'delete' ? TextStyle(color: Theme.of(context).colorScheme.error) : null),
                  onTap: () => Navigator.pop(context, value),
                ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'read':
        await guard(context, () => _account.readTopicMentionsAndReactions(info));
      case 'poll_votes':
        await guard(context, () => _account.send<td.Ok>(td.ReadAllForumTopicPollVotes(chatId: widget.chatId, forumTopicId: info.forumTopicId)));
      case 'pin':
        await guard(context, () => _account.setTopicPinned(info, !topic.isPinned));
      case 'mute':
        // Same "forever" value Telegram uses for muted chats.
        await guard(context, () => _account.setTopicMuted(topic, muted ? 0 : 0x7FFFFFFF));
      case 'link':
        final link = await guard(context, () => _account.topicLink(info));
        if (link != null) {
          await Clipboard.setData(ClipboardData(text: link));
          if (mounted) showToast(context, s.t('link_copied'));
        }
      case 'rename':
        final name = await promptText(context, title: s.t('topic_rename'), label: s.t('topic_name'), initial: info.name);
        if (name != null && name.isNotEmpty && mounted) await guard(context, () => _account.renameTopic(info, name));
      case 'hide':
        await guard(context, () => _account.setGeneralTopicHidden(widget.chatId, !info.isHidden));
      case 'close':
        await guard(context, () => _account.setTopicClosed(info, !info.isClosed));
      case 'unpin_all':
        await guard(context, () => _account.unpinAllTopicMessages(info));
      case 'delete':
        final ok = await confirm(context, title: s.t('topic_delete'), message: s.t('topic_delete_confirm'), destructive: true);
        if (ok && mounted) await guard(context, () => _account.deleteTopic(info));
    }
    if (mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider(widget.chatId));
    final s = context.s;
    final visible = _topics.where((t) => !t.info.isHidden || t.info.isGeneral).toList();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatInfoScreen(chatId: widget.chatId))),
          child: Row(
            children: [
              ChatAvatar(chatId: widget.chatId, size: 40, showOnline: false),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(chat?.title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
                    Text(s.count('topics', _lastPage?.totalCount ?? _topics.length),
                        style: TextStyle(fontSize: 13, color: context.onAppBarMuted, fontWeight: FontWeight.w400)),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: s.t('view_as_messages'),
            icon: const Icon(Icons.chat_rounded),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatScreen(chatId: widget.chatId))),
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              switch (value) {
                case 'pinned':
                  await _reorderPinned();
                case 'as_messages':
                  // Remembered by Telegram: next time the forum opens as one message list.
                  await guard(context, () => _account.send<td.Ok>(td.ToggleChatViewAsTopics(chatId: widget.chatId, viewAsTopics: false)));
                  if (context.mounted) Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => ChatScreen(chatId: widget.chatId)));
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'pinned', child: Text(s.t('pinned_reorder'))),
              PopupMenuItem(value: 'as_messages', child: Text(s.t('view_as_messages_default'))),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: _error != null && _topics.isEmpty
            ? ListView(children: [Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center))])
            : _topics.isEmpty && _lastPage == null
                ? const Center(child: CircularProgressIndicator())
                : NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.extentAfter < 400) unawaited(_loadMore());
                      return false;
                    },
                    child: ListView.separated(
                      itemCount: visible.length,
                      separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                      itemBuilder: (context, index) => _TopicTile(
                        topic: visible[index],
                        onTap: () => _open(visible[index]),
                        onLongPress: () => _showTopicMenu(visible[index]),
                      ),
                    ),
                  ),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: s.t('topic_new'),
        onPressed: _create,
        child: const Icon(Icons.add_comment_rounded),
      ),
    );
  }
}

class _TopicTile extends ConsumerWidget {
  const _TopicTile({required this.topic, required this.onTap, required this.onLongPress});

  final td.ForumTopic topic;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final info = topic.info;
    final color = Color(0xFF000000 | (info.icon.color == 0 ? 0x6FB9F0 : info.icon.color));
    final last = topic.lastMessage;
    final sender = last == null ? '' : account.senderName(last.senderId);
    final muted = topic.notificationSettings.muteFor > 0;
    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: color.withValues(alpha: 0.18),
        child: Icon(info.isGeneral ? Icons.tag_rounded : Icons.chat_bubble_rounded, color: color),
      ),
      title: Row(
        children: [
          Expanded(child: Text(info.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
          if (info.isClosed) Padding(padding: const EdgeInsets.only(left: 4), child: Icon(Icons.lock_rounded, size: 15, color: Theme.of(context).hintColor)),
          if (last != null)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(formatChatTime(last.date, s.locale), style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
            ),
        ],
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              last == null ? '' : '${sender.isEmpty ? '' : '$sender: '}${messagePreview(last, account, s)}'.replaceAll('\n', ' '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (topic.isPinned) Icon(Icons.push_pin_rounded, size: 15, color: Theme.of(context).hintColor),
          if (topic.unreadMentionCount > 0)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: CircleAvatar(radius: 10, backgroundColor: Theme.of(context).colorScheme.primary, child: const Text('@', style: TextStyle(fontSize: 12, color: Colors.white))),
            ),
          if (topic.unreadCount > 0)
            Container(
              margin: const EdgeInsets.only(left: 4),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: muted ? Theme.of(context).hintColor : Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(formatCount(topic.unreadCount), style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }
}
