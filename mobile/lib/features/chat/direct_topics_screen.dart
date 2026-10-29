import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../settings/privacy_screen.dart' show promptText;
import 'chat_screen.dart';

/// A channel's direct messages group as its admins see it: one topic per person who wrote to the channel.
class DirectTopicsScreen extends ConsumerStatefulWidget {
  const DirectTopicsScreen({super.key, required this.chatId});

  final int chatId;

  @override
  ConsumerState<DirectTopicsScreen> createState() => _DirectTopicsScreenState();
}

class _DirectTopicsScreenState extends ConsumerState<DirectTopicsScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _account.directTopicsRevision.addListener(_changed);
    unawaited(_load());
  }

  @override
  void dispose() {
    _account.directTopicsRevision.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  // Topics arrive as updateDirectMessagesChatTopic; TDLib answers 404 once all are loaded.
  Future<void> _load() async {
    try {
      for (var i = 0; i < 20; i++) {
        await _account.send<td.Ok>(td.LoadDirectMessagesChatTopics(chatId: widget.chatId, limit: 100));
      }
    } on TdException {
      // All topics loaded.
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _menu(td.DirectMessagesChatTopic topic) async {
    final s = context.s;
    // Fresh copy: the cached one may be older than the menu the user expects.
    final fresh = await guard(context, () => _account.send<td.DirectMessagesChatTopic>(td.GetDirectMessagesChatTopic(chatId: widget.chatId, topicId: topic.id)));
    if (!mounted) return;
    final t = fresh ?? topic;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: Icon(t.isMarkedAsUnread ? Icons.mark_chat_read_rounded : Icons.mark_chat_unread_rounded),
            title: Text(s.t(t.isMarkedAsUnread ? 'mark_read' : 'mark_unread')),
            onTap: () => Navigator.pop(context, 'unread'),
          ),
          if (t.unreadReactionCount > 0)
            ListTile(leading: const Icon(Icons.favorite_border_rounded), title: Text(s.t('read_reactions')), onTap: () => Navigator.pop(context, 'reactions')),
          ListTile(
            leading: Icon(t.canSendUnpaidMessages ? Icons.paid_rounded : Icons.money_off_rounded),
            title: Text(s.t(t.canSendUnpaidMessages ? 'dm_require_payment' : 'dm_allow_free')),
            onTap: () => Navigator.pop(context, 'free'),
          ),
          ListTile(leading: const Icon(Icons.star_outline_rounded), title: Text(s.t('dm_revenue')), onTap: () => Navigator.pop(context, 'revenue')),
          ListTile(leading: const Icon(Icons.push_pin_outlined), title: Text(s.t('unpin_all')), onTap: () => Navigator.pop(context, 'unpin')),
          ListTile(leading: const Icon(Icons.date_range_rounded), title: Text(s.t('clear_by_date')), onTap: () => Navigator.pop(context, 'by_date')),
          ListTile(
            leading: Icon(Icons.delete_outline_rounded, color: Theme.of(context).colorScheme.error),
            title: Text(s.t('clear_history'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () => Navigator.pop(context, 'clear'),
          ),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    final chatId = widget.chatId;
    switch (action) {
      case 'unread':
        await guard(context, () => _account.send<td.Ok>(td.SetDirectMessagesChatTopicIsMarkedAsUnread(chatId: chatId, topicId: t.id, isMarkedAsUnread: !t.isMarkedAsUnread)));
      case 'reactions':
        await guard(context, () => _account.send<td.Ok>(td.ReadAllDirectMessagesChatTopicReactions(chatId: chatId, topicId: t.id)));
      case 'free':
        var refund = false;
        if (!t.canSendUnpaidMessages) {
          refund = await confirm(context, title: s.t('dm_allow_free'), message: s.t('dm_refund_ask'), confirmLabel: s.t('dm_refund'));
          if (!mounted) return;
        }
        await guard(
          context,
          () => _account.send<td.Ok>(
            td.ToggleDirectMessagesChatTopicCanSendUnpaidMessages(chatId: chatId, topicId: t.id, canSendUnpaidMessages: !t.canSendUnpaidMessages, refundPayments: refund),
          ),
        );
      case 'revenue':
        final stars = await guard(context, () => _account.send<td.StarCount>(td.GetDirectMessagesChatTopicRevenue(chatId: chatId, topicId: t.id)));
        if (stars != null && mounted) showToast(context, s.t('dm_revenue_value', {'n': '${stars.starCount}'}));
      case 'unpin':
        await guard(context, () => _account.send<td.Ok>(td.UnpinAllDirectMessagesChatTopicMessages(chatId: chatId, topicId: t.id)));
      case 'by_date':
        final range = await showDateRangePicker(context: context, firstDate: DateTime(2013, 8), lastDate: DateTime.now(), helpText: s.t('clear_by_date'), saveText: s.t('delete'));
        if (range == null || !mounted) return;
        final ok = await confirm(context, title: s.t('clear_by_date'), message: s.t('clear_history_confirm'), destructive: true);
        if (!ok || !mounted) return;
        await guard(
          context,
          () => _account.send<td.Ok>(td.DeleteDirectMessagesChatTopicMessagesByDate(
            chatId: chatId,
            topicId: t.id,
            minDate: range.start.millisecondsSinceEpoch ~/ 1000,
            maxDate: DateTime(range.end.year, range.end.month, range.end.day, 23, 59, 59).millisecondsSinceEpoch ~/ 1000,
          )),
        );
      case 'clear':
        final ok = await confirm(context, title: s.t('clear_history'), message: s.t('clear_history_confirm'), destructive: true);
        if (ok && mounted) await guard(context, () => _account.send<td.Ok>(td.DeleteDirectMessagesChatTopicHistory(chatId: chatId, topicId: t.id)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final chat = ref.watch(chatProvider(widget.chatId));
    final topics = (_account.directTopics[widget.chatId]?.values ?? const <td.DirectMessagesChatTopic>[]).where((t) => t.order != 0).toList()
      ..sort((a, b) => b.order.compareTo(a.order));
    return Scaffold(
      appBar: AppBar(
        title: Text(chat == null ? '' : chatTitle(chat, _account, s)),
        actions: [
          IconButton(
            tooltip: s.t('view_as_messages'),
            icon: const Icon(Icons.chat_rounded),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatScreen(chatId: widget.chatId))),
          ),
        ],
      ),
      body: topics.isEmpty
          ? Center(child: _loading ? const CircularProgressIndicator() : Text(s.t('nothing_here')))
          : ListView.separated(
              itemCount: topics.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
              itemBuilder: (context, index) {
                final topic = topics[index];
                final last = topic.lastMessage;
                final unread = topic.unreadCount > 0 || topic.isMarkedAsUnread;
                return ListTile(
                  leading: _senderAvatar(topic.senderId),
                  title: Text(_account.senderName(topic.senderId), maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: last == null ? null : Text(messagePreview(last, _account, s), maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    if (last != null) Text(formatChatTime(last.date, s.locale), style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                    if (unread)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(10)),
                        child: Text(topic.unreadCount > 0 ? '${topic.unreadCount}' : '', style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontSize: 12)),
                      ),
                  ]),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DirectTopicChatScreen(chatId: widget.chatId, topic: topic))),
                  onLongPress: () => _menu(topic),
                );
              },
            ),
    );
  }
}

Widget _senderAvatar(td.MessageSender sender, {double size = 46}) => switch (sender) {
      td.MessageSenderUser(:final userId) => UserAvatar(userId: userId, size: size, showOnline: false),
      td.MessageSenderChat(:final chatId) => ChatAvatar(chatId: chatId, size: size, showOnline: false),
      _ => SizedBox.square(dimension: size),
    };

/// One person's conversation in a channel's direct messages: history, jump to a date, and a reply box.
class DirectTopicChatScreen extends ConsumerStatefulWidget {
  const DirectTopicChatScreen({super.key, required this.chatId, required this.topic});

  final int chatId;
  final td.DirectMessagesChatTopic topic;

  @override
  ConsumerState<DirectTopicChatScreen> createState() => _DirectTopicChatScreenState();
}

class _DirectTopicChatScreenState extends ConsumerState<DirectTopicChatScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  final _text = TextEditingController();
  List<td.Message>? _messages;
  int? _highlight;
  StreamSubscription<td.Update>? _updates;

  @override
  void initState() {
    super.initState();
    _updates = _account.messageEvents.listen((update) {
      if (update is td.UpdateNewMessage && update.message.chatId == widget.chatId && _inTopic(update.message)) unawaited(_load());
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _updates?.cancel();
    _text.dispose();
    super.dispose();
  }

  bool _inTopic(td.Message message) => message.topicId is td.MessageTopicDirectMessages &&
      (message.topicId as td.MessageTopicDirectMessages).directMessagesChatTopicId == widget.topic.id;

  Future<void> _load({int fromMessageId = 0, int offset = 0}) async {
    final result = await guard(
      context,
      () => _account.send<td.Messages>(td.GetDirectMessagesChatTopicHistory(
        chatId: widget.chatId,
        topicId: widget.topic.id,
        fromMessageId: fromMessageId,
        offset: offset,
        limit: 100,
      )),
    );
    if (mounted) setState(() => _messages = result?.messages ?? const []);
  }

  Future<void> _goToDate() async {
    final picked = await showDatePicker(context: context, firstDate: DateTime(2013, 8), lastDate: DateTime.now(), initialDate: DateTime.now());
    if (picked == null || !mounted) return;
    final message = await guard(
      context,
      () => _account.send<td.Message>(
        td.GetDirectMessagesChatTopicMessageByDate(chatId: widget.chatId, topicId: widget.topic.id, date: picked.millisecondsSinceEpoch ~/ 1000),
      ),
    );
    if (message == null || !mounted) return;
    _highlight = message.id;
    // Starts the page a little after the found message so it sits inside the list.
    await _load(fromMessageId: message.id, offset: -20);
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    _text.clear();
    await guard(
      context,
      () => _account.send<td.Message>(td.SendMessage(
        chatId: widget.chatId,
        topicId: td.MessageTopicDirectMessages(directMessagesChatTopicId: widget.topic.id),
        replyTo: null,
        options: null,
        replyMarkup: null,
        inputMessageContent: td.InputMessageText(text: formattedText(text), linkPreviewOptions: null, clearDraft: true),
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final messages = _messages;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          _senderAvatar(widget.topic.senderId, size: 38),
          const SizedBox(width: 10),
          Expanded(child: Text(_account.senderName(widget.topic.senderId), maxLines: 1, overflow: TextOverflow.ellipsis)),
        ]),
        actions: [IconButton(tooltip: s.t('go_to_date'), icon: const Icon(Icons.calendar_month_rounded), onPressed: _goToDate)],
      ),
      body: Column(children: [
        Expanded(
          child: messages == null
              ? const Center(child: CircularProgressIndicator())
              : messages.isEmpty
                  ? Center(child: Text(s.t('nothing_here')))
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final m = messages[index];
                        final mine = m.isOutgoing;
                        return Align(
                          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
                            decoration: BoxDecoration(
                              color: m.id == _highlight ? scheme.tertiaryContainer : (mine ? scheme.primaryContainer : scheme.surfaceContainerHighest),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                              Text(messagePreview(m, _account, s)),
                              if (m.suggestedPostInfo case final post?) _SuggestedPostBar(message: m, post: post, onChanged: _load),
                              Text(formatTime(m.date, s.locale), style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
                            ]),
                          ),
                        );
                      },
                    ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(hintText: s.t('message'), border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)), isDense: true),
                  onSubmitted: (_) => _send(),
                ),
              ),
              IconButton(icon: const Icon(Icons.send_rounded), color: scheme.primary, onPressed: _send),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// A post someone suggested to the channel: its price and state, with approve / decline for admins
/// and "offer another price" for the author.
class _SuggestedPostBar extends ConsumerWidget {
  const _SuggestedPostBar({required this.message, required this.post, required this.onChanged});

  final td.Message message;
  final td.SuggestedPostInfo post;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final price = switch (post.price) {
      td.SuggestedPostPriceStar(:final starCount) => '⭐ $starCount',
      _ => s.t('free'),
    };
    final state = switch (post.state) {
      td.SuggestedPostStateApproved() => s.t('suggested_post_approved'),
      td.SuggestedPostStateDeclined() => s.t('suggested_post_declined'),
      _ => s.t('suggested_post_pending'),
    };
    Future<void> act(Future<void> Function() action) async {
      await guard(context, () async {
        await action();
        return true;
      });
      await onChanged();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        Text('${s.t('suggested_post')} · $price · $state', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        Wrap(spacing: 4, children: [
          if (post.canBeApproved)
            TextButton(
              onPressed: () => act(() => account.send<td.Ok>(td.ApproveSuggestedPost(
                    chatId: message.chatId,
                    messageId: message.id,
                    // No date chosen by the author: publish in a minute.
                    sendDate: post.sendDate != 0 ? 0 : DateTime.now().add(const Duration(minutes: 1)).millisecondsSinceEpoch ~/ 1000,
                  ))),
              child: Text(s.t('accept')),
            ),
          if (post.canBeDeclined)
            TextButton(
              onPressed: () async {
                final comment = await promptText(context, title: s.t('decline'), label: s.t('suggested_post_comment'));
                if (comment == null || !context.mounted) return;
                await act(() => account.send<td.Ok>(td.DeclineSuggestedPost(chatId: message.chatId, messageId: message.id, comment: comment.trim())));
              },
              child: Text(s.t('decline')),
            ),
          if (post.state is td.SuggestedPostStatePending)
            TextButton(
              onPressed: () async {
                final text = await promptText(context, title: s.t('suggested_post_offer'), label: '⭐', keyboard: TextInputType.number);
                final stars = int.tryParse(text ?? '');
                if (stars == null || !context.mounted) return;
                await act(() => account.send<td.Message>(td.AddOffer(
                      chatId: message.chatId,
                      messageId: message.id,
                      options: sendOptions().copyWith(
                        suggestedPostInfo: td.InputSuggestedPostInfo(price: stars > 0 ? td.SuggestedPostPriceStar(starCount: stars) : null, sendDate: 0),
                      ),
                    )));
              },
              child: Text(s.t('suggested_post_offer')),
            ),
        ]),
      ]),
    );
  }
}
