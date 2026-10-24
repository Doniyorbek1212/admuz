import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';

/// "Recent actions": admin and member events of the last 48 hours in a supergroup or channel.
class EventLogScreen extends ConsumerStatefulWidget {
  const EventLogScreen({super.key, required this.chatId});

  final int chatId;

  @override
  ConsumerState<EventLogScreen> createState() => _EventLogScreenState();
}

class _EventLogScreenState extends ConsumerState<EventLogScreen> {
  List<td.ChatEvent>? _events;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final account = ref.read(accountProvider);
    final result = await guard(
      context,
      () => account.send<td.ChatEvents>(td.GetChatEventLog(chatId: widget.chatId, query: _query, fromEventId: 0, limit: 100, filters: null, userIds: const [])),
    );
    if (mounted) setState(() => _events = result?.events ?? const []);
  }

  Future<void> _reportFalsePositive(td.Message message) async {
    final supergroupId = switch (ref.read(accountProvider).chats[widget.chatId]?.type) {
      td.ChatTypeSupergroup(:final supergroupId) => supergroupId,
      _ => 0,
    };
    if (supergroupId == 0) return;
    final ok = await guard(context, () async {
      await ref.read(accountProvider).send<td.Ok>(td.ReportSupergroupAntiSpamFalsePositive(supergroupId: supergroupId, messageId: message.id));
      return true;
    });
    if (ok == true && mounted) showToast(context, context.t('report_sent'));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final events = _events;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('recent_actions'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: s.t('search')),
              onSubmitted: (value) {
                _query = value.trim();
                setState(() => _events = null);
                _load();
              },
            ),
          ),
          Expanded(
            child: events == null
                ? const Center(child: CircularProgressIndicator())
                : events.isEmpty
                    ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(s.t('recent_actions_empty'), textAlign: TextAlign.center)))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          itemCount: events.length,
                          separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                          itemBuilder: (context, index) {
                            final event = events[index];
                            final actor = account.senderName(event.memberId);
                            final detail = eventDetail(event.action, account, s);
                            final deleted = event.action is td.ChatEventMessageDeleted ? event.action as td.ChatEventMessageDeleted : null;
                            return ListTile(
                              leading: switch (event.memberId) {
                                td.MessageSenderUser(:final userId) => UserAvatar(userId: userId, size: 44, showOnline: false),
                                td.MessageSenderChat(:final chatId) => ChatAvatar(chatId: chatId, size: 44, showOnline: false),
                                _ => const SizedBox.square(dimension: 44),
                              },
                              title: Text(actor, style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: Text('${detail.title}${detail.body.isEmpty ? '' : '\n${detail.body}'}'),
                              isThreeLine: detail.body.isNotEmpty,
                              trailing: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(formatTime(event.date, s.locale), style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                                  if (deleted != null && deleted.canReportAntiSpamFalsePositive)
                                    TextButton(onPressed: () => _reportFalsePositive(deleted.message), child: Text(s.t('not_spam'))),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

/// Short title and optional detail line for one event; unknown kinds fall back to a generic label.
({String title, String body}) eventDetail(td.ChatEventAction action, TelegramAccount account, Strings s) {
  String preview(td.Message message) => (contentPreview(message.content, s) ?? '').replaceAll('\n', ' ');
  return switch (action) {
    td.ChatEventMessageDeleted(:final message) => (title: s.t('log_message_deleted'), body: preview(message)),
    td.ChatEventMessageEdited(:final newMessage) => (title: s.t('log_message_edited'), body: preview(newMessage)),
    td.ChatEventMessagePinned(:final message) => (title: s.t('log_message_pinned'), body: preview(message)),
    td.ChatEventMessageUnpinned(:final message) => (title: s.t('log_message_unpinned'), body: preview(message)),
    td.ChatEventPollStopped(:final message) => (title: s.t('log_poll_stopped'), body: preview(message)),
    td.ChatEventMemberJoined() || td.ChatEventMemberJoinedByInviteLink() || td.ChatEventMemberJoinedByRequest() => (title: s.t('log_joined'), body: ''),
    td.ChatEventMemberLeft() => (title: s.t('log_left'), body: ''),
    td.ChatEventMemberInvited(:final userId) => (title: s.t('log_invited'), body: account.userName(userId)),
    td.ChatEventMemberPromoted(:final userId) => (title: s.t('log_promoted'), body: account.userName(userId)),
    td.ChatEventMemberRestricted(:final memberId, :final newStatus) =>
      (title: s.t(newStatus is td.ChatMemberStatusBanned ? 'log_banned' : 'log_restricted'), body: account.senderName(memberId)),
    td.ChatEventTitleChanged(:final newTitle) => (title: s.t('log_title_changed'), body: newTitle),
    td.ChatEventDescriptionChanged(:final newDescription) => (title: s.t('log_description_changed'), body: newDescription),
    td.ChatEventUsernameChanged(:final newUsername) => (title: s.t('log_username_changed'), body: newUsername.isEmpty ? '' : '@$newUsername'),
    td.ChatEventPhotoChanged() => (title: s.t('log_photo_changed'), body: ''),
    td.ChatEventSlowModeDelayChanged(:final newSlowModeDelay) => (title: s.t('log_slow_mode'), body: '$newSlowModeDelay s'),
    td.ChatEventPermissionsChanged() => (title: s.t('log_permissions'), body: ''),
    td.ChatEventInviteLinkRevoked() || td.ChatEventInviteLinkDeleted() || td.ChatEventInviteLinkEdited() => (title: s.t('log_invite_link'), body: ''),
    td.ChatEventForumTopicCreated() || td.ChatEventForumTopicEdited() || td.ChatEventForumTopicDeleted() || td.ChatEventForumTopicPinned() ||
    td.ChatEventForumTopicToggleIsClosed() || td.ChatEventForumTopicToggleIsHidden() =>
      (title: s.t('log_topic'), body: ''),
    td.ChatEventVideoChatCreated() || td.ChatEventVideoChatEnded() => (title: s.t('log_video_chat'), body: ''),
    _ => (title: s.t('log_settings_changed'), body: ''),
  };
}
