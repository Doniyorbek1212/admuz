import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/calls/call_service.dart';
import '../../core/calls/call_session.dart';
import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../widgets/common.dart';

/// Full-screen voice/video call, Telegram style: peer avatar or remote video, status, emoji key, controls.
class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key, required this.session});

  final CallSession session;

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  Timer? _ticker;
  bool _showKey = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onChange);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.session.phase == CallPhase.active && mounted) setState(() {});
    });
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker?.cancel();
    widget.session.removeListener(_onChange);
    super.dispose();
  }

  String _status(Strings s) {
    final session = widget.session;
    return switch (session.phase) {
      CallPhase.ringing => s.t(session.isOutgoing ? 'call_ringing' : (session.call.isVideo ? 'call_incoming_video' : 'call_incoming')),
      CallPhase.connecting => s.t('call_connecting'),
      CallPhase.active => formatDuration(session.duration),
      CallPhase.ended => s.t(switch (session.endReason) {
          td.CallDiscardReasonDeclined() => 'call_declined',
          td.CallDiscardReasonMissed() => 'call_missed',
          td.CallDiscardReasonDisconnected() => 'call_failed',
          _ => 'call_ended',
        }),
    };
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final session = widget.session;
    final incomingRinging = !session.isOutgoing && session.phase == CallPhase.ringing;
    final user = session.account.users[session.call.userId];
    final name = user == null ? '' : '${user.firstName} ${user.lastName}'.trim();
    return PopScope(
      canPop: session.phase == CallPhase.ended,
      child: Scaffold(
        backgroundColor: const Color(0xFF0E1A24),
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (session.remoteVideo)
              RTCVideoView(session.remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
            else
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF1B6E68), Color(0xFF0E1A24)]),
                ),
              ),
            SafeArea(
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.topRight,
                    child: session.emojis.isEmpty
                        ? const SizedBox(height: 48)
                        : TextButton(
                            onPressed: () => setState(() => _showKey = !_showKey),
                            child: Text(session.emojis.join(' '), style: const TextStyle(fontSize: 22)),
                          ),
                  ),
                  if (_showKey)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(s.t('call_key_hint', {'name': user?.firstName ?? ''}), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                    ),
                  const SizedBox(height: 24),
                  if (!session.remoteVideo) UserAvatar(userId: session.call.userId, size: 128, showOnline: false),
                  const SizedBox(height: 16),
                  Text(name, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Text(_status(s), style: const TextStyle(color: Colors.white70, fontSize: 16)),
                  if (session.remoteMuted && session.phase == CallPhase.active)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(s.t('call_peer_muted', {'name': user?.firstName ?? ''}), style: const TextStyle(color: Colors.white60)),
                    ),
                  const Spacer(),
                  if (incomingRinging)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(40, 0, 40, 40),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _RoundButton(icon: Icons.call_end_rounded, color: const Color(0xFFE5484D), label: s.t('decline'), onTap: session.hangUp),
                          _RoundButton(
                            icon: session.call.isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                            color: const Color(0xFF2EAD5B),
                            label: s.t('accept'),
                            onTap: () => guard(context, session.accept),
                          ),
                        ],
                      ),
                    )
                  else if (session.phase == CallPhase.ended && session.needRating)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                      child: Column(
                        children: [
                          Text(s.t('call_rate'), style: const TextStyle(color: Colors.white, fontSize: 16)),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              for (var stars = 1; stars <= 5; stars++)
                                IconButton(
                                  icon: const Icon(Icons.star_rounded, color: Color(0xFFF5B830), size: 36),
                                  onPressed: () async {
                                    await guard(context, () => session.rate(stars));
                                    CallService.instance.close(session);
                                  },
                                ),
                            ],
                          ),
                          TextButton(onPressed: () => CallService.instance.close(session), child: Text(s.t('skip'), style: const TextStyle(color: Colors.white70))),
                        ],
                      ),
                    )
                  else if (session.phase != CallPhase.ended)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _RoundButton(icon: session.speaker ? Icons.volume_up_rounded : Icons.volume_down_rounded, active: session.speaker, label: s.t('call_speaker'), onTap: session.toggleSpeaker),
                          _RoundButton(icon: session.videoOn ? Icons.videocam_rounded : Icons.videocam_off_rounded, active: session.videoOn, label: s.t('call_video_short'), onTap: session.toggleVideo),
                          _RoundButton(icon: session.muted ? Icons.mic_off_rounded : Icons.mic_rounded, active: session.muted, label: s.t('call_mute'), onTap: () async => session.toggleMute()),
                          _RoundButton(icon: Icons.call_end_rounded, color: const Color(0xFFE5484D), label: s.t('call_end'), onTap: session.hangUp),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (session.videoOn)
              Positioned(
                right: 16,
                top: MediaQuery.paddingOf(context).top + 56,
                width: 110,
                height: 160,
                child: GestureDetector(
                  onTap: session.switchCamera,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: RTCVideoView(session.localRenderer, mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.label, required this.onTap, this.color, this.active = false});

  final IconData icon;
  final String label;
  final Future<void> Function() onTap;
  final Color? color;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final background = color ?? (active ? Colors.white : Colors.white24);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: background,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox.square(dimension: 64, child: Icon(icon, color: color == null && active ? Colors.black87 : Colors.white, size: 30)),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
      ],
    );
  }
}
