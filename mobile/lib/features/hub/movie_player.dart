import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/api/movie_models.dart';
import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../state/td_stream_server.dart';
import '../../state/telegram.dart';
import 'movie_downloads.dart';

/// Opens the full-screen player on [title]'s video number [index]; returns when the viewer leaves.
Future<void> openMoviePlayer(BuildContext context, MovieTitle title, int index) =>
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => MoviePlayerScreen(title: title, index: index)));

/// Where the viewer stopped in a video, if they are not at its start or end.
Duration? moviePosition(SharedPreferences prefs, String videoId) => switch (prefs.getInt('movie.pos.$videoId')) {
      final int seconds when seconds > 0 => Duration(seconds: seconds),
      _ => null,
    };

class MoviePlayerScreen extends ConsumerStatefulWidget {
  const MoviePlayerScreen({super.key, required this.title, required this.index});

  final MovieTitle title;
  final int index;

  @override
  ConsumerState<MoviePlayerScreen> createState() => _MoviePlayerScreenState();
}

class _MoviePlayerScreenState extends ConsumerState<MoviePlayerScreen> with WidgetsBindingObserver {
  static const _skip = Duration(seconds: 10);

  late int _index = widget.index;
  VideoPlayerController? _controller;
  int? _fileId;
  bool _failed = false;
  bool _chrome = true;
  double _speed = 1;
  bool _holdFast = false;
  String? _skipHint;
  Timer? _hideTimer;
  Timer? _hintTimer;
  Timer? _saveTimer;

  // Read once: dispose() saves the position and stops the download after ref is no longer usable.
  late final SharedPreferences _prefs;
  late final TelegramAccount _account;
  late final MovieDownloadsNotifier _downloads;

  MovieVideo get _video => widget.title.videos[_index];

  bool get _hasNext => _index + 1 < widget.title.videos.length;

  @override
  void initState() {
    super.initState();
    _prefs = ref.read(sharedPreferencesProvider);
    _account = ref.read(accountProvider);
    _downloads = ref.read(movieDownloadsProvider.notifier);
    WidgetsBinding.instance.addObserver(this);
    // Any orientation: the viewer turns the phone, or taps the rotate button.
    SystemChrome.setPreferredOrientations(const []);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    unawaited(WakelockPlus.enable());
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _savePosition());
    unawaited(_open());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _controller?.pause();
      _savePosition();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _savePosition();
    _hideTimer?.cancel();
    _hintTimer?.cancel();
    _saveTimer?.cancel();
    _release();
    unawaited(WakelockPlus.disable());
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // Back in the app's normal state after the rotation settles.
    Future<void>.delayed(const Duration(milliseconds: 600), () => SystemChrome.setPreferredOrientations(const []));
    super.dispose();
  }

  void _release() {
    final controller = _controller;
    _controller = null;
    unawaited(controller?.dispose());
    // Stop fetching the rest of the film once nobody watches it, unless the viewer is saving it.
    if (_fileId case final id? when !_downloads.isDownloading(_video.id)) _account.cancelDownload(id);
    _fileId = null;
  }

  Future<void> _open() async {
    setState(() => _failed = false);
    final account = _account;
    final video = _video;
    try {
      int? fileId;
      final VideoPlayerController controller;
      // Saved on the phone: plays without internet.
      if (await _downloads.savedFile(video.id) case final file?) {
        controller = VideoPlayerController.file(file);
      } else {
        final info = await account.send<td.MessageLinkInfo>(td.GetMessageLinkInfo(url: video.link));
        final content = info.message?.content;
        if (content is! td.MessageVideo) throw StateError('not a video post: ${video.link}');
        fileId = content.video.video.id;
        controller = VideoPlayerController.networkUrl(await TdStreamServer.instance.urlFor(account, fileId));
      }
      await controller.initialize();
      if (!mounted || video.id != _video.id) {
        await controller.dispose();
        return;
      }
      _fileId = fileId;
      final saved = moviePosition(_prefs, video.id);
      if (saved != null && saved < controller.value.duration - const Duration(seconds: 10)) await controller.seekTo(saved);
      await controller.setPlaybackSpeed(_speed);
      controller.addListener(_onTick);
      setState(() => _controller = controller);
      await controller.play();
      _scheduleHide();
    } on Object catch (error) {
      // TdException (channel gone, no network) or a player error.
      debugPrint('movie open failed: $error');
      if (mounted) setState(() => _failed = true);
    }
  }

  void _onTick() {
    final value = _controller?.value;
    if (value == null || !value.isInitialized) return;
    // Finished: forget the position and go on with the next episode.
    if (value.duration > Duration.zero && value.position >= value.duration - const Duration(milliseconds: 500) && !value.isPlaying) {
      _prefs.remove('movie.pos.${_video.id}');
      if (_hasNext) _goTo(_index + 1);
    }
  }

  void _savePosition() {
    final value = _controller?.value;
    if (value == null || !value.isInitialized || value.duration == Duration.zero) return;
    final prefs = _prefs;
    final key = 'movie.pos.${_video.id}';
    final nearEnd = value.position > value.duration * 0.95;
    if (value.position < const Duration(seconds: 15) || nearEnd) {
      prefs.remove(key);
    } else {
      prefs.setInt(key, value.position.inSeconds);
    }
  }

  void _goTo(int index) {
    _savePosition();
    _controller?.removeListener(_onTick);
    _release();
    setState(() => _index = index);
    unawaited(_open());
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) setState(() => _chrome = false);
    });
  }

  void _toggleChrome() {
    setState(() => _chrome = !_chrome);
    if (_chrome) _scheduleHide();
  }

  void _onDoubleTap(TapDownDetails details, double width) {
    final controller = _controller;
    if (controller == null) return;
    final forward = details.localPosition.dx > width / 2;
    final target = controller.value.position + (forward ? _skip : -_skip);
    final duration = controller.value.duration;
    unawaited(controller.seekTo(target < Duration.zero ? Duration.zero : (target > duration ? duration : target)));
    _hintTimer?.cancel();
    setState(() => _skipHint = forward ? '10 »' : '« 10');
    _hintTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _skipHint = null);
    });
  }

  Future<void> _setHoldFast(bool fast) async {
    final controller = _controller;
    if (controller == null) return;
    setState(() => _holdFast = fast);
    await controller.setPlaybackSpeed(fast ? 2 : _speed);
  }

  Future<void> _rotate() async {
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    await SystemChrome.setPreferredOrientations(
      landscape ? const [DeviceOrientation.portraitUp] : const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
    );
    _scheduleHide();
  }

  Future<void> _pickSpeed() async {
    final s = context.s;
    final picked = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(s.t('speed'), style: Theme.of(context).textTheme.titleMedium),
            for (final speed in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
              ListTile(
                leading: Icon(speed == _speed ? Icons.check_rounded : null),
                title: Text('${speed == speed.roundToDouble() ? speed.toInt() : speed}x'),
                onTap: () => Navigator.pop(context, speed),
              ),
          ]),
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _speed = picked);
    await _controller?.setPlaybackSpeed(picked);
  }

  String get _heading {
    final s = context.s;
    final v = _video;
    if (!widget.title.isSeries) return widget.title.title;
    final parts = [if (v.season > 0) s.t('movies_season', {'n': '${v.season}'}), if (v.episode > 0) s.t('movies_episode', {'n': '${v.episode}'})];
    return '${widget.title.title} · ${parts.join(' ')}${v.name.isNotEmpty ? ' · ${v.name}' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleChrome,
          onDoubleTapDown: (details) => _onDoubleTap(details, constraints.maxWidth),
          onDoubleTap: () {},
          onLongPressStart: (_) => _setHoldFast(true),
          onLongPressEnd: (_) => _setHoldFast(false),
          child: Stack(fit: StackFit.expand, children: [
            if (controller != null)
              Center(child: AspectRatio(aspectRatio: controller.value.aspectRatio, child: VideoPlayer(controller)))
            else if (_failed)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.error_outline_rounded, color: Colors.white70, size: 48),
                    const SizedBox(height: 12),
                    Text(s.t('movies_unavailable'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _open, child: Text(s.t('retry'))),
                  ]),
                ),
              )
            else
              const Center(child: CircularProgressIndicator(color: Colors.white)),
            if (controller != null)
              ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: controller,
                builder: (context, value, _) =>
                    value.isBuffering ? const Center(child: CircularProgressIndicator(color: Colors.white)) : const SizedBox.shrink(),
              ),
            if (_skipHint != null) Center(child: _pill(_skipHint!, fontSize: 22)),
            if (_holdFast) Align(alignment: const Alignment(0, -0.6), child: _pill('2x ▶▶')),
            AnimatedOpacity(
              opacity: _chrome || controller == null ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(ignoring: !_chrome && controller != null, child: _overlay(context, controller)),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _overlay(BuildContext context, VideoPlayerController? controller) {
    final s = context.s;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent, Colors.transparent, Colors.black54],
          stops: [0, 0.22, 0.72, 1],
        ),
      ),
      child: SafeArea(
        child: Column(children: [
          Row(children: [
            const BackButton(color: Colors.white),
            Expanded(
              child: Text(_heading, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            if (controller != null)
              TextButton(
                onPressed: _pickSpeed,
                child: Text('${_speed == _speed.roundToDouble() ? _speed.toInt() : _speed}x', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            IconButton(icon: const Icon(Icons.screen_rotation_rounded, color: Colors.white), tooltip: s.t('movies_rotate'), onPressed: _rotate),
          ]),
          const Spacer(),
          if (controller != null)
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: controller,
              builder: (context, value, _) => Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _roundButton(Icons.replay_10_rounded, () => controller.seekTo(value.position - _skip)),
                const SizedBox(width: 28),
                _roundButton(value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, () {
                  value.isPlaying ? controller.pause() : controller.play();
                  _scheduleHide();
                }, size: 64),
                const SizedBox(width: 28),
                _roundButton(Icons.forward_10_rounded, () => controller.seekTo(value.position + _skip)),
              ]),
            ),
          const Spacer(),
          if (controller != null) _seekBar(controller),
        ]),
      ),
    );
  }

  Widget _roundButton(IconData icon, VoidCallback onPressed, {double size = 44}) => IconButton.filled(
        iconSize: size * 0.62,
        style: IconButton.styleFrom(backgroundColor: Colors.black45, fixedSize: Size.square(size)),
        icon: Icon(icon, color: Colors.white),
        onPressed: onPressed,
      );

  Widget _seekBar(VideoPlayerController controller) {
    final s = context.s;
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final total = value.duration.inMilliseconds;
        final position = value.position.inMilliseconds.clamp(0, total > 0 ? total : 0);
        final buffered = value.buffered.isEmpty ? 0 : value.buffered.last.end.inMilliseconds.clamp(0, total > 0 ? total : 0);
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Row(children: [
            Text(formatDuration(value.position), style: const TextStyle(color: Colors.white)),
            Expanded(
              child: Slider(
                value: total > 0 ? position.toDouble() : 0,
                secondaryTrackValue: total > 0 ? buffered.toDouble() : null,
                max: total > 0 ? total.toDouble() : 1,
                activeColor: Colors.white,
                secondaryActiveColor: Colors.white54,
                inactiveColor: Colors.white24,
                onChangeStart: (_) => _hideTimer?.cancel(),
                onChanged: total > 0 ? (v) => controller.seekTo(Duration(milliseconds: v.round())) : null,
                onChangeEnd: (_) => _scheduleHide(),
              ),
            ),
            Text(formatDuration(value.duration), style: const TextStyle(color: Colors.white)),
            if (_hasNext)
              IconButton(icon: const Icon(Icons.skip_next_rounded, color: Colors.white), tooltip: s.t('movies_next'), onPressed: () => _goTo(_index + 1)),
          ]),
        );
      },
    );
  }

  Widget _pill(String text, {double fontSize = 15}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(18)),
        child: Text(text, style: TextStyle(color: Colors.white, fontSize: fontSize, fontWeight: FontWeight.w700)),
      );
}
