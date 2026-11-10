import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../core/formatters.dart';
import '../l10n/strings.dart';
import '../state/playback.dart';

/// Telegram's top player strip: what is playing stays controllable while browsing other chats.
/// Tapping the title opens the full player with a seek bar.
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
                      child: InkWell(
                        onTap: () => showPlayerSheet(context),
                        child: SizedBox.expand(
                          child: Align(
                            alignment: Alignment.centerLeft,
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
                        ),
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

/// Full player: title, a seek bar to jump anywhere in the track, times, ±10 s, previous / play / next.
Future<void> showPlayerSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => const _PlayerSheet(),
    );

class _PlayerSheet extends StatelessWidget {
  const _PlayerSheet();

  static const _skip = Duration(seconds: 10);

  @override
  Widget build(BuildContext context) {
    final playback = Playback.instance;
    final player = playback.player;
    final s = context.s;
    final theme = Theme.of(context);
    return ValueListenableBuilder<NowPlaying?>(
      valueListenable: playback.nowPlaying,
      builder: (context, now, _) {
        if (now == null) return const SizedBox(height: 120);
        Future<void> seekBy(Duration delta) async {
          final total = player.duration ?? Duration.zero;
          final target = player.position + delta;
          await player.seek(target < Duration.zero ? Duration.zero : (total > Duration.zero && target > total ? total : target));
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircleAvatar(
              radius: 44,
              backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.12),
              child: Icon(now.isMusic ? Icons.music_note_rounded : Icons.mic_rounded, size: 44, color: theme.colorScheme.primary),
            ),
            const SizedBox(height: 16),
            Text(now.title, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            if (now.performer.isNotEmpty) Text(now.performer, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: theme.hintColor)),
            const SizedBox(height: 12),
            const _SeekBar(),
            StreamBuilder<PlayerState>(
              stream: player.playerStateStream,
              builder: (context, _) => Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                IconButton(iconSize: 30, icon: const Icon(Icons.skip_previous_rounded), tooltip: s.t('previous_track'), onPressed: playback.skipToPrevious),
                IconButton(iconSize: 30, icon: const Icon(Icons.replay_10_rounded), tooltip: s.t('seek_back_10'), onPressed: () => seekBy(-_skip)),
                IconButton.filled(
                  iconSize: 40,
                  icon: Icon(playback.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  tooltip: s.t(playback.isPlaying ? 'pause' : 'play'),
                  onPressed: playback.togglePlay,
                ),
                IconButton(iconSize: 30, icon: const Icon(Icons.forward_10_rounded), tooltip: s.t('seek_forward_10'), onPressed: () => seekBy(_skip)),
                IconButton(iconSize: 30, icon: const Icon(Icons.skip_next_rounded), tooltip: s.t('next_track'), onPressed: playback.skipToNext),
              ]),
            ),
          ]),
        );
      },
    );
  }
}

/// Draggable position: the thumb follows the finger while dragging, the player seeks once on release.
class _SeekBar extends StatefulWidget {
  const _SeekBar();

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _dragging; // milliseconds under the finger

  @override
  Widget build(BuildContext context) {
    final player = Playback.instance.player;
    final hint = TextStyle(color: Theme.of(context).hintColor, fontFeatures: const [FontFeature.tabularFigures()]);
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (context, snapshot) {
        final total = (player.duration ?? Duration.zero).inMilliseconds.toDouble();
        final position = (_dragging ?? (snapshot.data ?? Duration.zero).inMilliseconds.toDouble()).clamp(0.0, total > 0 ? total : 0.0);
        final buffered = player.bufferedPosition.inMilliseconds.toDouble().clamp(0.0, total > 0 ? total : 0.0);
        return Column(children: [
          Slider(
            value: total > 0 ? position : 0,
            max: total > 0 ? total : 1,
            secondaryTrackValue: total > 0 ? buffered : null,
            onChanged: total > 0 ? (v) => setState(() => _dragging = v) : null,
            onChangeEnd: (v) async {
              await player.seek(Duration(milliseconds: v.round()));
              if (mounted) setState(() => _dragging = null);
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(formatDuration(Duration(milliseconds: position.round())), style: hint),
              Text(total > 0 ? formatDuration(Duration(milliseconds: total.round())) : '--:--', style: hint),
            ]),
          ),
        ]);
      },
    );
  }
}
