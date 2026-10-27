import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../state/telegram.dart';
import '../tdlib/td_client.dart';
import 'group_call_sdp.dart';

/// Stable map key for a participant (user or chat).
String participantKey(td.MessageSender sender) => switch (sender) {
      td.MessageSenderUser(:final userId) => 'u$userId',
      td.MessageSenderChat(:final chatId) => 'c$chatId',
      _ => '',
    };

/// A joined video chat (voice chat of a group or channel), audio only.
///
/// One peer connection to Telegram's SFU: the first m-line sends our microphone, each further m-line
/// receives one participant's audio SSRC. Participant changes renegotiate locally (offer from us,
/// answer synthesized from the join transport), the SFU itself is told nothing beyond the join.
/// shortcut: no participant video or screen sharing yet (needs simulcast SSRC groups and colibri constraints).
class GroupCallSession extends ChangeNotifier {
  GroupCallSession(this.account, this.chatId, this.groupCall);

  final TelegramAccount account;
  final int chatId;
  td.GroupCall groupCall;

  /// Participants by [participantKey], kept sorted by TDLib's order in [sortedParticipants].
  final Map<String, td.GroupCallParticipant> participants = {};
  bool muted = true;
  bool speaker = true;
  bool joined = false;
  bool ended = false;

  RTCPeerConnection? _pc;
  MediaStream? _local;
  GroupJoinTransport? _transport;
  String _sendMid = '0';
  final Map<String, int> _ssrcByMid = {};
  int _version = 1;
  Future<void> _negotiation = Future.value();
  Timer? _levelTimer;
  Set<int> _speaking = {};
  bool _selfSpeaking = false;
  bool _disposed = false;

  int get id => groupCall.id;

  td.GroupCallParticipant? get me => participants.values.where((p) => p.isCurrentUser).firstOrNull;

  List<td.GroupCallParticipant> get sortedParticipants =>
      participants.values.toList()..sort((a, b) => b.order.compareTo(a.order));

  /// Joins with the microphone muted, like Telegram does.
  Future<void> join({String inviteHash = ''}) async {
    // TDLib sends participant updates only for calls fetched with getGroupCall.
    groupCall = await account.send<td.GroupCall>(td.GetGroupCall(groupCallId: id));
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
      'video': false,
    });
    final track = _local!.getAudioTracks().first;
    track.enabled = !muted;
    final pc = await createPeerConnection({'sdpSemantics': 'unified-plan', 'bundlePolicy': 'max-bundle', 'rtcpMuxPolicy': 'require'});
    _pc = pc;
    await pc.addTransceiver(track: track, kind: RTCRtpMediaType.RTCRtpMediaTypeAudio, init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendOnly, streams: [_local!]));
    final offer = await _localOffer();
    _sendMid = offer.mids.first;
    final response = await account.send<td.Text>(td.JoinVideoChat(
      groupCallId: id,
      joinParameters: td.GroupCallJoinParameters(audioSourceId: signedSsrc(offer.audioSsrc), payload: buildJoinPayload(offer), isMuted: muted, isMyVideoEnabled: false),
      inviteHash: inviteHash,
    ));
    _transport = GroupJoinTransport.parse(response.text);
    await pc.setRemoteDescription(RTCSessionDescription(_answer(offer.mids), 'answer'));
    await Helper.setSpeakerphoneOn(speaker);
    joined = true;
    _levelTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => unawaited(_pollLevels()));
    _notify();
    await account.send<td.Ok>(td.LoadGroupCallParticipants(groupCallId: id, limit: 100));
  }

  Future<LocalOfferInfo> _localOffer() async {
    final pc = _pc!;
    final offer = await pc.createOffer();
    final sdp = normalizeOfferExtmaps(offer.sdp!);
    await pc.setLocalDescription(RTCSessionDescription(sdp, 'offer'));
    return parseLocalOffer(sdp);
  }

  String _answer(List<String> mids) =>
      buildRemoteAnswer(transport: _transport!, mids: mids, sendMid: _sendMid, ssrcByMid: _ssrcByMid, version: _version++);

  void onGroupCall(td.GroupCall updated) {
    groupCall = updated;
    if (!updated.isActive && joined) unawaited(_close());
    if (updated.needRejoin && joined) unawaited(_rejoin());
    _notify();
  }

  void onParticipant(td.GroupCallParticipant participant) {
    final key = participantKey(participant.participantId);
    // TDLib marks departed participants with order "" (empty).
    if (participant.order.isEmpty) {
      participants.remove(key);
    } else {
      participants[key] = participant;
    }
    // An admin muted us: the microphone must go silent here too.
    if (participant.isCurrentUser && participant.isMutedForAllUsers && !participant.canUnmuteSelf && !muted) {
      muted = true;
      for (final track in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
        track.enabled = false;
      }
    }
    _notify();
    _negotiation = _negotiation.then((_) => _syncRemoteAudio()).catchError((Object e) => debugPrint('group call renegotiation: $e'));
  }

  /// Gives every remote participant's audio SSRC its own receiving m-line.
  Future<void> _syncRemoteAudio() async {
    final pc = _pc;
    if (pc == null || _transport == null || _disposed) return;
    final wanted = {
      for (final p in participants.values)
        if (!p.isCurrentUser && p.audioSourceId != 0) p.audioSourceId,
    };
    final before = Map.of(_ssrcByMid);
    _ssrcByMid.removeWhere((_, ssrc) => !wanted.contains(ssrc));
    final missing = wanted.difference(_ssrcByMid.values.toSet());
    final transceivers = await pc.getTransceivers();
    final freeMids = [
      for (final t in transceivers)
        if (t.mid.isNotEmpty && t.mid != _sendMid && !_ssrcByMid.containsKey(t.mid)) t.mid,
    ];
    final pendingSsrcs = <int>[];
    for (final ssrc in missing) {
      if (freeMids.isNotEmpty) {
        _ssrcByMid[freeMids.removeAt(0)] = ssrc;
      } else {
        pendingSsrcs.add(ssrc);
        await pc.addTransceiver(kind: RTCRtpMediaType.RTCRtpMediaTypeAudio, init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly));
      }
    }
    if (pendingSsrcs.isEmpty && mapEquals(before, _ssrcByMid)) return;
    final offer = await _localOffer();
    // New transceivers got their mids in the offer we just set.
    final newMids = offer.mids.where((mid) => mid != _sendMid && !_ssrcByMid.containsKey(mid)).toList();
    for (final ssrc in pendingSsrcs) {
      if (newMids.isEmpty) break;
      _ssrcByMid[newMids.removeAt(0)] = ssrc;
    }
    await pc.setRemoteDescription(RTCSessionDescription(_answer(offer.mids), 'answer'));
  }

  /// Reports who is speaking (from inbound audio levels) so TDLib can light up the participant list.
  Future<void> _pollLevels() async {
    final pc = _pc;
    if (pc == null) return;
    final speaking = <int>{};
    var self = false;
    for (final report in await pc.getStats()) {
      final level = (report.values['audioLevel'] as num?)?.toDouble() ?? 0;
      if (report.type == 'inbound-rtp' && level > 0.03) speaking.add(signedSsrc((report.values['ssrc'] as num).toInt()));
      if (report.type == 'media-source' && level > 0.03) self = !muted;
    }
    for (final ssrc in speaking.difference(_speaking)) {
      unawaited(_setSpeaking(ssrc, true));
    }
    for (final ssrc in _speaking.difference(speaking)) {
      unawaited(_setSpeaking(ssrc, false));
    }
    if (self != _selfSpeaking) unawaited(_setSpeaking(0, self));
    _speaking = speaking;
    _selfSpeaking = self;
  }

  Future<void> _setSpeaking(int ssrc, bool isSpeaking) async {
    try {
      await account.send<td.MessageSender>(td.SetGroupCallParticipantIsSpeaking(groupCallId: id, audioSource: ssrc, isSpeaking: isSpeaking));
    } on TdException {
      // The participant may have left meanwhile.
    }
  }

  /// Unmutes/mutes the microphone; when an admin muted us, raises the hand instead.
  Future<void> toggleMute() async {
    final self = me;
    if (self == null) return;
    if (muted && !self.canUnmuteSelf) {
      await account.send<td.Ok>(td.ToggleGroupCallParticipantIsHandRaised(groupCallId: id, participantId: self.participantId, isHandRaised: !self.isHandRaised));
      return;
    }
    muted = !muted;
    for (final track in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
    _notify();
    await account.send<td.Ok>(td.ToggleGroupCallParticipantIsMuted(groupCallId: id, participantId: self.participantId, isMuted: muted));
  }

  Future<void> toggleSpeaker() async {
    speaker = !speaker;
    await Helper.setSpeakerphoneOn(speaker);
    _notify();
  }

  Future<void> leave() async {
    if (joined) {
      try {
        await account.send<td.Ok>(td.LeaveGroupCall(groupCallId: id));
      } on TdException catch (e) {
        debugPrint('leave group call: ${e.message}');
      }
    }
    await _close();
  }

  /// Ends the video chat for everyone (admins, [td.GroupCall.canBeManaged]).
  Future<void> endForAll() async {
    await account.send<td.Ok>(td.EndGroupCall(groupCallId: id));
    await _close();
  }

  Future<void> _rejoin() async {
    await _teardown();
    joined = false;
    participants.clear();
    _ssrcByMid.clear();
    await join();
  }

  Future<void> _teardown() async {
    _levelTimer?.cancel();
    for (final track in _local?.getTracks() ?? const <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _local?.dispose();
    await _pc?.close();
    _local = null;
    _pc = null;
  }

  Future<void> _close() async {
    if (ended) return;
    ended = true;
    joined = false;
    await _teardown();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_close());
    super.dispose();
  }
}
