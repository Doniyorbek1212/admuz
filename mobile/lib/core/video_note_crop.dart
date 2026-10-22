import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Side of the square round-video messages are encoded at (Telegram allows up to 640).
const videoNoteSize = 480;

const _channel = MethodChannel('uz.sado.app/video');

/// Center-crops a recorded clip to a [videoNoteSize] square (VideoNoteTranscoder.kt): Telegram turns
/// non-square video notes into ordinary videos. Returns the new file, or null where unsupported or failed.
Future<String?> cropVideoNoteSquare(String input) async {
  if (!Platform.isAndroid) return null;
  final output = '${input.replaceFirst(RegExp(r'\.\w+$'), '')}_square.mp4';
  try {
    return await _channel.invokeMethod<String>('cropSquare', {'input': input, 'output': output, 'size': videoNoteSize});
  } on PlatformException catch (error) {
    debugPrint('video note crop failed: $error');
    return null;
  }
}
