import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/api/market_models.dart';
import '../business/business_widgets.dart';

/// A paid hub banner: picture or muted looping video, darkened at the bottom for the headline.
class AdBannerCard extends StatelessWidget {
  const AdBannerCard({super.key, required this.ad, this.playVideo = true, this.onTap});

  final Ad ad;

  /// Plays direct video links; previews show a still instead.
  final bool playVideo;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final direct = ad.isVideo && youtubeId(ad.mediaUrl) == null && isLoadableMedia(ad.mediaUrl);
    return Material(
      // A picture still loading shows a light card, not a black slab; videos keep black behind the frame.
      color: ad.isVideo ? Colors.black : Theme.of(context).colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (direct && playVideo) _LoopingVideo(url: ad.mediaUrl) else AdMediaPreview(url: ad.mediaUrl, isVideo: ad.isVideo),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black87], stops: [0.35, 1]),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 14,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ad.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
                  if (ad.text.isNotEmpty)
                    Text(ad.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withValues(alpha: 0.88), fontSize: 13.5, height: 1.25)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoopingVideo extends StatefulWidget {
  const _LoopingVideo({required this.url});

  final String url;

  @override
  State<_LoopingVideo> createState() => _LoopingVideoState();
}

/// Ad videos stay loaded between hub visits: coming back plays them at once instead of a dark box while
/// the stream reconnects. Least recently shown is dropped past [_keptVideos]; the carousel mounts at most the
/// current page and its neighbours, so a dropped one is already off screen.
const _keptVideos = 4;
final _videoCache = <String, Future<VideoPlayerController>>{};

Future<VideoPlayerController> _adVideo(String url) {
  final cached = _videoCache.remove(url);
  if (cached != null) return _videoCache[url] = cached; // re-insert: most recently used last
  final controller = VideoPlayerController.networkUrl(Uri.parse(resolveMediaUrl(url)));
  final ready = controller.initialize().then((_) async {
    await controller.setVolume(0);
    await controller.setLooping(true);
    return controller;
  });
  _videoCache[url] = ready;
  // A failed load is not kept, so the next visit tries again.
  unawaited(ready.then<void>((_) {}, onError: (Object _) {
    if (identical(_videoCache[url], ready)) _videoCache.remove(url);
    unawaited(controller.dispose());
  }));
  while (_videoCache.length > _keptVideos) {
    final oldest = _videoCache.keys.first;
    unawaited(_videoCache.remove(oldest)!.then((c) => c.dispose(), onError: (Object _) {}));
  }
  return ready;
}

class _LoopingVideoState extends State<_LoopingVideo> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _adVideo(widget.url).then((controller) {
      if (!mounted) return;
      unawaited(controller.play());
      setState(() => _controller = controller);
    }, onError: (Object error) {
      debugPrint('ad video failed: $error');
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    // Kept in the cache for the next visit; only stops playing off screen.
    unawaited(_controller?.pause());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_failed || controller == null || !controller.value.isInitialized) return AdMediaPreview(url: widget.url, isVideo: true);
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(width: controller.value.size.width, height: controller.value.size.height, child: VideoPlayer(controller)),
    );
  }
}
