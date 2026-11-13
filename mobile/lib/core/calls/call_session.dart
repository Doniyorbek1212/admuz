import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path_provider/path_provider.dart';
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
  Future<MediaStream>? _opening;
  bool _cameraPaused = false;
  SignalingCrypto? _crypto;
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteSet = false;
  bool _makingOffer = false;
  bool _started = false;
  final Map<int, Timer> _serviceTimers = {};
  bool _disposed = false;

  /// Call diagnostics for Telegram when it asks for them after the call (needDebugInformation / needLog).
  final List<String> _log = [];
  Map<String, Object?> _lastStats = const {};

  bool get isOutgoing => call.isOutgoing;
  Duration get duration => startedAt == null ? Duration.zero : DateTime.now().difference(startedAt!);

  Future<void> init() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    videoOn = call.isVideo;
    // The caller sees their own camera while it rings, like Telegram; the callee opens media on answer.
    if (isOutgoing) {
      unawaited(_openLocal().then<void>((_) => _notify()).catchError((Object error) => debugPrint('call media not opened: $error')));
    }
  }

  /// Microphone, plus the camera when video is on; one stream however many callers ask at once.
  Future<MediaStream> _openLocal() => _opening ??= _open().catchError((Object error) {
        _opening = null;
        throw error;
      });

  Future<MediaStream> _open() async {
    const audio = {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true};
    MediaStream stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({'audio': audio, 'video': videoOn ? {'facingMode': 'user'} : false});
    } on Exception catch (error) {
      // Camera denied or busy: the call goes on as voice instead of failing.
      if (!videoOn) rethrow;
      debugPrint('camera unavailable: $error');
      videoOn = false;
      stream = await navigator.mediaDevices.getUserMedia({'audio': audio, 'video': false});
    }
    if (phase == CallPhase.ended) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
      throw StateError('call ended while opening media');
    }
    _local = stream;
    if (videoOn) localRenderer.srcObject = stream;
    return stream;
  }

  /// Applies an updateCall from TDLib.
  Future<void> onCallUpdate(td.Call updated) async {
    call = updated;
    _trace('state ${updated.state.runtimeType}');
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
      case td.CallStateDiscarded(:final reason, :final needRating, :final needDebugInformation, :final needLog):
        endReason = reason;
        this.needRating = needRating;
        _trace('discarded ${reason.runtimeType}');
        await _end();
        if (needDebugInformation) unawaited(_sendDebugInformation());
        if (needLog) unawaited(_sendLog());
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

  Future<void> toggleMute() async {
    muted = !muted;
    _notify();
    for (final track in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !muted;
      // Some Android builds keep sending a disabled track's audio; the native mute stops the capture itself.
      try {
        await Helper.setMicrophoneMute(muted, track);
      } on Object catch (error) {
        debugPrint('native mute failed: $error');
      }
    }
    _sendMediaState();
  }

  /// Like Telegram: the camera pauses while the call is a floating window or the app is in the background
  /// (MIUI blacks out a background camera anyway), and resumes on return.
  void setCameraPaused(bool paused) {
    if (!videoOn) return;
    for (final track in _local?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !paused;
    }
    _cameraPaused = paused;
    _sendMediaState();
  }

  Future<void> toggleSpeaker() async {
    speaker = !speaker;
    await Helper.setSpeakerphoneOn(speaker);
    _notify();
  }

  /// Works in every phase: before the peer connection exists only the local stream changes, and
  /// [_start] sends whatever it holds.
  Future<void> toggleVideo() async {
    final pc = _pc;
    if (videoOn) {
      videoOn = false;
      localRenderer.srcObject = null;
      _notify();
      // Senders and the stream let go of the track first: a stopped track is already gone natively.
      for (final sender in pc == null ? const <RTCRtpSender>[] : await pc.getSenders()) {
        if (sender.track?.kind == 'video') await pc!.removeTrack(sender);
      }
      for (final track in _local?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
        try {
          await _local?.removeTrack(track);
          await track.stop();
        } on PlatformException catch (error) {
          debugPrint('camera track not released: $error');
        }
      }
    } else {
      final local = _opening == null ? null : await _openLocal();
      if (local == null) {
        // Media is not open yet (an unanswered incoming call): the camera opens with it.
        videoOn = true;
        _notify();
        return;
      }
      final MediaStream camera;
      try {
        camera = await navigator.mediaDevices.getUserMedia({'audio': false, 'video': {'facingMode': 'user'}});
      } on Exception catch (error) {
        debugPrint('camera unavailable: $error');
        return;
      }
      final track = camera.getVideoTracks().first;
      await local.addTrack(track);
      // Adding a track needs a new offer/answer round; onRenegotiationNeeded drives it.
      if (pc != null) await pc.addTrack(track, local);
      localRenderer.srcObject = local;
      videoOn = true;
      _cameraPaused = false;
    }
    _sendMediaState();
    _notify();
  }

  Future<void> switchCamera() async {
    final tracks = _local?.getVideoTracks() ?? const <MediaStreamTrack>[];
    if (tracks.isEmpty) return;
    try {
      await Helper.switchCamera(tracks.first);
    } on PlatformException catch (error) {
      // A phone with a single camera, or one another app holds.
      debugPrint('camera switch failed: $error');
    }
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

    final local = await _openLocal();
    for (final track in local.getTracks()) {
      await pc.addTrack(track, local);
    }
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
      'videoState': !videoOn ? 'inactive' : (_cameraPaused ? 'paused' : 'active'),
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
    await _snapshotStats();
    for (final track in _local?.getTracks() ?? const <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _local?.dispose();
    await _data?.close();
    await _pc?.close();
    _local = null;
    _opening = null;
    _pc = null;
    _data = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _trace(String event) {
    _log.add('${DateTime.now().toIso8601String()} $event');
    if (_log.length > 500) _log.removeAt(0);
  }

  /// Last WebRTC stats before the connection closes: transport, candidate pair and RTP counters.
  Future<void> _snapshotStats() async {
    final pc = _pc;
    if (pc == null) return;
    try {
      final reports = await pc.getStats();
      const kept = {'transport', 'candidate-pair', 'inbound-rtp', 'outbound-rtp', 'remote-inbound-rtp'};
      _lastStats = {
        for (final report in reports)
          if (kept.contains(report.type)) '${report.type}:${report.id}': report.values,
      };
    } on Object catch (error) {
      _trace('stats failed: $error');
    }
  }

  Future<void> _sendDebugInformation() async {
    final info = jsonEncode({
      'library': callProtocol.libraryVersions.first,
      'duration': duration.inSeconds,
      'video': videoOn || remoteVideo,
      'stats': _lastStats,
    });
    try {
      await account.send<td.Ok>(td.SendCallDebugInformation(callId: td.InputCallDiscarded(callId: call.id), debugInformation: info));
    } on TdException catch (error) {
      debugPrint('call debug info not sent: $error');
    }
  }

  Future<void> _sendLog() async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}call_${call.id}.log');
      await file.writeAsString(_log.join('\n'));
      await account.send<td.Ok>(td.SendCallLog(callId: td.InputCallDiscarded(callId: call.id), logFile: td.InputFileLocal(path: file.path)));
    } on Object catch (error) {
      debugPrint('call log not sent: $error');
    }
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
