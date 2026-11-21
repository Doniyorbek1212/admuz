import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../core/tdlib/td_client.dart';
import 'telegram.dart';

/// Serves TDLib files to the video player over http://127.0.0.1 with HTTP Range support. Only the part the player
/// asks for is downloaded (a window ahead of the read position), so a two-hour film starts in seconds and seeking
/// jumps straight to the new position, as in Telegram's own apps.
class TdStreamServer {
  TdStreamServer._();

  static final TdStreamServer instance = TdStreamServer._();

  // Other apps on the phone can reach 127.0.0.1 too: every URL carries a per-launch secret.
  static final String _secret = List.generate(24, (_) => Random.secure().nextInt(36).toRadixString(36)).join();
  static const _readChunk = 256 * 1024;
  static const _window = 16 * 1024 * 1024;
  static const _stallTimeout = Duration(seconds: 60);

  HttpServer? _server;
  Future<HttpServer>? _binding;
  TelegramAccount? _account;

  /// URL the player can open for [fileId] of [account].
  Future<Uri> urlFor(TelegramAccount account, int fileId, {String extension = 'mp4'}) async {
    _account = account;
    final server = _server ?? await (_binding ??= _bind());
    return Uri.parse('http://127.0.0.1:${server.port}/$_secret/$fileId.$extension');
  }

  Future<HttpServer> _bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => unawaited(_handle(request)));
    return _server = server;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final segments = request.uri.pathSegments;
    final account = _account;
    final fileId = segments.length == 2 && segments[0] == _secret ? int.tryParse(segments[1].split('.').first) : null;
    if (account == null || fileId == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    RandomAccessFile? reader;
    try {
      var file = await account.send<td.File>(td.GetFile(fileId: fileId));
      final size = file.size != 0 ? file.size : file.expectedSize;
      final range = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
      final start = int.tryParse(range?.group(1) ?? '') ?? 0;
      final end = min(int.tryParse(range?.group(2) ?? '') ?? size - 1, size - 1);
      if (size <= 0 || start > end) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        await response.close();
        return;
      }
      response.statusCode = range == null ? HttpStatus.ok : HttpStatus.partialContent;
      response.headers
        ..contentType = ContentType('video', segments[1].split('.').last)
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..contentLength = end - start + 1;
      if (range != null) response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$size');
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      var position = start;
      var requestedUntil = -1;
      var lastProgress = DateTime.now();
      var lastRequest = DateTime(0);
      while (position <= end) {
        final ready = (await account.send<td.FileDownloadedPrefixSize>(td.GetFileDownloadedPrefixSize(fileId: fileId, offset: position))).size;
        // Keep a window downloaded ahead of the reader. TDLib has one download cursor per file, so another request
        // (the player probing elsewhere) can move it away: starved for a second, ask again.
        final starved = ready == 0 && DateTime.now().difference(lastRequest) > const Duration(seconds: 1);
        if (position + ready < size && (position + ready >= requestedUntil - _window ~/ 4 || starved)) {
          requestedUntil = position + ready + _window;
          lastRequest = DateTime.now();
          file = await account.send<td.File>(td.DownloadFile(fileId: fileId, priority: 32, offset: position + ready, limit: _window, synchronous: false));
        }
        if (ready == 0) {
          if (DateTime.now().difference(lastProgress) > _stallTimeout) throw TimeoutException('no data for $fileId at $position');
          await Future<void>.delayed(const Duration(milliseconds: 120));
          continue;
        }
        if (reader == null) {
          if (file.local.path.isEmpty) file = await account.send<td.File>(td.GetFile(fileId: fileId));
          reader = await File(file.local.path).open();
        }
        final count = min(min(ready, end - position + 1), _readChunk);
        await reader.setPosition(position);
        response.add(await reader.read(count));
        await response.flush();
        position += count;
        lastProgress = DateTime.now();
      }
      await response.close();
    } on TdException catch (error) {
      debugPrint('stream $fileId: $error');
      await _fail(response);
    } on IOException {
      // The player closed the connection (seek, pause, screen closed): expected.
    } on TimeoutException catch (error) {
      debugPrint('stream stalled: $error');
      await _fail(response);
    } finally {
      await reader?.close();
    }
  }

  static Future<void> _fail(HttpResponse response) async {
    try {
      await response.close();
    } on Object catch (_) {
      // Headers or the socket are already gone.
    }
  }
}
