import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../core/tdlib/td_client.dart';
import 'actions.dart';
import 'telegram.dart';

/// What the shared player has loaded; drives the mini player and the media notification.
@immutable
class NowPlaying {
  const NowPlaying({required this.message, required this.fileId, required this.title, this.performer = '', this.artPath});

  final td.Message message;
  final int fileId;
  final String title;
  final String performer;
  final String? artPath;

  bool get isMusic => message.content is td.MessageAudio;

  NowPlaying withArt(String path) => NowPlaying(message: message, fileId: fileId, title: title, performer: performer, artPath: path);
}

/// Single shared player for voice notes and music, so starting one stops the other.
/// Like Telegram, it keeps playing in the background with notification / lock-screen
/// controls (Android, see MusicService.kt) and moves on to the chat's next track or voice note.
class Playback {
  Playback._() {
    player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) unawaited(_onCompleted());
    });
    if (_systemControls) {
      _channel.setMethodCallHandler(_onSystemControl);
      nowPlaying.addListener(_pushSystemState);
      player.playbackEventStream.listen((_) => _pushSystemState(), onError: (Object _) {});
      player.playingStream.listen((_) => _pushSystemState());
    }
  }

  static final Playback instance = Playback._();
  static const _channel = MethodChannel('uz.sado.app/music');
  static final _systemControls = !kIsWeb && Platform.isAndroid;

  final AudioPlayer player = AudioPlayer();
  final ValueNotifier<NowPlaying?> nowPlaying = ValueNotifier(null);
  final ValueNotifier<double> speed = ValueNotifier(1.0);
  TelegramAccount? _account;

  bool get isPlaying => player.playing && player.processingState != ProcessingState.completed;

  Future<void> cycleSpeed() async {
    const speeds = [1.0, 1.5, 2.0];
    speed.value = speeds[(speeds.indexOf(speed.value) + 1) % speeds.length];
    await player.setSpeed(speed.value);
  }

  /// Plays the voice note or music of [message] (downloading it first), or pauses/resumes it when already loaded.
  /// [title] names a voice note in the notification; music uses its own tags.
  Future<void> playMessage(TelegramAccount account, td.Message message, {String title = ''}) async {
    final file = _fileOf(message);
    if (file == null) return;
    if (nowPlaying.value?.fileId == file.id) return togglePlay();
    _account = account;
    final path = await _download(account, message, file.id);
    if (path != null) await _load(message, file.id, path, title);
  }

  Future<void> togglePlay() async {
    if (isPlaying) {
      await player.pause();
    } else {
      // play() completes only when playback stops, so it is not awaited.
      unawaited(player.play());
    }
  }

  Future<void> stop() async {
    nowPlaying.value = null;
    await player.stop();
    if (_systemControls) _invoke('stop');
  }

  Future<void> skipToNext() => _skip(newer: true);

  /// Restarts the track when past its first seconds, like Telegram; otherwise goes to the previous one.
  Future<void> skipToPrevious() async {
    if (player.position < const Duration(seconds: 3) && await _skip(newer: false)) return;
    await player.seek(Duration.zero);
  }

  static td.File? _fileOf(td.Message message) => switch (message.content) {
        td.MessageAudio(:final audio) => audio.audio,
        td.MessageVoiceNote(:final voiceNote) => voiceNote.voice,
        _ => null,
      };

  Future<String?> _download(TelegramAccount account, td.Message message, int fileId) async {
    if (message.content is td.MessageAudio && account.files[fileId]?.local.isDownloadingCompleted != true) {
      // Registered in TDLib's download list so it appears (and can be paused) in Downloads.
      await account.addToDownloads(message, fileId, priority: 32).catchError((Object _) {});
    }
    return account.downloadFile(fileId, priority: 32);
  }

  Future<void> _load(td.Message message, int fileId, String path, String title) async {
    final content = message.content;
    nowPlaying.value = switch (content) {
      td.MessageAudio(:final audio) => NowPlaying(
          message: message,
          fileId: fileId,
          title: audio.title.isEmpty ? audio.fileName : audio.title,
          performer: audio.performer,
        ),
      _ => NowPlaying(message: message, fileId: fileId, title: title),
    };
    try {
      await player.setFilePath(path);
    } on PlayerInterruptedException {
      return; // Another track was picked while this one loaded.
    } on PlayerException catch (error) {
      debugPrint('playback failed: $error');
      await stop();
      return;
    }
    unawaited(player.play());
    if (content is td.MessageAudio) unawaited(_loadCover(content.audio, fileId));
  }

  Future<void> _loadCover(td.Audio audio, int fileId) async {
    final thumbnail = audio.albumCoverThumbnail;
    final account = _account;
    if (thumbnail == null || account == null) return;
    final path = await account.downloadFile(thumbnail.file.id, priority: 1);
    final current = nowPlaying.value;
    if (path != null && current != null && current.fileId == fileId) nowPlaying.value = current.withArt(path);
  }

  /// Loads the neighbouring message of the same kind (music or voice) in the chat; false when there is none.
  Future<bool> _skip({required bool newer}) async {
    final current = nowPlaying.value;
    final account = _account;
    if (current == null || account == null) return false;
    final id = current.message.id;
    try {
      // A window around the current track; neighbours are picked by id, so the window's exact edges don't matter.
      final found = await account.send<td.FoundChatMessages>(td.SearchChatMessages(
        chatId: current.message.chatId,
        query: '',
        fromMessageId: id,
        offset: -2,
        limit: 4,
        filter: current.isMusic ? const td.SearchMessagesFilterAudio() : const td.SearchMessagesFilterVoiceNote(),
      ));
      final next = pickNeighbor(found.messages, id, newer: newer);
      final file = next == null ? null : _fileOf(next);
      if (next == null || file == null) return false;
      final path = await _download(account, next, file.id);
      // The user may have picked another track while this one downloaded.
      if (path == null || nowPlaying.value != current) return false;
      // Voice notes keep the caller's localized title.
      await _load(next, file.id, path, current.title);
      return true;
    } on TdException catch (error) {
      debugPrint('track switch failed: $error');
      return false;
    }
  }

  Future<void> _onCompleted() async {
    // Music listened to the end counts for the track (Telegram uses it for profile audio statistics).
    final playing = nowPlaying.value;
    if (playing != null && playing.message.content is td.MessageAudio) {
      unawaited(_account
          ?.send<td.Ok>(td.ListenToAudio(audioFileId: playing.fileId, duration: player.duration?.inSeconds ?? 0))
          .catchError((Object _) => const td.Ok()));
    }
    if (await _skip(newer: true)) return;
    await player.pause();
    await player.seek(Duration.zero);
  }

  Future<void> _onSystemControl(MethodCall call) async {
    switch (call.method) {
      case 'play':
        unawaited(player.play());
      case 'pause':
        await player.pause();
      case 'next':
        await skipToNext();
      case 'previous':
        await skipToPrevious();
      case 'seek':
        await player.seek(Duration(milliseconds: call.arguments as int));
      case 'stop':
        await stop();
    }
  }

  void _pushSystemState() {
    final now = nowPlaying.value;
    if (now == null) return; // stop() already removed the notification.
    _invoke('update', {
      'title': now.title,
      'artist': now.performer,
      'artPath': now.artPath,
      'playing': isPlaying,
      'position': player.position.inMilliseconds,
      'duration': player.duration?.inMilliseconds ?? 0,
      'speed': player.speed,
    });
  }

  void _invoke(String method, [Object? arguments]) {
    unawaited(_channel.invokeMethod<void>(method, arguments).catchError((Object error) => debugPrint('music controls: $error')));
  }
}

/// The closest message after (or before) [currentId] among [messages], in chat order.
@visibleForTesting
td.Message? pickNeighbor(List<td.Message> messages, int currentId, {required bool newer}) {
  td.Message? best;
  for (final message in messages) {
    final beyond = newer ? message.id > currentId : message.id < currentId;
    if (beyond && (best == null || (newer ? message.id < best.id : message.id > best.id))) best = message;
  }
  return best;
}
