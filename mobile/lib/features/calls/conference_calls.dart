import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/calls/call_service.dart';
import '../../core/calls/group_call_session.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../contacts/contacts_screen.dart';
import '../settings/privacy_screen.dart' show promptText;
import 'video_chat_screen.dart';

/// Starts a new conference call (no chat needed), or joins one by its t.me/call link, and opens its screen.
Future<void> startConference(BuildContext context, {td.InputGroupCall? input}) async {
  final session = await guard(context, () async => (await CallService.instance.joinConference(input: input))!);
  if (session == null || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => VideoChatScreen(session: session)));
}

Future<void> joinConferenceByLink(BuildContext context) async {
  final s = context.s;
  final link = await promptText(context, title: s.t('conference_join'), label: 'https://t.me/call/…', keyboard: TextInputType.url);
  if (link == null || link.isEmpty || !context.mounted) return;
  await startConference(context, input: td.InputGroupCallLink(link: link));
}

/// Invites contacts into a conference call one by one, reporting who could not be added.
Future<void> inviteToConference(BuildContext context, GroupCallSession session) async {
  final s = context.s;
  final ids = await Navigator.of(context).push<List<int>>(MaterialPageRoute(builder: (_) => const ContactsScreen(pickMany: true)));
  if (ids == null || ids.isEmpty || !context.mounted) return;
  final problems = <String>[];
  for (final userId in ids) {
    try {
      final result = await session.account.send<td.InviteGroupCallParticipantResult>(
        td.InviteGroupCallParticipant(groupCallId: session.id, userId: userId, isVideo: false),
      );
      final reason = switch (result) {
        td.InviteGroupCallParticipantResultUserPrivacyRestricted() => 'conference_invite_privacy',
        td.InviteGroupCallParticipantResultUserAlreadyParticipant() => 'conference_invite_already',
        td.InviteGroupCallParticipantResultUserWasBanned() => 'conference_invite_banned',
        _ => null,
      };
      if (reason != null) problems.add('${session.account.userName(userId)}: ${s.t(reason)}');
    } on TdException catch (error) {
      problems.add('${session.account.userName(userId)}: ${error.message}');
    }
  }
  if (!context.mounted) return;
  showToast(context, problems.isEmpty ? s.t('conference_invited') : problems.join('\n'));
}

Future<void> shareConferenceLink(GroupCallSession session) async {
  final link = session.groupCall.inviteLink;
  if (link.isNotEmpty) await SharePlus.instance.share(ShareParams(text: link));
}

Future<void> revokeConferenceLink(BuildContext context, GroupCallSession session) async {
  final s = context.s;
  if (!await confirm(context, title: s.t('conference_revoke_link'), message: s.t('conference_revoke_link_hint'), destructive: true) || !context.mounted) return;
  final done = await guard(context, () async {
    await session.account.send<td.Ok>(td.RevokeGroupCallInviteLink(groupCallId: session.id));
    return true;
  });
  if (done == true && context.mounted) showToast(context, s.t('link_revoked'));
}

Future<void> banFromConference(BuildContext context, GroupCallSession session, int userId) async {
  final s = context.s;
  if (!await confirm(context, title: s.t('conference_ban'), message: session.account.userName(userId), destructive: true) || !context.mounted) return;
  await guard(context, () => session.account.send<td.Ok>(td.BanGroupCallParticipants(groupCallId: session.id, userIds: [userId])));
}

/// Number of people in the call a "group call" message points to; null when it cannot be read.
final _conferenceSizeProvider = FutureProvider.autoDispose.family<int?, (int, int)>((ref, key) async {
  try {
    final result = await ref.watch(accountProvider).send<td.GroupCallParticipants>(
          td.GetGroupCallParticipants(inputGroupCall: td.InputGroupCallMessage(chatId: key.$1, messageId: key.$2), limit: 100),
        );
    return result.totalCount;
  } on TdException {
    return null;
  }
});

/// A conference-call invitation or record in a chat: join while it runs, or decline the invitation.
class GroupCallMessageView extends ConsumerWidget {
  const GroupCallMessageView({super.key, required this.message, required this.call});

  final td.Message message;
  final td.MessageGroupCall call;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final count = call.isActive ? ref.watch(_conferenceSizeProvider((message.chatId, message.id))).value : null;
    final title = s.t(call.wasMissed ? 'conference_missed' : (call.isActive ? 'conference_active' : 'conference_ended'));
    return SizedBox(
      width: 250,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(call.isVideo ? Icons.videocam_rounded : Icons.groups_rounded, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
        if (count != null) Text(s.count('video_chat_participants', count), style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
        if (call.isActive)
          Row(children: [
            FilledButton.tonal(
              onPressed: () => startConference(context, input: td.InputGroupCallMessage(chatId: message.chatId, messageId: message.id)),
              child: Text(s.t('conference_join')),
            ),
            const SizedBox(width: 8),
            if (!message.isOutgoing)
              TextButton(
                onPressed: () => guard(context, () => account.send<td.Ok>(td.DeclineGroupCallInvitation(chatId: message.chatId, messageId: message.id))),
                child: Text(s.t('decline')),
              ),
          ]),
      ]),
    );
  }
}

/// Bot answer that is still being written (streamed); "Stop" ends the generation.
class PendingBotMessageBar extends StatelessWidget {
  const PendingBotMessageBar({super.key, required this.account, required this.chatId});

  final TelegramAccount account;
  final int chatId;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: account.pendingBotMessagesRevision,
        builder: (context, _, _) {
          final pending = account.pendingBotMessages[chatId];
          if (pending == null) return const SizedBox.shrink();
          final s = context.s;
          final text = switch (pending.content) { td.MessageText(:final text) => text.text, _ => '' };
          return Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: ListTile(
              dense: true,
              leading: const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              title: Text(text.isEmpty ? s.t('bot_writing') : text, maxLines: 3, overflow: TextOverflow.ellipsis),
              trailing: pending.canStop
                  ? TextButton(
                      onPressed: () => guard(context, () => account.send<td.Ok>(td.StopPendingMessage(chatId: chatId, topicId: null, draftId: pending.draftId))),
                      child: Text(s.t('stop')),
                    )
                  : null,
            ),
          );
        },
      );
}
