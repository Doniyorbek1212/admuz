import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/api/movie_models.dart';
import '../../core/tdlib/td_client.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';

/// Films kept on the phone to watch without internet: [saved] video id -> its title, [active] download -> progress 0..1.
@immutable
class MovieDownloads {
  const MovieDownloads({this.saved = const {}, this.active = const {}});

  final Map<String, MovieTitle> saved;
  final Map<String, double> active;
}

final movieDownloadsProvider = NotifierProvider<MovieDownloadsNotifier, MovieDownloads>(MovieDownloadsNotifier.new);

/// Downloads a video through TDLib, then copies it into the app's own folder: TDLib's cache limits and
/// "clear cache" would otherwise delete a film the viewer saved for a trip.
class MovieDownloadsNotifier extends Notifier<MovieDownloads> {
  static const _prefsKey = 'movie.saved';
  static const _maxStalls = 5;

  final _fileIds = <String, int>{};
  final _cancelled = <String>{};

  @override
  MovieDownloads build() {
    final raw = ref.read(sharedPreferencesProvider).getString(_prefsKey);
    if (raw == null) return const MovieDownloads();
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return MovieDownloads(saved: {for (final e in map.entries) e.key: MovieTitle.fromJson(e.value as Map<String, dynamic>)});
    } on FormatException catch (error) {
      debugPrint('saved movies unreadable: $error');
      return const MovieDownloads();
    }
  }

  bool isDownloading(String videoId) => state.active.containsKey(videoId);

  /// The offline copy of [videoId], or null when it is not on the phone.
  Future<File?> savedFile(String videoId) async {
    if (!state.saved.containsKey(videoId)) return null;
    final file = await _fileFor(videoId);
    if (await file.exists()) return file;
    _setSaved({...state.saved}..remove(videoId)); // deleted from outside the app
    return null;
  }

  /// False when the download failed; true once [video] is saved or the viewer cancelled it.
  Future<bool> download(MovieTitle title, MovieVideo video) async {
    if (isDownloading(video.id) || state.saved.containsKey(video.id)) return true;
    _cancelled.remove(video.id);
    _setActive(video.id, 0);
    final account = ref.read(accountProvider);
    StreamSubscription<td.File>? progress;
    try {
      final info = await account.send<td.MessageLinkInfo>(td.GetMessageLinkInfo(url: video.link));
      final content = info.message?.content;
      if (content is! td.MessageVideo) return false;
      final fileId = _fileIds[video.id] = content.video.video.id;
      progress = account.fileUpdates(fileId).listen((f) {
        final size = f.size != 0 ? f.size : f.expectedSize;
        if (size > 0 && isDownloading(video.id)) _setActive(video.id, f.local.downloadedSize / size);
      });
      final path = await _downloadAll(fileId, video.id);
      if (path == null) return _cancelled.contains(video.id);
      final target = await _fileFor(video.id);
      await target.parent.create(recursive: true);
      // Copy to .part first: a crash mid-copy must not leave a cut film that looks saved.
      final part = await File(path).copy('${target.path}.part');
      await part.rename(target.path);
      unawaited(account.send<td.Ok>(td.DeleteFile(fileId: fileId)).catchError((Object _) => const td.Ok())); // free the cache copy
      _setSaved({...state.saved, video.id: _onlyVideo(title, video)});
      return true;
    } on TdException catch (error) {
      debugPrint('movie download failed: $error');
      return false;
    } on FileSystemException catch (error) {
      debugPrint('movie save failed: $error');
      return false;
    } finally {
      await progress?.cancel();
      _fileIds.remove(video.id);
      _setActive(video.id, null);
    }
  }

  /// TDLib ends a synchronous download early when the player streams the same file (it moves the download
  /// cursor), so ask again until done; give up after [_maxStalls] tries without progress.
  Future<String?> _downloadAll(int fileId, String videoId) async {
    final account = ref.read(accountProvider);
    var stalls = 0;
    var last = -1;
    while (!_cancelled.contains(videoId)) {
      final path = await account.downloadFile(fileId, priority: 1);
      if (path != null && path.isNotEmpty) return path;
      if (_cancelled.contains(videoId)) break;
      final done = (await account.send<td.File>(td.GetFile(fileId: fileId))).local.downloadedSize;
      stalls = done > last ? 0 : stalls + 1;
      last = done;
      if (stalls >= _maxStalls) return null;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return null;
  }

  void cancel(String videoId) {
    _cancelled.add(videoId);
    if (_fileIds[videoId] case final id?) ref.read(accountProvider).cancelDownload(id);
  }

  Future<void> delete(String videoId) async {
    final file = await _fileFor(videoId);
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (error) {
      debugPrint('movie delete failed: $error');
    }
    _setSaved({...state.saved}..remove(videoId));
  }

  /// The title with just [video], so the offline list and "next episode" only offer what is on the phone.
  static MovieTitle _onlyVideo(MovieTitle t, MovieVideo video) => MovieTitle(
        id: t.id,
        isSeries: t.isSeries,
        title: t.title,
        description: t.description,
        year: t.year,
        categories: t.categories,
        country: t.country,
        language: t.language,
        posterUrl: t.posterUrl,
        videos: [video],
      );

  static Future<File> _fileFor(String videoId) async {
    final dir = await getApplicationSupportDirectory();
    // The id comes from the server: keep it from naming a path outside the folder.
    final name = videoId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File('${dir.path}${Platform.pathSeparator}movies${Platform.pathSeparator}$name.mp4');
  }

  void _setActive(String videoId, double? progress) =>
      state = MovieDownloads(saved: state.saved, active: {...state.active}..remove(videoId)..addAll({videoId: ?progress}));

  void _setSaved(Map<String, MovieTitle> saved) {
    state = MovieDownloads(saved: saved, active: state.active);
    unawaited(ref.read(sharedPreferencesProvider).setString(_prefsKey, jsonEncode({for (final e in saved.entries) e.key: e.value.toJson()})));
  }
}
