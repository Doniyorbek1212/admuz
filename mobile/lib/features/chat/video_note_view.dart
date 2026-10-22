import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:video_player/video_player.dart';

import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';

/// Round video message as in Telegram/aka: downloads by itself and loops silently in the chat;
/// a tap plays it from the start with sound and a progress ring, another tap pauses.
class VideoNoteView extends ConsumerStatefulWidget {
  const VideoNoteView({super.key, required this.message, required this.videoNote, required this.isViewed});

  final td.Message message;
  final td.VideoNote videoNote;
  final bool isViewed;

  @override
  ConsumerState<VideoNoteView> createState() => _VideoNoteViewState();
}

class _VideoNoteViewState extends ConsumerState<VideoNoteView> {
  VideoPlayerController? _controller;
  String? _path;

  /// Playing from the start with sound (otherwise: muted preview loop).
  bool _withSound = false;

  @override
  void dispose() {
    _controller?.removeListener(_onTick);
    unawaited(_controller?.dispose());
    super.dispose();
  }

  Future<void> _open(String path) async {
    if (_path == path) return;
    _path = path;
    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
      await controller.setVolume(0);
      await controller.setLooping(true);
      await controller.play();
    } on Object catch (error) {
      debugPrint('video note failed: $error');
      await controller.dispose();
      return;
    }
    if (!mounted) return controller.dispose();
    controller.addListener(_onTick);
    setState(() => _controller = controller);
  }

  void _onTick() {
    final controller = _controller;
    if (controller == null || !mounted) return;
    final value = controller.value;
    // Finished the audible run: back to the silent loop.
    if (_withSound && !value.isPlaying && value.position >= value.duration - const Duration(milliseconds: 200)) {
      setState(() => _withSound = false);
      unawaited(controller.setVolume(0).then((_) => controller.setLooping(true)).then((_) => controller.play()));
      return;
    }
    if (_withSound) setState(() {});
  }

  Future<void> _tap() async {
    final controller = _controller;
    if (controller == null) return;
    if (!_withSound) {
      setState(() => _withSound = true);
      await controller.setLooping(false);
      await controller.seekTo(Duration.zero);
      await controller.setVolume(1);
      await controller.play();
      // Marks it watched for the sender, unless ghost mode hides reading.
      if (!widget.message.isOutgoing && !ref.read(settingsProvider).ghostMode) {
        unawaited(ref
            .read(accountProvider)
            .send<td.Ok>(td.OpenMessageContent(chatId: widget.message.chatId, messageId: widget.message.id))
            .catchError((Object _) => const td.Ok()));
      }
    } else if (controller.value.isPlaying) {
      await controller.pause();
      setState(() {});
    } else {
      await controller.play();
    }
  }

  static String _clock(Duration d) => '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final note = widget.videoNote;
    final file = ref.watch(fileProvider(note.video.id)).value ?? note.video;
    if (file.local.isDownloadingCompleted && file.local.path.isNotEmpty) unawaited(_open(file.local.path));
    final width = MediaQuery.sizeOf(context).width;
    final diameter = min(width * 0.6, 300.0);
    final controller = _controller;
    final value = controller?.value;
    final total = Duration(seconds: note.duration);
    final remaining = _withSound && value != null ? value.duration - value.position : total;
    final progress = _withSound && value != null && value.duration.inMilliseconds > 0
        ? value.position.inMilliseconds / value.duration.inMilliseconds
        : null;
    final downloading = !file.local.isDownloadingCompleted;
    final size = file.size == 0 ? file.expectedSize : file.size;

    return GestureDetector(
      onTap: _tap,
      child: SizedBox.square(
        dimension: diameter,
        child: Stack(
          children: [
            ClipOval(
              child: SizedBox.expand(
                child: controller != null && controller.value.isInitialized
                    ? FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(width: controller.value.size.width, height: controller.value.size.height, child: VideoPlayer(controller)),
                      )
                    : note.thumbnail != null
                        ? TdImage(file: note.thumbnail!.file, minithumbnail: note.minithumbnail, width: diameter, height: diameter)
                        : const ColoredBox(color: Colors.black26),
              ),
            ),
            if (downloading)
              Center(
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                  padding: const EdgeInsets.all(12),
                  child: CircularProgressIndicator(
                    value: size > 0 ? file.local.downloadedSize / size : null,
                    strokeWidth: 2.5,
                    color: Colors.white,
                  ),
                ),
              ),
            if (progress != null)
              Positioned.fill(
                child: CircularProgressIndicator(value: progress, strokeWidth: 3, color: Colors.white.withValues(alpha: 0.9)),
              ),
            if (_withSound && value != null && !value.isPlaying)
              const Center(child: Icon(Icons.play_arrow_rounded, size: 54, color: Colors.white)),
            Positioned(
              left: diameter * 0.06,
              bottom: diameter * 0.04,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(12)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_clock(remaining), style: const TextStyle(color: Colors.white, fontSize: 12.5, fontFeatures: [FontFeature.tabularFigures()])),
                    if (!_withSound && !widget.isViewed) ...[
                      const SizedBox(width: 5),
                      Container(width: 6, height: 6, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle)),
                    ],
                    if (!_withSound) ...[
                      const SizedBox(width: 5),
                      const Icon(Icons.volume_off_rounded, size: 13, color: Colors.white),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
