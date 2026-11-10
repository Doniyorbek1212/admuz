import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tdlib_ex/td_api.dart' as td;

/// Full-chat celebrations played over the message list when a message or a reaction asks for one.
enum ScreenEffect { confetti, hearts, fire }

/// Keywords per effect (Uzbek first, then Russian and English). Matched at a word start, case- and apostrophe-insensitive.
const _keywords = <ScreenEffect, List<String>>{
  ScreenEffect.confetti: [
    'tabriklayman', 'tabriklaymiz', "tug'ilgan kuning bilan", "tug'ilgan kuningiz bilan", 'muborak',
    'поздравляю', 'с днем рождения', 'с днём рождения', 'congratulations', 'happy birthday',
  ],
  ScreenEffect.hearts: [
    'rahmat', 'sevaman', "yaxshi ko'raman", 'спасибо', 'люблю', 'thank you', 'love you',
  ],
  ScreenEffect.fire: [
    "yong'in", 'daxshat', 'dahshat', 'огонь', 'жесть',
  ],
};

/// Reactions that start an effect.
const _reactionEffects = <String, ScreenEffect>{
  '❤': ScreenEffect.hearts,
  '🔥': ScreenEffect.fire,
  '🎉': ScreenEffect.confetti,
};

final _apostrophes = RegExp('[ʻʼ‘’`´]');

/// The effect a message text asks for, or null. Long texts (articles, forwarded posts) never trigger one.
ScreenEffect? effectForText(String text) {
  if (text.isEmpty || text.length > 300) return null;
  final normalized = ' ${text.toLowerCase().replaceAll(_apostrophes, "'")}';
  for (final MapEntry(key: effect, value: words) in _keywords.entries) {
    for (final word in words) {
      // A word start: "muborak" yes, "nomuborak" no.
      for (var at = normalized.indexOf(word); at > 0; at = normalized.indexOf(word, at + 1)) {
        if (!_isLetter(normalized.codeUnitAt(at - 1))) return effect;
      }
    }
  }
  return null;
}

bool _isLetter(int unit) {
  final char = String.fromCharCode(unit);
  return char.toLowerCase() != char.toUpperCase() || char == "'";
}

/// The effect a reaction emoji asks for (the variation selector does not matter), or null.
ScreenEffect? effectForReaction(String emoji) => _reactionEffects[emoji.replaceAll('️', '')];

/// The effect of a reaction that was just added: compares emoji reaction counts before and after.
ScreenEffect? effectForNewReaction(td.MessageInteractionInfo? before, td.MessageInteractionInfo? after) {
  Map<String, int> counts(td.MessageInteractionInfo? info) => {
        for (final reaction in info?.reactions?.reactions ?? const <td.MessageReaction>[])
          if (reaction.type case td.ReactionTypeEmoji(:final emoji)) emoji: reaction.totalCount,
      };
  final old = counts(before);
  for (final MapEntry(key: emoji, value: count) in counts(after).entries) {
    if (count > (old[emoji] ?? 0)) {
      if (effectForReaction(emoji) case final effect?) return effect;
    }
  }
  return null;
}

/// Plays [ScreenEffect]s over the whole screen (in the app's overlay); never takes touches. Call [ScreenEffectsOverlayState.play].
class ScreenEffectsOverlay extends StatefulWidget {
  const ScreenEffectsOverlay({super.key});

  @override
  State<ScreenEffectsOverlay> createState() => ScreenEffectsOverlayState();
}

class ScreenEffectsOverlayState extends State<ScreenEffectsOverlay> with SingleTickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 3400);
  late final AnimationController _controller = AnimationController(vsync: this, duration: _duration);
  final _random = math.Random();
  OverlayEntry? _entry;

  @override
  void dispose() {
    _remove();
    _controller.dispose();
    super.dispose();
  }

  void _remove() {
    _entry?.remove();
    _entry = null;
  }

  void play(ScreenEffect effect) {
    if (!mounted || MediaQuery.disableAnimationsOf(context)) return;
    _remove();
    final particles = List.generate(effect == ScreenEffect.confetti ? 110 : 34, (_) => _Particle.random(effect, _random));
    final entry = OverlayEntry(
      builder: (_) => IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(size: Size.infinite, painter: _EffectPainter(effect, particles, _controller)),
        ),
      ),
    );
    _entry = entry;
    Overlay.of(context).insert(entry);
    _controller.forward(from: 0).whenComplete(() {
      if (_entry == entry) _remove();
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// One particle, in unit coordinates (0..1 of the overlay) so it fits any screen size.
class _Particle {
  const _Particle(this.x, this.delay, this.speed, this.size, this.sway, this.spin, this.color);

  factory _Particle.random(ScreenEffect effect, math.Random r) => _Particle(
        r.nextDouble(),
        r.nextDouble() * (effect == ScreenEffect.confetti ? 0.25 : 0.4),
        0.7 + r.nextDouble() * 0.6,
        effect == ScreenEffect.confetti ? 6 + r.nextDouble() * 7 : 22 + r.nextDouble() * 22,
        (r.nextDouble() - 0.5) * 2,
        (r.nextDouble() - 0.5) * 14,
        _confettiColors[r.nextInt(_confettiColors.length)],
      );

  final double x;
  final double delay;
  final double speed;
  final double size;
  final double sway;
  final double spin;
  final Color color;
}

const _confettiColors = [
  Color(0xFFFF5C8A), Color(0xFFFFC542), Color(0xFF26C6B0), Color(0xFF3D8BFF), Color(0xFF8B6CFF), Color(0xFFFF7043),
];

class _EffectPainter extends CustomPainter {
  _EffectPainter(this.effect, this.particles, this.progress) : super(repaint: progress);

  final ScreenEffect effect;
  final List<_Particle> particles;
  final Animation<double> progress;

  static final _emoji = <String, TextPainter>{};

  static TextPainter _glyph(String emoji) => _emoji.putIfAbsent(
        emoji,
        () => TextPainter(text: TextSpan(text: emoji, style: const TextStyle(fontSize: 40)), textDirection: TextDirection.ltr)..layout(),
      );

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    final paint = Paint();
    for (final p in particles) {
      // Each particle runs on its own clock: starts after its delay, ends with the effect.
      final local = ((t - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
      if (local <= 0) continue;
      final fade = local > 0.8 ? (1 - local) / 0.2 : 1.0;
      switch (effect) {
        case ScreenEffect.confetti:
          // Bursts from the top, falls with gravity, sways and spins.
          final y = -0.05 + local * local * 1.15 * p.speed;
          final x = p.x + math.sin(local * math.pi * 3 + p.sway * 4) * 0.04;
          canvas.save();
          canvas.translate(x * size.width, y * size.height);
          canvas.rotate(local * p.spin);
          paint.color = p.color.withValues(alpha: fade);
          canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 0.55), const Radius.circular(1.5)), paint);
          canvas.restore();
        case ScreenEffect.hearts || ScreenEffect.fire:
          // Rises from the bottom; fire faster and flickering, hearts slower and swaying.
          final fire = effect == ScreenEffect.fire;
          final y = 1.05 - local * (fire ? 1.1 : 0.95) * p.speed;
          final x = p.x + math.sin(local * math.pi * (fire ? 5 : 2) + p.sway * 3) * (fire ? 0.02 : 0.05);
          final pop = local < 0.15 ? local / 0.15 : 1.0;
          final flicker = fire ? 1 + math.sin(local * 40 + p.spin) * 0.08 : 1.0;
          final scale = p.size / 40 * pop * flicker;
          final glyph = _glyph(fire ? '🔥' : '❤️');
          canvas.save();
          canvas.translate(x * size.width, y * size.height);
          canvas.scale(scale);
          final box = Rect.fromCenter(center: Offset.zero, width: glyph.width, height: glyph.height);
          canvas.saveLayer(box, Paint()..color = Color.fromRGBO(0, 0, 0, fade));
          glyph.paint(canvas, box.topLeft);
          canvas.restore();
          canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(_EffectPainter oldDelegate) => oldDelegate.effect != effect || oldDelegate.particles != particles;
}
