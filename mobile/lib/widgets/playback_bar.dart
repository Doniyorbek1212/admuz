import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../l10n/strings.dart';
import '../state/playback.dart';

/// Telegram's top player strip: what is playing stays controllable while browsing other chats.
class PlaybackBar extends StatelessWidget {
  const PlaybackBar({super.key});

  @override
  Widget build(BuildContext context) {
    final playback = Playback.instance;
    return ValueListenableBuilder<NowPlaying?>(
      valueListenable: playback.nowPlaying,
      builder: (context, now, _) {
        if (now == null) return const SizedBox.shrink();
        final s = context.s;
        final theme = Theme.of(context);
        final primary = theme.colorScheme.primary;
        return Material(
          color: theme.colorScheme.surface,
          elevation: 1,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 48,
                child: Row(
                  children: [
                    IconButton(icon: const Icon(Icons.skip_previous_rounded), tooltip: s.t('previous_track'), onPressed: playback.skipToPrevious),
                    StreamBuilder<PlayerState>(
                      stream: playback.player.playerStateStream,
                      builder: (context, _) => IconButton(
                        icon: Icon(playback.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: primary, size: 30),
                        tooltip: s.t(playback.isPlaying ? 'pause' : 'play'),
                        onPressed: playback.togglePlay,
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.skip_next_rounded), tooltip: s.t('next_track'), onPressed: playback.skipToNext),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: now.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                            if (now.performer.isNotEmpty) TextSpan(text: ' — ${now.performer}', style: TextStyle(color: theme.hintColor)),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.close_rounded, size: 20), tooltip: s.t('close'), onPressed: playback.stop),
                  ],
                ),
              ),
              StreamBuilder<Duration>(
                stream: playback.player.positionStream,
                builder: (context, position) {
                  final total = playback.player.duration?.inMilliseconds ?? 0;
                  final elapsed = position.data?.inMilliseconds ?? 0;
                  return LinearProgressIndicator(
                    value: total > 0 ? (elapsed / total).clamp(0.0, 1.0) : 0,
                    minHeight: 2,
                    color: primary,
                    backgroundColor: Colors.transparent,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
