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
import 'video_note_shapes.dart';

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

  /// Shape read from the file's marker; the server resets the note's length, so this is the one that lasts.
  VideoNoteShape? _fileShape;

  /// Tapped while auto-download is off: fetch it, then play with sound as soon as it is ready.
  bool _requested = false;

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
    try {
      final shape = await VideoNoteShape.readMarker(path);
      if (shape != null && mounted) setState(() => _fileShape = shape);
    } on FileSystemException catch (error) {
      debugPrint('video note shape unreadable: $error');
    }
    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
      await controller.setVolume(0);
      await controller.setLooping(true);
      // Power saving / video autoplay off: the first frame waits for a tap.
      if (ref.read(motionProvider).videos) await controller.play();
    } on Object catch (error) {
      debugPrint('video note failed: $error');
      await controller.dispose();
      return;
    }
    if (!mounted) return controller.dispose();
    controller.addListener(_onTick);
    setState(() => _controller = controller);
    if (_requested) unawaited(_tap());
  }

  void _onTick() {
    final controller = _controller;
    if (controller == null || !mounted) return;
    final value = controller.value;
    // Finished the audible run: back to the silent loop.
    if (_withSound && !value.isPlaying && value.position >= value.duration - const Duration(milliseconds: 200)) {
      _backToPreview(controller);
      return;
    }
    if (_withSound) setState(() {});
  }

  /// Ends the audible run (finished or closed with ✕): small, silent, looping preview again.
  void _backToPreview(VideoPlayerController controller) {
    setState(() => _withSound = false);
    final loop = ref.read(motionProvider).videos;
    unawaited(controller.setVolume(0).then((_) => controller.setLooping(true)).then((_) => loop ? controller.play() : controller.seekTo(Duration.zero)));
  }

  Future<void> _tap() async {
    final controller = _controller;
    if (controller == null) {
      if (!_requested) setState(() => _requested = true);
      return;
    }
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
    final auto = ref.watch(settingsProvider.select((s) => s.autoDownloadPhotos));
    final fetch = auto || _requested;
    final file = (fetch ? ref.watch(fileProvider(note.video.id)).value : ref.watch(fileStateProvider(note.video.id)).value) ?? note.video;
    if (file.local.isDownloadingCompleted && file.local.path.isNotEmpty) unawaited(_open(file.local.path));
    final width = MediaQuery.sizeOf(context).width;
    // Grows while playing with sound, as in Telegram/aka, and shrinks back to the preview size after.
    final diameter = _withSound ? min(width * 0.86, 420.0) : min(width * 0.6, 300.0);
    final controller = _controller;
    final value = controller?.value;
    final total = Duration(seconds: note.duration);
    final remaining = _withSound && value != null ? value.duration - value.position : total;
    final progress = _withSound && value != null && value.duration.inMilliseconds > 0
        ? value.position.inMilliseconds / value.duration.inMilliseconds
        : null;
    final downloading = !file.local.isDownloadingCompleted && (fetch || file.local.isDownloadingActive);
    final size = file.size == 0 ? file.expectedSize : file.size;
    final shape = _fileShape ?? VideoNoteShape.fromLength(note.length);

    return GestureDetector(
      onTap: _tap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        width: diameter,
        height: diameter,
        child: Stack(
          children: [
            ClipPath(
              clipper: VideoNoteShapeClipper(shape),
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
            // Shaped notes get a thin outline (as in the shapes design); a progress line runs along it while playing.
            if (progress != null || shape != VideoNoteShape.circle)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: VideoNoteShapeOutline(
                      shape: shape,
                      progress: progress,
                      color: Colors.white.withValues(alpha: 0.9),
                      strokeWidth: progress != null ? 3 : 1.5,
                      track: progress != null ? 0 : 0.55,
                    ),
                  ),
                ),
              ),
            if (!fetch && !file.local.isDownloadingCompleted && !file.local.isDownloadingActive)
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                  child: const Icon(Icons.download_rounded, color: Colors.white, size: 28),
                ),
              ),
            if (_withSound && value != null && !value.isPlaying)
              const Center(child: Icon(Icons.play_arrow_rounded, size: 54, color: Colors.white)),
            // While enlarged (playing or paused) a ✕ shrinks it back without waiting for the end.
            if (_withSound && controller != null)
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  onPressed: () => _backToPreview(controller),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ),
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
