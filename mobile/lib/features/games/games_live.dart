import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/sado_api.dart';
import '../../core/config.dart';
import 'games_models.dart';

final gamesLiveProvider = Provider<GamesLive>((ref) {
  final live = GamesLive(ref.read(sadoApiProvider));
  ref.onDispose(live.close);
  return live;
});

/// The live games socket (/v1/games/ws): open while any games screen holds it ([hold]/[release]), reconnects
/// with back-off, and re-opens the games being watched so their state is fresh after a drop.
class GamesLive {
  GamesLive(this._api);

  static const _pingEvery = Duration(seconds: 25);
  static const _maxBackoff = Duration(seconds: 20);

  final SadoApi _api;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final connected = ValueNotifier<bool>(false);
  final games = <String, LiveGame>{};
  /// Games that have a screen open (or one being pushed), so a new-game event opens exactly one screen.
  final open = <String>{};
  final _watching = <String>{};
  WebSocket? _socket;
  Timer? _ping;
  Timer? _retry;
  int _holders = 0;
  int _failures = 0;
  bool _connecting = false;
  DateTime _lastHeard = DateTime.now();

  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Every screen that needs the socket holds it while it is open.
  void hold() {
    _holders++;
    unawaited(_connect());
  }

  void release() {
    _holders = _holders > 0 ? _holders - 1 : 0;
    if (_holders == 0) {
      _watching.clear();
      _drop();
    }
  }

  void watch(String gameId) {
    _watching.add(gameId);
    send({'t': 'open', 'game': gameId});
  }

  void unwatch(String gameId) => _watching.remove(gameId);

  /// Sends [message] when connected; returns false (and the caller shows "no connection") otherwise.
  bool send(Map<String, dynamic> message) {
    final socket = _socket;
    if (socket == null || !connected.value) return false;
    try {
      socket.add(jsonEncode(message));
    } on StateError {
      return false; // closed by the other side a moment ago; onDone reconnects
    }
    return true;
  }

  Uri get _url {
    final base = Uri.parse(AppConfig.apiUrl);
    return base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: '/v1/games/ws');
  }

  Future<void> _connect({bool renew = false}) async {
    if (_socket != null || _connecting || _holders == 0) return;
    _connecting = true;
    _retry?.cancel();
    try {
      final token = await _api.liveToken(renew: renew);
      final connecting = WebSocket.connect(_url.toString());
      final WebSocket socket;
      try {
        socket = await connecting.timeout(const Duration(seconds: 15));
      } on TimeoutException {
        // The connect may still finish later: close that socket so the server does not see a second player.
        unawaited(connecting.then((late) => late.close(), onError: (Object _) => null));
        rethrow;
      }
      if (_holders == 0) {
        await socket.close();
        return;
      }
      _socket = socket;
      socket.add(jsonEncode({'t': 'auth', 'token': token}));
      socket.listen(_onData, onDone: () => _onClosed(socket), onError: (Object _) => _onClosed(socket), cancelOnError: true);
    } on Exception {
      _scheduleRetry();
    } finally {
      _connecting = false;
    }
  }

  void _onData(dynamic raw) {
    _lastHeard = DateTime.now();
    if (raw is! String) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    final message = decoded.cast<String, dynamic>();
    switch (message['t']) {
      case 'ready':
        _failures = 0;
        connected.value = true;
        _ping?.cancel();
        _ping = Timer.periodic(_pingEvery, (_) => _keepAlive());
        for (final id in _watching) {
          send({'t': 'open', 'game': id});
        }
      case 'game':
        try {
          final game = LiveGame.fromJson((message['game'] as Map).cast<String, dynamic>());
          games[game.id] = game;
        } on TypeError {
          return; // a malformed game event is dropped; the next one (or a re-open) brings the state back
        }
    }
    _events.add(message);
  }

  /// Pings, and drops a socket that has heard nothing (not even a pong) for two rounds: on a half-open mobile
  /// connection sends "succeed" into the void and no close ever comes.
  void _keepAlive() {
    final socket = _socket;
    if (socket == null) return;
    if (DateTime.now().difference(_lastHeard) > _pingEvery * 2 + const Duration(seconds: 5)) {
      unawaited(socket.close());
      _onClosed(socket);
      return;
    }
    send({'t': 'ping'});
  }

  void _onClosed(WebSocket socket) {
    if (_socket != socket) return;
    final refused = socket.closeCode == 4401;
    _socket = null;
    _ping?.cancel();
    connected.value = false;
    _events.add({'t': 'disconnected'});
    if (_holders == 0) return;
    if (refused && _failures == 0) {
      _failures++;
      unawaited(_connect(renew: true)); // the access token expired: one fresh token at once
      return;
    }
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_holders == 0) return;
    _failures++;
    final wait = Duration(seconds: (1 << (_failures.clamp(1, 5) - 1)));
    _retry?.cancel();
    _retry = Timer(wait > _maxBackoff ? _maxBackoff : wait, () => unawaited(_connect(renew: _failures > 2)));
  }

  void _drop() {
    _retry?.cancel();
    _ping?.cancel();
    final socket = _socket;
    _socket = null;
    connected.value = false;
    if (socket != null) unawaited(socket.close());
  }

  void close() {
    _holders = 0;
    _drop();
    unawaited(_events.close());
  }
}
