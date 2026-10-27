import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../state/telegram.dart';
import '../tdlib/td_client.dart';
import 'signaling_crypto.dart';

/// What every UZARO call offers Telegram: tgcalls' WebRTC "reference" protocol, signaling v1.
/// Telegram Desktop and Android register that implementation, so they pick it when we offer only it.
const callProtocol = td.CallProtocol(udpP2p: true, udpReflector: true, minLayer: 65, maxLayer: 92, libraryVersions: ['10.0.0']);

enum CallPhase { ringing, connecting, active, ended }

/// One Telegram voice/video call: TDLib call state + a WebRTC peer connection whose
/// offer/answer/candidates travel encrypted over TDLib call signaling.
class CallSession extends ChangeNotifier {
  CallSession(this.account, this.call);

  final TelegramAccount account;
  td.Call call;

  CallPhase phase = CallPhase.ringing;
  List<String> emojis = const [];
  bool muted = false;
  bool speaker = false;
  bool videoOn = false;
  bool remoteMuted = false;
  bool remoteVideo = false;
  DateTime? startedAt;
  td.CallDiscardReason? endReason;

  /// Set when the call failed (callStateError), e.g. USER_PRIVACY_RESTRICTED.
  td.TdError? error;

  /// Telegram asks for a 1-5 star rating after some calls.
  bool needRating = false;

  Future<void> rate(int stars) => account.send<td.Ok>(td.SendCallRating(callId: td.InputCallDiscarded(callId: call.id), rating: stars, comment: null, problems: const []));

  final localRenderer = RTCVideoRenderer();
  final remoteRenderer = RTCVideoRenderer();

  RTCPeerConnection? _pc;
  RTCDataChannel? _data;
  MediaStream? _local;
  SignalingCrypto? _crypto;
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteSet = false;
  bool _makingOffer = false;
  bool _started = false;
  final Map<int, Timer> _serviceTimers = {};
  bool _disposed = false;

  bool get isOutgoing => call.isOutgoing;
  Duration get duration => startedAt == null ? Duration.zero : DateTime.now().difference(startedAt!);

  Future<void> init() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    videoOn = call.isVideo;
  }

  /// Applies an updateCall from TDLib.
  Future<void> onCallUpdate(td.Call updated) async {
    call = updated;
    switch (updated.state) {
      case td.CallStatePending():
      case td.CallStateExchangingKeys():
        phase = isOutgoing ? CallPhase.ringing : phase;
        if (updated.state is td.CallStateExchangingKeys) phase = CallPhase.connecting;
      case final td.CallStateReady ready:
        emojis = ready.emojis;
        phase = CallPhase.connecting;
        if (!_started) {
          _started = true;
          await _start(ready);
        }
      case td.CallStateHangingUp():
        break;
      case td.CallStateDiscarded(:final reason, :final needRating):
        endReason = reason;
        this.needRating = needRating;
        await _end();
      case td.CallStateError(:final error):
        debugPrint('call error: ${error.code} ${error.message}');
        this.error = error;
        await _end();
    }
    _notify();
  }

  /// Encrypted signaling bytes from the peer (updateNewCallSignalingData).
  Future<void> onSignalingData(String base64Data) async {
    final crypto = _crypto;
    if (crypto == null) return;
    for (final message in crypto.handleIncoming(base64Decode(base64Data))) {
      await _onSignalingMessage(message);
    }
  }

  Future<void> accept() => account.send<td.Ok>(td.AcceptCall(callId: call.id, protocol: callProtocol));

  Future<void> hangUp() async {
    final seconds = duration.inSeconds;
    try {
      await account.send<td.Ok>(td.DiscardCall(
        callId: call.id,
        isDisconnected: false,
        inviteLink: '',
        duration: seconds,
        isVideo: videoOn || remoteVideo,
        connectionId: 0,
      ));
    } on TdException catch (error) {
      debugPrint('discard call failed: $error');
    }
    await _end();
    _notify();
  }

  void toggleMute() {
    muted = !muted;
    for (final track in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
    _sendMediaState();
    _notify();
  }

  Future<void> toggleSpeaker() async {
    speaker = !speaker;
    await Helper.setSpeakerphoneOn(speaker);
    _notify();
  }

  Future<void> toggleVideo() async {
    final pc = _pc;
    if (pc == null) return;
    if (videoOn) {
      for (final track in _local?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
        track.enabled = false;
        await track.stop();
        await _local?.removeTrack(track);
      }
      for (final sender in await pc.getSenders()) {
        if (sender.track?.kind == 'video') await pc.removeTrack(sender);
      }
      localRenderer.srcObject = null;
      videoOn = false;
    } else {
      final camera = await navigator.mediaDevices.getUserMedia({'audio': false, 'video': {'facingMode': 'user'}});
      final track = camera.getVideoTracks().first;
      await _local?.addTrack(track);
      await pc.addTrack(track, _local!);
      localRenderer.srcObject = _local;
      videoOn = true;
      // Adding a track needs a new offer/answer round; onRenegotiationNeeded drives it.
    }
    _sendMediaState();
    _notify();
  }

  Future<void> switchCamera() async {
    final tracks = _local?.getVideoTracks() ?? const <MediaStreamTrack>[];
    if (tracks.isNotEmpty) await Helper.switchCamera(tracks.first);
  }

  // ------------------------------------------------------------------ WebRTC

  Future<void> _start(td.CallStateReady ready) async {
    _crypto = SignalingCrypto(
      key: Uint8List.fromList(base64Decode(ready.encryptionKey)),
      isOutgoing: isOutgoing,
      requestService: _scheduleService,
    );
    final servers = <Map<String, dynamic>>[];
    for (final server in ready.servers) {
      if (server.type case td.CallServerTypeWebrtc(:final username, :final password, :final supportsTurn, :final supportsStun)) {
        for (final host in [server.ipAddress, if (server.ipv6Address.isNotEmpty) '[${server.ipv6Address}]']) {
          if (host.isEmpty) continue;
          if (supportsTurn && username.isNotEmpty) servers.add({'urls': 'turn:$host:${server.port}', 'username': username, 'credential': password});
          if (supportsStun) servers.add({'urls': 'stun:$host:${server.port}'});
        }
      }
      // shortcut: Telegram reflector servers need tgcalls' custom relay port; skipped until a native build exists.
    }
    final pc = await createPeerConnection({
      'iceServers': servers,
      'iceTransportPolicy': ready.allowP2p ? 'all' : 'relay',
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
      'continualGatheringPolicy': 'gather_continually',
    });
    _pc = pc;
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      _sendJson({'@type': 'candidate', 'sdp': candidate.candidate, 'mid': candidate.sdpMid ?? '0', 'mline': candidate.sdpMLineIndex ?? 0});
    };
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) remoteRenderer.srcObject = event.streams.first;
      if (event.track.kind == 'video') remoteVideo = true;
      _notify();
    };
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected && phase != CallPhase.active) {
        phase = CallPhase.active;
        startedAt ??= DateTime.now();
        _sendMediaState();
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        unawaited(pc.restartIce());
      }
      _notify();
    };
    pc.onRenegotiationNeeded = () {
      // Same rule as tgcalls: renegotiate only from a settled state; the callee never before the first offer.
      if (_makingOffer || pc.signalingState != RTCSignalingState.RTCSignalingStateStable) return;
      if (!isOutgoing && !_remoteSet) return;
      unawaited(_sendOffer());
    };
    pc.onDataChannel = _attachData;

    _local = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
      'video': call.isVideo ? {'facingMode': 'user'} : false,
    });
    for (final track in _local!.getTracks()) {
      await pc.addTrack(track, _local!);
    }
    if (call.isVideo) localRenderer.srcObject = _local;
    await Helper.setSpeakerphoneOn(call.isVideo);
    speaker = call.isVideo;

    if (isOutgoing) {
      _attachData(await pc.createDataChannel('data', RTCDataChannelInit()));
      await _sendOffer();
    }
  }

  Future<void> _sendOffer() async {
    final pc = _pc;
    if (pc == null) return;
    _makingOffer = true;
    try {
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      _sendJson({'@type': offer.type, 'sdp': offer.sdp});
    } finally {
      _makingOffer = false;
    }
  }

  Future<void> _onSignalingMessage(Uint8List data) async {
    final pc = _pc;
    if (pc == null) return;
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(data));
    } on FormatException {
      return;
    }
    if (json is! Map<String, dynamic>) return;
    switch (json['@type']) {
      case final String type when type == 'offer' || type == 'answer':
        final collision = type == 'offer' && (_makingOffer || pc.signalingState != RTCSignalingState.RTCSignalingStateStable);
        // The callee is the "impolite" side in tgcalls: on a collision the caller's offer wins.
        if (collision && isOutgoing) return;
        await pc.setRemoteDescription(RTCSessionDescription(json['sdp'] as String?, type));
        _remoteSet = true;
        for (final candidate in _pendingCandidates) {
          await pc.addCandidate(candidate);
        }
        _pendingCandidates.clear();
        if (type == 'offer') {
          final answer = await pc.createAnswer();
          await pc.setLocalDescription(answer);
          _sendJson({'@type': answer.type, 'sdp': answer.sdp});
        }
      case 'candidate':
        final candidate = RTCIceCandidate(json['sdp'] as String?, json['mid'] as String?, (json['mline'] as num?)?.toInt());
        if (_remoteSet) {
          await pc.addCandidate(candidate);
        } else {
          _pendingCandidates.add(candidate);
        }
      case 'MediaState':
        _onMediaState(json);
    }
  }

  void _attachData(RTCDataChannel channel) {
    _data = channel;
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) _sendMediaState();
    };
    channel.onMessage = (message) {
      if (message.isBinary) return;
      final Object? json;
      try {
        json = jsonDecode(message.text);
      } on FormatException {
        return;
      }
      if (json is Map<String, dynamic> && json['@type'] == 'MediaState') _onMediaState(json);
    };
  }

  void _onMediaState(Map<String, dynamic> json) {
    remoteMuted = json['muted'] == true;
    final video = json['videoState'];
    final screencast = json['screencastState'];
    remoteVideo = video == 'active' || screencast == 'active';
    _notify();
  }

  void _sendMediaState() {
    final channel = _data;
    if (channel == null || channel.state != RTCDataChannelState.RTCDataChannelOpen) return;
    channel.send(RTCDataChannelMessage(jsonEncode({
      '@type': 'MediaState',
      'muted': muted,
      'lowBattery': false,
      'videoState': videoOn ? 'active' : 'inactive',
      'videoRotation': 0,
      'screencastState': 'inactive',
    })));
  }

  void _sendJson(Map<String, Object?> message) {
    final packet = _crypto?.prepareMessage(Uint8List.fromList(utf8.encode(jsonEncode(message))));
    if (packet != null) _sendPacket(packet);
  }

  void _sendPacket(Uint8List packet) {
    if (_disposed) return;
    unawaited(account
        .send<td.Ok>(td.SendCallSignalingData(callId: call.id, data: base64Encode(packet)))
        .then((_) {}, onError: (Object error) => debugPrint('call signaling send failed: $error')));
  }

  void _scheduleService(int delayMs, int cause) {
    _serviceTimers.remove(cause)?.cancel();
    _serviceTimers[cause] = Timer(Duration(milliseconds: delayMs), () {
      _serviceTimers.remove(cause);
      final packet = _crypto?.prepareService(cause);
      if (packet != null) _sendPacket(packet);
    });
  }

  Future<void> _end() async {
    if (phase == CallPhase.ended) return;
    phase = CallPhase.ended;
    for (final timer in _serviceTimers.values) {
      timer.cancel();
    }
    _serviceTimers.clear();
    for (final track in _local?.getTracks() ?? const <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _local?.dispose();
    await _data?.close();
    await _pc?.close();
    _local = null;
    _pc = null;
    _data = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    // TDLib can repeat the final call state, so closing may be requested more than once.
    if (_disposed) return;
    _disposed = true;
    unawaited(_end());
    unawaited(localRenderer.dispose());
    unawaited(remoteRenderer.dispose());
    super.dispose();
  }
}
