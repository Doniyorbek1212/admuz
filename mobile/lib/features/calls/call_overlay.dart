import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/calls/call_service.dart';
import '../../core/calls/call_session.dart';
import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../widgets/common.dart';

/// Keeps a call alive and reachable when its screen is not on top, Telegram style:
/// - back on the call screen only hides it, and a "return to call" bar shows over the app;
/// - leaving the app shrinks the call into a floating window (Android picture-in-picture);
/// - an ongoing notification (foreground service) keeps the microphone working in the background.
class CallPresence {
  CallPresence._() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'pip':
          inPip.value = call.arguments == true;
        case 'open':
          onOpen?.call();
      }
    });
  }

  static final instance = CallPresence._();
  static const _channel = MethodChannel('uz.sado.app/call');

  /// The app is showing as the floating call window.
  final inPip = ValueNotifier<bool>(false);

  /// The full call screen is on top; otherwise the return bar shows.
  final screenOpen = ValueNotifier<bool>(false);

  /// Opens the call screen again (set by whoever owns the navigator).
  VoidCallback? onOpen;

  CallSession? _session;
  Strings? _strings;
  bool? _sentActive;
  bool? _sentVideo;
  CallPhase? _sentPhase;

  /// Follows [session] (null when there is none) and tells Android when the call needs its service.
  void track(CallSession? session, Strings strings) {
    _strings = strings;
    if (identical(session, _session)) return;
    _session?.removeListener(_sync);
    _session = session;
    session?.addListener(_sync);
    _sync();
  }

  void _sync() {
    final session = _session;
    final strings = _strings;
    // Mic and camera are in use from the moment the call is accepted or placed; an unanswered incoming call is not.
    final active = session != null && session.phase != CallPhase.ended && !(session.phase == CallPhase.ringing && !session.isOutgoing);
    final video = session?.videoOn ?? false;
    // Telegram asks for a rating after some calls: bring the hidden call screen back for it.
    if (session != null && session.phase == CallPhase.ended && session.needRating && !screenOpen.value) onOpen?.call();
    if (active == _sentActive && video == _sentVideo && session?.phase == _sentPhase) return;
    _sentActive = active;
    _sentVideo = video;
    _sentPhase = session?.phase;
    if (!Platform.isAndroid || strings == null) return;
    final user = session?.account.users[session.call.userId];
    final name = user == null ? '' : '${user.firstName} ${user.lastName}'.trim();
    final since = session?.phase == CallPhase.active ? DateTime.now().subtract(session!.duration).millisecondsSinceEpoch : 0;
    unawaited(_channel.invokeMethod<void>('update', {
      'active': active,
      'video': video,
      'title': name.isEmpty ? strings.t('call_ongoing') : name,
      'text': strings.t(session?.phase == CallPhase.active ? 'call_ongoing' : 'call_connecting'),
      'since': since,
    }).catchError((Object error) => debugPrint('call presence not sent: $error')));
  }
}

/// Wraps the whole app: the "return to call" bar while the call screen is hidden, and the compact call view
/// while the app is a floating window. The app below stays mounted (offstage), so nothing loses its state.
class CallOverlay extends StatelessWidget {
  const CallOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final presence = CallPresence.instance;
    return ValueListenableBuilder<CallSession?>(
      valueListenable: CallService.instance.current,
      builder: (context, session, _) => ListenableBuilder(
        listenable: Listenable.merge([presence.inPip, presence.screenOpen, ?session]),
        builder: (context, _) {
            final pip = presence.inPip.value;
            final live = session != null && session.phase != CallPhase.ended;
            final floating = pip && session != null;
            // A finished call has nothing to return to; the bar goes the moment it ends.
            final bar = live && !presence.screenOpen.value && !pip;
            return Stack(
              fit: StackFit.expand,
              children: [
                Offstage(
                  offstage: floating,
                  child: bar
                      ? Column(
                          children: [
                            _ReturnBar(session: session),
                            Expanded(child: MediaQuery.removePadding(context: context, removeTop: true, child: child)),
                          ],
                        )
                      : child,
                ),
                if (floating) _FloatingCall(session: session),
              ],
            );
        },
      ),
    );
  }
}

/// Re-renders every second while a call is active (the timer).
mixin _Ticking<T extends StatefulWidget> on State<T> {
  CallSession get session;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    session.addListener(_changed);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _changed());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker?.cancel();
    session.removeListener(_changed);
    super.dispose();
  }
}

String _callStatus(CallSession session, Strings s) => switch (session.phase) {
      CallPhase.active => formatDuration(session.duration),
      CallPhase.ended => s.t('call_ended'),
      CallPhase.ringing => s.t(session.isOutgoing ? 'call_ringing' : 'call_incoming'),
      CallPhase.connecting => s.t('call_connecting'),
    };

String _peerName(CallSession session) {
  final user = session.account.users[session.call.userId];
  return user == null ? '' : '${user.firstName} ${user.lastName}'.trim();
}

class _ReturnBar extends StatefulWidget {
  const _ReturnBar({required this.session});

  final CallSession session;

  @override
  State<_ReturnBar> createState() => _ReturnBarState();
}

class _ReturnBarState extends State<_ReturnBar> with _Ticking {
  @override
  CallSession get session => widget.session;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Material(
      color: const Color(0xFF2EAD5B),
      child: InkWell(
        onTap: CallPresence.instance.onOpen,
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: 38,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Icon(session.call.isVideo ? Icons.videocam_rounded : Icons.call_rounded, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${s.t('call_return')} · ${_peerName(session)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                    ),
                  ),
                  Text(
                    _callStatus(session, s),
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The call as Android's floating window: the other side's video, or their photo, name and the timer.
class _FloatingCall extends StatefulWidget {
  const _FloatingCall({required this.session});

  final CallSession session;

  @override
  State<_FloatingCall> createState() => _FloatingCallState();
}

class _FloatingCallState extends State<_FloatingCall> with _Ticking {
  @override
  CallSession get session => widget.session;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Material(
      color: const Color(0xFF0E1A24),
      child: session.remoteVideo
          ? Stack(
              fit: StackFit.expand,
              children: [
                RTCVideoView(session.remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: Text(_callStatus(session, s), style: const TextStyle(color: Colors.white, fontSize: 13, shadows: [Shadow(blurRadius: 4)])),
                ),
              ],
            )
          : DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF1B6E68), Color(0xFF0E1A24)]),
              ),
              child: LayoutBuilder(
                builder: (context, box) {
                  final avatar = (box.biggest.shortestSide * 0.42).clamp(32.0, 96.0);
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: FittedBox(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            UserAvatar(userId: session.call.userId, size: avatar, showOnline: false),
                            const SizedBox(height: 6),
                            Text(_peerName(session), maxLines: 1, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                            Text(
                              _callStatus(session, s),
                              style: const TextStyle(color: Colors.white70, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]),
                            ),
                            if (session.muted) const Icon(Icons.mic_off_rounded, color: Colors.white70, size: 16),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
