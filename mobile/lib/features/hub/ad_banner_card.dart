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
      color: Colors.black,
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

class _LoopingVideoState extends State<_LoopingVideo> {
  late final VideoPlayerController _controller = VideoPlayerController.networkUrl(Uri.parse(resolveMediaUrl(widget.url)));
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _controller.initialize().then((_) {
      if (!mounted) return;
      _controller
        ..setVolume(0)
        ..setLooping(true)
        ..play();
      setState(() {});
    }, onError: (Object error) {
      debugPrint('ad video failed: $error');
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed || !_controller.value.isInitialized) return AdMediaPreview(url: widget.url, isVideo: true);
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(width: _controller.value.size.width, height: _controller.value.size.height, child: VideoPlayer(_controller)),
    );
  }
}
