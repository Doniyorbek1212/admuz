import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../state/telegram.dart';
import 'call_session.dart';

/// Owns the account's calls: turns TDLib call updates into [CallSession]s and exposes the current one.
/// The UI listens to [current] and shows the call screen while it is set.
class CallService {
  CallService._();

  static final instance = CallService._();

  final current = ValueNotifier<CallSession?>(null);
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
    _account = null;
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
        await session.onCallUpdate(call);
        if (session.phase != CallPhase.ringing) _stopRinging();
        if (session.phase == CallPhase.ended) {
          _stopRinging();
          // A rating request keeps the screen open until the user rates or skips (see [close]).
          if (!session.needRating) {
            // Leave the "call ended" state visible for a moment before closing the screen.
            final ended = session;
            Timer(const Duration(milliseconds: 1500), () => close(ended));
          }
        }
      case td.UpdateNewCallSignalingData(:final callId, :final data):
        await _sessions[callId]?.onSignalingData(data);
      default:
        break;
    }
  }

  /// Drops an ended call and closes its screen.
  void close(CallSession session) {
    _sessions.remove(session.call.id);
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
