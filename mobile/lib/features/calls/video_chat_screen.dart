import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/calls/call_service.dart';
import '../../core/calls/group_call_session.dart';
import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../contacts/contacts_screen.dart';
import '../settings/privacy_screen.dart' show pickOption, promptText;

/// Whether the current user may start and manage video chats in [chat].
bool canManageVideoChats(TelegramAccount account, td.Chat chat) => switch (account.myStatus(chat)) {
      td.ChatMemberStatusCreator() => true,
      td.ChatMemberStatusAdministrator(:final rights) => rights.canManageVideoChats,
      _ => false,
    };

/// Start now or schedule a video chat, then join it.
Future<void> startVideoChat(BuildContext context, TelegramAccount account, td.Chat chat) async {
  final s = context.s;
  final mode = await pickOption<String>(context, s.t('video_chat_start'), {
    'now': s.t('video_chat_start_now'),
    'schedule': s.t('video_chat_schedule'),
    'rtmp': s.t('video_chat_rtmp'),
  }, null);
  if (mode == null || !context.mounted) return;
  var startDate = 0;
  if (mode == 'schedule') {
    final when = await _pickDateTime(context);
    if (when == null || !context.mounted) return;
    startDate = when.millisecondsSinceEpoch ~/ 1000;
  }
  final created = await guard(context, () => account.send<td.GroupCallId>(td.CreateVideoChat(chatId: chat.id, title: '', startDate: startDate, isRtmpStream: mode == 'rtmp')));
  if (created == null || !context.mounted) return;
  if (mode == 'rtmp') return showRtmpSheet(context, account, chat.id);
  if (startDate == 0) await openVideoChat(context, account, chat.id, created.id);
}

Future<DateTime?> _pickDateTime(BuildContext context) async {
  final now = DateTime.now();
  final day = await showDatePicker(context: context, firstDate: now, lastDate: now.add(const Duration(days: 7)), initialDate: now);
  if (day == null || !context.mounted) return null;
  final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))));
  if (time == null) return null;
  final picked = DateTime(day.year, day.month, day.day, time.hour, time.minute);
  // Telegram wants the start at least 10 seconds ahead.
  return picked.isAfter(now.add(const Duration(seconds: 15))) ? picked : now.add(const Duration(minutes: 1));
}

/// Joins (or, for a scheduled one, shows) the chat's video chat and opens its screen.
Future<void> openVideoChat(BuildContext context, TelegramAccount account, int chatId, int groupCallId) async {
  final groupCall = await guard(context, () => account.send<td.GroupCall>(td.GetGroupCall(groupCallId: groupCallId)));
  if (groupCall == null || !context.mounted) return;
  if (groupCall.scheduledStartDate > 0) return _showScheduled(context, account, groupCall);
  final session = await guard(context, () => CallService.instance.joinVideoChat(chatId, groupCallId));
  if (session == null || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => VideoChatScreen(session: session), fullscreenDialog: true));
}

Future<void> _showScheduled(BuildContext context, TelegramAccount account, td.GroupCall groupCall) async {
  final s = context.s;
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.event_rounded),
            title: Text(groupCall.title.isEmpty ? s.t('video_chat') : groupCall.title),
            subtitle: Text(s.t('video_chat_scheduled_for', {'date': '${formatDayHeader(groupCall.scheduledStartDate, s)} ${formatTime(groupCall.scheduledStartDate, s.locale)}'})),
          ),
          if (groupCall.canBeManaged)
            ListTile(leading: const Icon(Icons.play_arrow_rounded), title: Text(s.t('video_chat_start_now')), onTap: () => Navigator.pop(context, 'start')),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_active_outlined),
            title: Text(s.t('video_chat_notify_me')),
            value: groupCall.enabledStartNotification,
            onChanged: (_) => Navigator.pop(context, 'notify'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  switch (action) {
    case 'start':
      await guard(context, () async {
        await account.send<td.Ok>(td.StartScheduledVideoChat(groupCallId: groupCall.id));
        return true;
      });
    case 'notify':
      await guard(context, () async {
        await account.send<td.Ok>(td.ToggleVideoChatEnabledStartNotification(groupCallId: groupCall.id, enabledStartNotification: !groupCall.enabledStartNotification));
        return true;
      });
  }
}

/// RTMP server URL and stream key for streaming from OBS and similar apps.
Future<void> showRtmpSheet(BuildContext context, TelegramAccount account, int chatId) async {
  final s = context.s;
  var rtmp = await guard(context, () => account.send<td.RtmpUrl>(td.GetVideoChatRtmpUrl(chatId: chatId)));
  if (rtmp == null || !context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        Widget row(String label, String value) => ListTile(
              title: Text(label),
              subtitle: Text(value, maxLines: 2, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.copy_rounded),
              onTap: () {
                unawaited(Clipboard.setData(ClipboardData(text: value)));
                showToast(context, s.t('copied'));
              },
            );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(title: Text(s.t('video_chat_rtmp'), style: const TextStyle(fontWeight: FontWeight.w600))),
              row(s.t('video_chat_rtmp_url'), rtmp!.url),
              row(s.t('video_chat_rtmp_key'), rtmp!.streamKey),
              ListTile(
                leading: Icon(Icons.refresh_rounded, color: Theme.of(context).colorScheme.error),
                title: Text(s.t('video_chat_rtmp_revoke'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: () async {
                  final fresh = await guard(context, () => account.send<td.RtmpUrl>(td.ReplaceVideoChatRtmpUrl(chatId: chatId)));
                  if (fresh != null) setState(() => rtmp = fresh);
                },
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// Bar above the chat while the chat has a video chat: join it, or return to it.
class VideoChatBar extends ConsumerWidget {
  const VideoChatBar({super.key, required this.chat});

  final td.Chat chat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final videoChat = chat.videoChat;
    return ValueListenableBuilder<GroupCallSession?>(
      valueListenable: CallService.instance.currentGroup,
      builder: (context, joined, _) {
        final inThisCall = joined != null && joined.id == videoChat.groupCallId;
        return Material(
          color: const Color(0xFF1B6E68),
          child: InkWell(
            onTap: () => inThisCall
                ? Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => VideoChatScreen(session: joined), fullscreenDialog: true))
                : openVideoChat(context, account, chat.id, videoChat.groupCallId),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
              child: Row(
                children: [
                  const Icon(Icons.graphic_eq_rounded, color: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(child: Text(s.t('video_chat'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600))),
                  FilledButton.tonal(
                    onPressed: null,
                    style: FilledButton.styleFrom(disabledBackgroundColor: Colors.white, disabledForegroundColor: const Color(0xFF1B6E68), visualDensity: VisualDensity.compact),
                    child: Text(s.t(inThisCall ? 'video_chat_return' : 'video_chat_join')),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The joined video chat: participants with speaking/muted state, microphone, admin tools.
class VideoChatScreen extends ConsumerStatefulWidget {
  const VideoChatScreen({super.key, required this.session});

  final GroupCallSession session;

  @override
  ConsumerState<VideoChatScreen> createState() => _VideoChatScreenState();
}

class _VideoChatScreenState extends ConsumerState<VideoChatScreen> {
  GroupCallSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onChange);
  }

  void _onChange() {
    if (!mounted) return;
    if (_session.ended) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _session.removeListener(_onChange);
    super.dispose();
  }

  Future<void> _leave() async {
    final s = context.s;
    final call = _session.groupCall;
    var endForAll = false;
    if (call.canBeManaged) {
      final choice = await pickOption<bool>(context, s.t('video_chat_leave'), {false: s.t('video_chat_leave'), true: s.t('video_chat_end_all')}, null);
      if (choice == null || !mounted) return;
      endForAll = choice;
    }
    await guard(context, () async {
      await CallService.instance.leaveVideoChat(endForAll: endForAll);
      return true;
    });
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _onMenu(String value) async {
    final s = context.s;
    final account = _session.account;
    final call = _session.groupCall;
    Future<void> run(td.TdFunction function) async {
      await guard(context, () async {
        await account.send<td.Ok>(function);
        return true;
      });
    }

    switch (value) {
      case 'title':
        final title = await promptText(context, title: s.t('video_chat_title_edit'), label: s.t('title'), initial: call.title);
        if (title != null && mounted) await run(td.SetVideoChatTitle(groupCallId: call.id, title: title));
      case 'mute_new':
        await run(td.ToggleVideoChatMuteNewParticipants(groupCallId: call.id, muteNewParticipants: !call.muteNewParticipants));
      case 'record':
        if (call.recordDuration > 0) {
          await run(td.EndGroupCallRecording(groupCallId: call.id));
        } else {
          await run(td.StartGroupCallRecording(groupCallId: call.id, title: call.title, recordVideo: false, usePortraitOrientation: false));
        }
      case 'link':
        final canSpeak = call.canBeManaged
            ? await pickOption<bool>(context, s.t('video_chat_invite_link'), {false: s.t('video_chat_invite_listener_link'), true: s.t('video_chat_invite_speaker_link')}, null)
            : false;
        if (canSpeak == null || !mounted) return;
        final link = await guard(context, () => account.send<td.HttpUrl>(td.GetVideoChatInviteLink(groupCallId: call.id, canSelfUnmute: canSpeak)));
        if (link != null) await SharePlus.instance.share(ShareParams(text: link.url));
      case 'invite':
        final ids = await Navigator.of(context).push<List<int>>(MaterialPageRoute(builder: (_) => const ContactsScreen(pickMany: true)));
        if (ids == null || ids.isEmpty || !mounted) return;
        await run(td.InviteVideoChatParticipants(groupCallId: call.id, userIds: ids));
      case 'display_as':
        await _pickDisplayAs();
      case 'rtmp':
        await showRtmpSheet(context, account, _session.chatId);
    }
  }

  Future<void> _pickDisplayAs() async {
    final s = context.s;
    final account = _session.account;
    final available = await guard(context, () => account.send<td.MessageSenders>(td.GetVideoChatAvailableParticipants(chatId: _session.chatId)));
    if (available == null || !mounted) return;
    final options = {for (final sender in available.senders) participantKey(sender): account.senderName(sender)};
    final picked = await pickOption<String>(context, s.t('video_chat_display_as'), options, null);
    if (picked == null || !mounted) return;
    final sender = available.senders.firstWhere((x) => participantKey(x) == picked);
    await guard(context, () async {
      await account.send<td.Ok>(td.SetVideoChatDefaultParticipant(chatId: _session.chatId, defaultParticipantId: sender));
      return true;
    });
    if (mounted) showToast(context, s.t('video_chat_display_as_next'));
  }

  Future<void> _participantMenu(td.GroupCallParticipant p) async {
    final s = context.s;
    final account = _session.account;
    final id = _session.id;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(account.senderName(p.participantId), style: const TextStyle(fontWeight: FontWeight.w600))),
            if (p.canBeMutedForAllUsers) ListTile(leading: const Icon(Icons.mic_off_rounded), title: Text(s.t('video_chat_mute_for_all')), onTap: () => Navigator.pop(context, 'mute_all')),
            if (p.canBeUnmutedForAllUsers && !p.isCurrentUser)
              ListTile(leading: const Icon(Icons.mic_rounded), title: Text(s.t('video_chat_allow_speak')), onTap: () => Navigator.pop(context, 'unmute_all')),
            if (p.canBeMutedForCurrentUser) ListTile(leading: const Icon(Icons.volume_off_rounded), title: Text(s.t('video_chat_mute_for_me')), onTap: () => Navigator.pop(context, 'mute_me')),
            if (p.canBeUnmutedForCurrentUser) ListTile(leading: const Icon(Icons.volume_up_rounded), title: Text(s.t('video_chat_unmute_for_me')), onTap: () => Navigator.pop(context, 'unmute_me')),
            if (p.isHandRaised && (_session.groupCall.canBeManaged || p.isCurrentUser))
              ListTile(leading: const Icon(Icons.back_hand_outlined), title: Text(s.t('video_chat_lower_hand')), onTap: () => Navigator.pop(context, 'lower_hand')),
            if (!p.isCurrentUser) ListTile(leading: const Icon(Icons.tune_rounded), title: Text(s.t('video_chat_volume')), onTap: () => Navigator.pop(context, 'volume')),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    Future<void> run(td.TdFunction function) async {
      await guard(context, () async {
        await account.send<td.Ok>(function);
        return true;
      });
    }

    switch (action) {
      case 'mute_all' || 'mute_me':
        await run(td.ToggleGroupCallParticipantIsMuted(groupCallId: id, participantId: p.participantId, isMuted: true));
      case 'unmute_all' || 'unmute_me':
        await run(td.ToggleGroupCallParticipantIsMuted(groupCallId: id, participantId: p.participantId, isMuted: false));
      case 'lower_hand':
        await run(td.ToggleGroupCallParticipantIsHandRaised(groupCallId: id, participantId: p.participantId, isHandRaised: false));
      case 'volume':
        final level = await _pickVolume(p.volumeLevel);
        // TDLib volume is in hundredths of a percent: 10000 = 100%.
        if (level != null && mounted) await run(td.SetGroupCallParticipantVolumeLevel(groupCallId: id, participantId: p.participantId, volumeLevel: level));
    }
  }

  Future<int?> _pickVolume(int current) {
    final s = context.s;
    var value = (current == 0 ? 10000 : current).clamp(1, 20000).toDouble();
    return showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(s.t('video_chat_volume')),
          content: Slider(value: value, min: 1, max: 20000, divisions: 40, label: '${(value / 100).round()}%', onChanged: (v) => setState(() => value = v)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
            TextButton(onPressed: () => Navigator.pop(context, value.round()), child: Text(s.t('save'))),
          ],
        ),
      ),
    );
  }

  String _participantStatus(td.GroupCallParticipant p, Strings s) {
    if (p.isHandRaised) return s.t('video_chat_hand_raised');
    if (p.isSpeaking) return s.t('video_chat_speaking');
    if (p.isMutedForCurrentUser || p.isMutedForAllUsers) return s.t('video_chat_muted');
    return s.t('video_chat_listening');
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final call = _session.groupCall;
    final account = _session.account;
    final chat = account.chats[_session.chatId];
    final me = _session.me;
    final handRaisedOnly = _session.muted && me != null && !me.canUnmuteSelf;
    final participants = _session.sortedParticipants;
    return Scaffold(
      backgroundColor: const Color(0xFF0E1A24),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(call.title.isNotEmpty ? call.title : (chat?.title ?? s.t('video_chat'))),
            Text(
              [
                s.count('video_chat_participants', call.participantCount),
                if (call.recordDuration > 0) s.t('video_chat_recording'),
              ].join(' · '),
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: _onMenu,
            itemBuilder: (context) => [
              if (call.canBeManaged) PopupMenuItem(value: 'title', child: Text(s.t('video_chat_title_edit'))),
              if (call.canToggleMuteNewParticipants)
                CheckedPopupMenuItem(value: 'mute_new', checked: call.muteNewParticipants, child: Text(s.t('video_chat_mute_new'))),
              if (call.canBeManaged) PopupMenuItem(value: 'record', child: Text(s.t(call.recordDuration > 0 ? 'video_chat_record_stop' : 'video_chat_record_start'))),
              PopupMenuItem(value: 'link', child: Text(s.t('video_chat_invite_link'))),
              PopupMenuItem(value: 'invite', child: Text(s.t('video_chat_invite'))),
              PopupMenuItem(value: 'display_as', child: Text(s.t('video_chat_display_as'))),
              if (call.canBeManaged) PopupMenuItem(value: 'rtmp', child: Text(s.t('video_chat_rtmp'))),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: participants.length,
              itemBuilder: (context, index) {
                final p = participants[index];
                final muted = p.isMutedForAllUsers || p.isMutedForCurrentUser;
                final name = account.senderName(p.participantId);
                return ListTile(
                  onTap: () => _participantMenu(p),
                  leading: DecoratedBox(
                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: p.isSpeaking ? const Color(0xFF2EAD5B) : Colors.transparent, width: 2.5)),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: switch (p.participantId) {
                        td.MessageSenderUser(:final userId) => UserAvatar(userId: userId, size: 42, showOnline: false),
                        td.MessageSenderChat(:final chatId) => ChatAvatar(chatId: chatId, size: 42, showOnline: false),
                        _ => const SizedBox.square(dimension: 42),
                      },
                    ),
                  ),
                  title: Text(p.isCurrentUser ? '$name (${s.t('video_chat_you')})' : name, style: const TextStyle(color: Colors.white)),
                  subtitle: Text(
                    _participantStatus(p, s),
                    style: TextStyle(color: p.isSpeaking ? const Color(0xFF2EAD5B) : (p.isHandRaised ? const Color(0xFFF5B830) : Colors.white54)),
                  ),
                  trailing: Icon(
                    p.isHandRaised ? Icons.back_hand_rounded : (muted ? Icons.mic_off_rounded : Icons.mic_rounded),
                    color: muted ? Colors.white38 : const Color(0xFF2EAD5B),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _CircleButton(icon: _session.speaker ? Icons.volume_up_rounded : Icons.phone_in_talk_rounded, label: s.t('call_speaker'), onTap: _session.toggleSpeaker),
                  _CircleButton(
                    icon: handRaisedOnly ? Icons.back_hand_rounded : (_session.muted ? Icons.mic_off_rounded : Icons.mic_rounded),
                    label: s.t(handRaisedOnly ? 'video_chat_raise_hand' : (_session.muted ? 'video_chat_unmute' : 'video_chat_mute')),
                    size: 88,
                    color: handRaisedOnly ? const Color(0xFFF5B830) : (_session.muted ? const Color(0xFF3D8BFF) : const Color(0xFF2EAD5B)),
                    onTap: () async {
                      await guard(context, () async {
                        await _session.toggleMute();
                        return true;
                      });
                    },
                  ),
                  _CircleButton(icon: Icons.call_end_rounded, label: s.t('video_chat_leave'), color: const Color(0xFFE5484D), onTap: _leave),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.icon, required this.label, required this.onTap, this.color, this.size = 60});

  final IconData icon;
  final String label;
  final Future<void> Function() onTap;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: color ?? Colors.white24,
            shape: const CircleBorder(),
            child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: SizedBox.square(dimension: size, child: Icon(icon, color: Colors.white, size: size * 0.45))),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
        ],
      );
}
