import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/gift_models.dart';
import '../../core/api/sado_api.dart';
import '../../core/theme.dart' show brandGold;
import '../../l10n/strings.dart';
import '../business/business_widgets.dart' show apiGuard;
import 'gift_effects.dart';
import 'gift_widgets.dart';

const _ribbon = brandGold;
const _ribbonShade = Color(0xFFA9802F);

/// A gift still in its wrapping: a frosted glass orb tied with a gold ribbon whose tail hangs below.
/// [pull] stretches the tail (pixels), [untie] (0..1) lets the ribbon fall away.
class WrappedGiftOrb extends StatelessWidget {
  const WrappedGiftOrb({super.key, required this.size, this.pull = 0, this.untie = 0, this.glow = 0});

  final double size;
  final double pull;
  final double untie;

  /// 0..1 pulse on the tail's knob, inviting a pull.
  final double glow;

  /// Height the orb needs for its tail at rest.
  static double heightFor(double size) => size * 1.45;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size, heightFor(size) + pull),
        painter: _OrbPainter(pull: pull, untie: untie, glow: glow),
      );
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.pull, required this.untie, required this.glow});

  final double pull;
  final double untie;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width * 0.46;
    final c = Offset(size.width / 2, r + size.width * 0.04);
    final sphere = Rect.fromCircle(center: c, radius: r);

    // Frosted glass: a cool radial body, a few sparkles caught inside, a bright rim and a highlight.
    canvas.drawCircle(c, r, Paint()
      ..shader = const RadialGradient(
        center: Alignment(-0.35, -0.4),
        radius: 1,
        colors: [Color(0xFFF4FBFF), Color(0xFFBFE6F2), Color(0xFF7CC2DB), Color(0xFF4F98C4)],
        stops: [0, 0.35, 0.75, 1],
      ).createShader(sphere));
    final sparkle = Paint()..color = const Color(0xCCFFFFFF);
    for (var i = 0; i < 9; i++) {
      final angle = i * 2.4;
      final distance = r * (0.25 + (i * 37 % 50) / 100);
      canvas.drawCircle(c + Offset(math.cos(angle), math.sin(angle)) * distance, r * (0.025 + (i % 3) * 0.012), sparkle);
    }
    canvas.drawCircle(c, r, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.04
      ..color = const Color(0x99FFFFFF));
    canvas.drawOval(Rect.fromCenter(center: c + Offset(-r * 0.38, -r * 0.55), width: r * 0.55, height: r * 0.2), Paint()..color = const Color(0xB3FFFFFF));

    if (untie >= 1) return;
    // Untied, the bands slip off first; the bow and tail then drop away and fade.
    final bandFade = (1 - untie * 1.8).clamp(0.0, 1.0);
    final fade = (1 - untie).clamp(0.0, 1.0);

    // The two bands follow the sphere's curve and stay inside it, with a lighter sheen down their middle.
    if (bandFade > 0) {
      canvas.save();
      canvas.clipPath(Path()..addOval(sphere));
      final vertical = Path()
        ..moveTo(c.dx, c.dy - r)
        ..quadraticBezierTo(c.dx + r * 0.28, c.dy, c.dx, c.dy + r);
      final horizontal = Path()
        ..moveTo(c.dx - r, c.dy - r * 0.05)
        ..quadraticBezierTo(c.dx, c.dy + r * 0.3, c.dx + r, c.dy - r * 0.05);
      Paint stroke(double width, Color color) => Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color.withValues(alpha: color.a * bandFade);
      for (final path in [vertical, horizontal]) {
        canvas.drawPath(path, stroke(r * 0.19, _ribbonShade));
        canvas.drawPath(path, stroke(r * 0.15, _ribbon));
        canvas.drawPath(path, stroke(r * 0.04, const Color(0x8CFFF1C9)));
      }
      canvas.restore();
    }

    canvas.save();
    canvas.translate(0, untie * r * 1.4);

    // The tail hangs from the bow; pulling stretches it and it swings a little.
    final bow = Offset(c.dx, c.dy + r * 0.98);
    final end = bow + Offset(r * 0.18 * math.sin(pull / 60), r * 0.55 + pull);
    final tail = Path()
      ..moveTo(bow.dx, bow.dy)
      ..quadraticBezierTo(bow.dx + r * 0.25, (bow.dy + end.dy) / 2, end.dx, end.dy);
    canvas.drawPath(tail, Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = r * 0.11
      ..color = _ribbon.withValues(alpha: fade));

    // Bow: two loops and a knot.
    final loop = Paint()..color = _ribbon.withValues(alpha: fade);
    for (final side in [-1.0, 1.0]) {
      canvas.save();
      canvas.translate(bow.dx + side * r * 0.2, bow.dy - r * 0.04);
      canvas.rotate(side * -0.5);
      canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: r * 0.42, height: r * 0.22), loop);
      canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: r * 0.2, height: r * 0.08), Paint()..color = _ribbonShade.withValues(alpha: fade));
      canvas.restore();
    }
    canvas.drawCircle(bow, r * 0.09, Paint()..color = _ribbonShade.withValues(alpha: fade));

    // The knob to grab, with a soft pulse while it waits.
    final knob = r * 0.12;
    if (glow > 0) canvas.drawCircle(end, knob * (1.6 + glow * 0.8), Paint()..color = Colors.white.withValues(alpha: 0.28 * (1 - glow) * fade));
    canvas.drawCircle(end, knob, Paint()..color = Colors.white.withValues(alpha: fade));
    canvas.drawCircle(end, knob, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.025
      ..color = _ribbon.withValues(alpha: fade));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.pull != pull || old.untie != untie || old.glow != glow;
}

/// Opens a wrapped gift the user received: pull the ribbon down (or tap the button), the orb bursts and the gift
/// shows, with who sent it and their words. True once opened.
Future<bool> showGiftUnwrap(BuildContext context, SentGift sent) async {
  final opened = await showGeneralDialog<SentGift>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).closeButtonLabel,
    barrierColor: const Color(0xB3000000),
    transitionDuration: const Duration(milliseconds: 320),
    transitionBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
    pageBuilder: (context, _, _) => _UnwrapView(sent: sent),
  );
  if (opened == null) return false;
  // A premium gift plays its show once it is out of the wrapping.
  if (opened.gift.premium && context.mounted) await showPremiumGift(context, opened.gift, sent: opened);
  return true;
}

class _UnwrapView extends ConsumerStatefulWidget {
  const _UnwrapView({required this.sent});

  final SentGift sent;

  @override
  ConsumerState<_UnwrapView> createState() => _UnwrapViewState();
}

class _UnwrapViewState extends ConsumerState<_UnwrapView> with TickerProviderStateMixin {
  static const _orb = 220.0;
  static const _openAt = 110.0;

  late final _hint = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  late final _spring = AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
  late final _burst = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  double _pull = 0;
  double _released = 0;
  bool _opening = false;
  SentGift? _opened;

  @override
  void initState() {
    super.initState();
    _spring.addListener(() => setState(() => _pull = _released * (1 - Curves.easeOutBack.transform(_spring.value))));
  }

  @override
  void dispose() {
    _hint.dispose();
    _spring.dispose();
    _burst.dispose();
    super.dispose();
  }

  void _drag(DragUpdateDetails details) {
    if (_opening) return;
    // The ribbon gives less the further it is pulled.
    setState(() => _pull = math.max(0, _pull + details.delta.dy * (1 - _pull / (_openAt * 2.2))));
    if (_pull >= _openAt) _open();
  }

  void _letGo([DragEndDetails? _]) {
    if (_opening || _pull == 0) return;
    _released = _pull;
    _spring.forward(from: 0);
  }

  Future<void> _open() async {
    if (_opening) return;
    setState(() => _opening = true);
    unawaited(HapticFeedback.mediumImpact());
    final opened = await apiGuard(context, () => ref.read(sadoApiProvider).openGift(widget.sent.id));
    if (!mounted) return;
    if (opened == null) {
      // Offline or refused: the ribbon goes back and can be pulled again.
      setState(() => _opening = false);
      return _letGo();
    }
    setState(() => _opened = opened);
    if (MediaQuery.disableAnimationsOf(context)) {
      _burst.value = 1;
    } else {
      await _burst.forward();
    }
  }

  Future<void> _hide() async {
    final opened = _opened;
    if (opened == null) return;
    final done = await apiGuard(context, () async {
      await ref.read(sadoApiProvider).setGiftHidden(opened.id, true);
      return true;
    });
    if (done == true && mounted) Navigator.pop(context, opened);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final opened = _opened;
    return Material(
      type: MaterialType.transparency,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: SafeArea(
          child: Stack(children: [
            Positioned(
              right: 4,
              top: 4,
              child: IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonLabel,
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                // Closed after opening, the gift is shown on the profile as usual.
                onPressed: () => Navigator.pop(context, opened),
              ),
            ),
            Center(
              child: AnimatedBuilder(
                animation: Listenable.merge([_hint, _burst]),
                builder: (context, _) => opened == null ? _wrapped(s) : _reveal(s, opened),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _wrapped(Strings s) {
    final name = giftSenderName(context, ref, widget.sent);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text(s.t('gifts_wrapped_title'), style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
      if (name.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(s.t('gifts_from', {'name': name}), style: const TextStyle(color: Colors.white70, fontSize: 15)),
      ],
      const SizedBox(height: 28),
      GestureDetector(
        onVerticalDragUpdate: _drag,
        onVerticalDragEnd: _letGo,
        onVerticalDragCancel: _letGo,
        child: Semantics(
          label: s.t('gifts_unwrap_hint'),
          child: Transform.rotate(
            angle: math.sin(_hint.value * math.pi * 2) * 0.03 * (1 - _pull / _openAt),
            child: WrappedGiftOrb(size: _orb, pull: _pull, glow: _opening ? 0 : _hint.value),
          ),
        ),
      ),
      const SizedBox(height: 16),
      if (_opening)
        const SizedBox.square(dimension: 28, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
      else ...[
        Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.south_rounded, color: Colors.white70, size: 18),
          const SizedBox(width: 6),
          Text(s.t('gifts_unwrap_hint'), style: const TextStyle(color: Colors.white70, fontSize: 15)),
        ]),
        const SizedBox(height: 6),
        // The same without dragging (screen readers, switch access).
        TextButton(onPressed: _open, child: Text(s.t('gifts_unwrap'), style: const TextStyle(color: Colors.white))),
      ],
    ]);
  }

  Widget _reveal(Strings s, SentGift opened) {
    final t = _burst.value;
    double phase(double from, double to) => ((t - from) / (to - from)).clamp(0.0, 1.0);
    final orbOut = Curves.easeIn.transform(phase(0.2, 0.55));
    final giftIn = Curves.easeOutBack.transform(phase(0.4, 0.85));
    final details = phase(0.75, 1);
    final name = giftSenderName(context, ref, opened);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: _orb * 1.6,
        height: _orb * 1.25,
        child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
          if (orbOut < 1)
            Positioned(
              top: 0,
              child: Opacity(
                opacity: 1 - orbOut,
                child: Transform.scale(
                  scale: 1 + orbOut * 0.35,
                  child: WrappedGiftOrb(size: _orb, untie: phase(0, 0.3)),
                ),
              ),
            ),
          IgnorePointer(child: CustomPaint(size: Size.square(_orb * 1.6), painter: _BurstPainter(phase(0.25, 1)))),
          if (giftIn > 0) Transform.scale(scale: giftIn, child: GiftBubble(gift: opened.gift, size: _orb)),
        ]),
      ),
      Opacity(
        opacity: details,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(opened.gift.titleFor(s.locale), style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
            if (name.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(s.t('gifts_from', {'name': name}), style: const TextStyle(color: Colors.white70, fontSize: 15)),
            ],
            if (opened.text.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('“${opened.text}”', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 17, fontStyle: FontStyle.italic)),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: details < 1 ? null : () => Navigator.pop(context, opened),
              style: FilledButton.styleFrom(minimumSize: const Size(240, 50)),
              icon: const Icon(Icons.person_pin_rounded),
              label: Text(s.t('gifts_show_on_profile')),
            ),
            TextButton(
              onPressed: details < 1 ? null : _hide,
              child: Text(s.t('gifts_keep_private'), style: const TextStyle(color: Colors.white70)),
            ),
          ]),
        ),
      ),
    ]);
  }
}

/// Gold, ice and white sparks flying out of the burst orb.
class _BurstPainter extends CustomPainter {
  _BurstPainter(this.t);

  final double t;

  static const _colors = [Color(0xFFFFD27A), Color(0xFFBFE6F2), Colors.white, brandGold];

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    final center = Offset(size.width / 2, size.height * 0.42);
    final eased = Curves.easeOutCubic.transform(t);
    for (var i = 0; i < 22; i++) {
      final angle = i * (math.pi * 2 / 22) + (i.isEven ? 0.12 : -0.08);
      final reach = size.width * (0.28 + (i * 13 % 10) / 40) * eased;
      final paint = Paint()..color = _colors[i % _colors.length].withValues(alpha: 1 - t);
      canvas.drawCircle(center + Offset(math.cos(angle), math.sin(angle)) * reach, 3.5 + (i % 3) * 1.5, paint);
    }
  }

  @override
  bool shouldRepaint(_BurstPainter old) => old.t != t;
}
