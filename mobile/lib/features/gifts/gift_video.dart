import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/api/gift_models.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';

/// Plays a premium gift's video full screen with sound, like a live-stream gift; closes at the end or on a tap.
/// [sent] adds who sent it; null right after sending (the sender's own preview).
Future<void> showGiftVideoOf(BuildContext context, GiftItem gift, {SentGift? sent}) {
  if (gift.videoUrl == null) return Future.value();
  return Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.black87,
    transitionDuration: const Duration(milliseconds: 250),
    reverseTransitionDuration: const Duration(milliseconds: 300),
    pageBuilder: (_, _, _) => _GiftVideoPage(gift: gift, sent: sent),
    transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
  ));
}

class _GiftVideoPage extends ConsumerStatefulWidget {
  const _GiftVideoPage({required this.gift, required this.sent});

  final GiftItem gift;
  final SentGift? sent;

  @override
  ConsumerState<_GiftVideoPage> createState() => _GiftVideoPageState();
}

class _GiftVideoPageState extends ConsumerState<_GiftVideoPage> {
  late final VideoPlayerController _video = VideoPlayerController.networkUrl(Uri.parse(widget.gift.videoUrl!));
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await _video.initialize();
      await _video.setVolume(1);
      _video.addListener(_onTick);
      await _video.play();
      if (mounted) setState(() {});
    } on Exception catch (error) {
      // A video that will not load must not leave a black screen over the profile.
      debugPrint('gift video failed: $error');
      _close();
    }
  }

  void _onTick() {
    final value = _video.value;
    if (value.isInitialized && !value.isPlaying && value.position >= value.duration) _close();
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _video
      ..removeListener(_onTick)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sender = switch (widget.sent) { final sent? => ref.watch(accountProvider).users[sent.senderTelegramId], null => null };
    final name = sender == null ? '' : '${sender.firstName} ${sender.lastName}'.trim();
    final size = _video.value.size;
    // Material gives the titles a text theme (no debug underline) on this bare route.
    return Material(
      type: MaterialType.transparency,
      child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _close,
      child: Stack(fit: StackFit.expand, children: [
        if (_video.value.isInitialized)
          FittedBox(fit: BoxFit.cover, child: SizedBox(width: size.width, height: size.height, child: VideoPlayer(_video)))
        else
          const Center(child: CircularProgressIndicator(color: Colors.white)),
        Positioned(
          left: 24,
          right: 24,
          bottom: MediaQuery.paddingOf(context).bottom + 40,
          child: Column(children: [
            Text(
              widget.gift.titleFor(context.s.locale),
              style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900, shadows: [Shadow(blurRadius: 12)]),
            ),
            if (name.isNotEmpty)
              Text(context.t('gifts_from', {'name': name}),
                  style: const TextStyle(color: Colors.white, fontSize: 16, shadows: [Shadow(blurRadius: 10)])),
          ]),
        ),
        Positioned(
          top: MediaQuery.paddingOf(context).top + 8,
          right: 8,
          child: IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonLabel,
            onPressed: _close,
            icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28, shadows: [Shadow(blurRadius: 8)]),
          ),
        ),
      ]),
      ),
    );
  }
}
