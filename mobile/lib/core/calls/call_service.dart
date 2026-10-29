import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../state/telegram.dart';
import 'call_session.dart';
import 'group_call_session.dart';

/// Owns the account's calls: turns TDLib call updates into [CallSession]s and exposes the current one.
/// The UI listens to [current] and shows the call screen while it is set.
class CallService {
  CallService._();

  static final instance = CallService._();

  final current = ValueNotifier<CallSession?>(null);

  /// The joined video chat, if any; its screen is opened by whoever joins and can be reopened from the chat.
  final currentGroup = ValueNotifier<GroupCallSession?>(null);
  final Map<int, CallSession> _sessions = {};
  StreamSubscription<td.Update>? _subscription;
  TelegramAccount? _account;
  Timer? _ringTimer;

  void attach(TelegramAccount account) {
    if (_account == account) return;
    detach();
    _account = account;
    _subscription = account.callEvents.listen(_onEvent);
  }

  void detach() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
    current.value = null;
    currentGroup.value?.dispose();
    currentGroup.value = null;
    _account = null;
  }

  /// Joins the chat's video chat (or returns the one already joined).
  Future<GroupCallSession?> joinVideoChat(int chatId, int groupCallId) async {
    final account = _account;
    if (account == null) return null;
    final joined = currentGroup.value;
    if (joined != null && !joined.ended) {
      if (joined.id == groupCallId) return joined;
      await leaveVideoChat();
    }
    final groupCall = await account.send<td.GroupCall>(td.GetGroupCall(groupCallId: groupCallId));
    final session = GroupCallSession(account, chatId, groupCall);
    currentGroup.value = session;
    try {
      await session.join();
    } on Object {
      currentGroup.value = null;
      session.dispose();
      rethrow;
    }
    return session;
  }

  /// Joins the group call of a live story posted by [posterChatId], leaving any other call.
  Future<GroupCallSession?> joinLiveStory(int posterChatId, int groupCallId) async {
    final account = _account;
    if (account == null) return null;
    if (currentGroup.value != null) await leaveVideoChat();
    final groupCall = await account.send<td.GroupCall>(td.GetGroupCall(groupCallId: groupCallId));
    final session = GroupCallSession(account, posterChatId, groupCall)..liveStory = true;
    currentGroup.value = session;
    try {
      await session.join();
    } on Object {
      currentGroup.value = null;
      session.dispose();
      rethrow;
    }
    return session;
  }

  /// Starts a new conference call ([input] null) or joins one by link / by its message, leaving any other call.
  Future<GroupCallSession?> joinConference({td.InputGroupCall? input}) async {
    final account = _account;
    if (account == null) return null;
    if (currentGroup.value != null) await leaveVideoChat();
    final session = await GroupCallSession.conference(account, input: input);
    currentGroup.value = session;
    return session;
  }

  Future<void> leaveVideoChat({bool endForAll = false}) async {
    final session = currentGroup.value;
    if (session == null) return;
    currentGroup.value = null;
    await (endForAll ? session.endForAll() : session.leave());
    session.dispose();
  }

  /// Starts a voice or video call; the call screen opens when TDLib reports the new call.
  Future<void> startCall(int userId, {bool video = false}) async {
    final account = _account;
    if (account == null) return;
    await account.send<td.CallId>(td.CreateCall(userId: userId, protocol: callProtocol, isVideo: video));
  }

  Future<void> _onEvent(td.Update update) async {
    final account = _account;
    if (account == null) return;
    switch (update) {
      case td.UpdateCall(:final call):
        var session = _sessions[call.id];
        if (session == null) {
          if (call.state is td.CallStateDiscarded || call.state is td.CallStateError) return;
          // A second call while one is running: Telegram shows it as busy, so decline it.
          if (current.value != null && current.value!.phase != CallPhase.ended && !call.isOutgoing) {
            await account.send<td.Ok>(td.DiscardCall(callId: call.id, isDisconnected: false, inviteLink: '', duration: 0, isVideo: false, connectionId: 0));
            return;
          }
          session = CallSession(account, call);
          _sessions[call.id] = session;
          await session.init();
          current.value = session;
          if (!call.isOutgoing) _startRinging(session);
        }
        final wasEnded = session.phase == CallPhase.ended;
        await session.onCallUpdate(call);
        if (session.phase != CallPhase.ringing) _stopRinging();
        // TDLib may repeat the final state; schedule the close only on the transition.
        if (session.phase == CallPhase.ended && !wasEnded) {
          _stopRinging();
          // A rating request keeps the screen open until the user rates or skips (see [close]).
          if (!session.needRating) {
            // Leave the "call ended" state visible for a moment before closing the screen.
            final ended = session;
            // An error message needs a bit longer to read than "call ended".
            final delay = Duration(milliseconds: session.error == null ? 1500 : 3000);
            Timer(delay, () => close(ended));
          }
        }
      case td.UpdateNewCallSignalingData(:final callId, :final data):
        await _sessions[callId]?.onSignalingData(data);
      case td.UpdateGroupCall(:final groupCall):
        final session = currentGroup.value;
        if (session?.id != groupCall.id) return;
        session!.onGroupCall(groupCall);
        if (session.ended) {
          currentGroup.value = null;
          session.dispose();
        }
      case td.UpdateGroupCallParticipant(:final groupCallId, :final participant):
        final session = currentGroup.value;
        if (session?.id == groupCallId) session!.onParticipant(participant);
      case td.UpdateNewGroupCallMessage(:final groupCallId, :final message):
        final session = currentGroup.value;
        if (session?.id == groupCallId) session!.onMessage(message);
      case td.UpdateGroupCallMessagesDeleted(:final groupCallId, :final messageIds):
        final session = currentGroup.value;
        if (session?.id == groupCallId) session!.onMessagesDeleted(messageIds);
      default:
        break;
    }
  }

  /// Drops an ended call and closes its screen.
  void close(CallSession session) {
    if (_sessions.remove(session.call.id) == null) return;
    if (current.value == session) current.value = null;
    session.dispose();
  }

  /// shortcut: vibration only; a real ringtone and a full-screen notification for a locked phone come later.
  void _startRinging(CallSession session) {
    _ringTimer?.cancel();
    _ringTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (session.phase == CallPhase.ringing) {
        unawaited(HapticFeedback.vibrate());
      } else {
        _stopRinging();
      }
    });
  }

  void _stopRinging() {
    _ringTimer?.cancel();
    _ringTimer = null;
  }
}
