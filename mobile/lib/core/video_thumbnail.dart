import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tdlib_ex/td_api.dart' as td;

const _channel = MethodChannel('uz.sado.app/privacy');

/// Cover for an outgoing video (first frame, at most 320px), made by Android; null elsewhere or when the
/// file cannot be read, and the video then goes out without one as before.
Future<td.InputThumbnail?> videoThumbnail(String path) async {
  if (defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    final thumb = await _channel.invokeMapMethod<String, Object?>('videoThumbnail', {'path': path});
    final file = thumb?['path'];
    if (thumb == null || file is! String) return null;
    return td.InputThumbnail(
      thumbnail: td.InputFileLocal(path: file),
      width: thumb['width'] as int? ?? 0,
      height: thumb['height'] as int? ?? 0,
    );
  } on PlatformException catch (error) {
    debugPrint('video thumbnail failed: $error');
    return null;
  } on MissingPluginException {
    return null;
  }
}
