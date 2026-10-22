import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Accent bar background: deep-to-light accent gradient with a gold swoosh along the bottom right.
class BrandBarBackground extends StatelessWidget {
  const BrandBarBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final base = theme.brightness == Brightness.dark ? Color.lerp(accent, Colors.black, 0.55)! : accent;
    return CustomPaint(painter: _BarPainter(brandGradient(base)), child: const SizedBox.expand());
  }
}

class _BarPainter extends CustomPainter {
  const _BarPainter(this.gradient);

  final Gradient gradient;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..shader = gradient.createShader(rect));
    final w = size.width;
    final h = size.height;
    final curve = Path()
      ..moveTo(w * 0.5, h)
      ..quadraticBezierTo(w * 0.86, h * 0.98, w, h * 0.2);
    final glow = Path.from(curve)
      ..lineTo(w, h)
      ..close();
    canvas.drawPath(glow, Paint()..color = Colors.white.withValues(alpha: 0.08));
    canvas.drawPath(
      curve,
      Paint()
        ..shader = brandGoldGradient.createShader(Rect.fromLTWH(w * 0.5, 0, w * 0.5, h))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_BarPainter old) => old.gradient != gradient;
}

/// Light header ornament: an accent wave with a gold trim in the top-right corner.
class BrandCornerWave extends StatelessWidget {
  const BrandCornerWave({super.key});

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(
      painter: _CornerPainter(brandGradient(Theme.of(context).colorScheme.primary), MediaQuery.paddingOf(context).top),
      child: const SizedBox.expand(),
    ),
  );
}

class _CornerPainter extends CustomPainter {
  const _CornerPainter(this.gradient, this.top);

  final Gradient gradient;
  final double top;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final bottom = top + 22;
    final wave = Path()
      ..moveTo(w * 0.68, 0)
      ..quadraticBezierTo(w * 0.8, bottom * 0.95, w, bottom)
      ..lineTo(w, 0)
      ..close();
    final rect = Rect.fromLTWH(w * 0.68, 0, w * 0.32, bottom);
    canvas.drawPath(wave, Paint()..shader = gradient.createShader(rect));
    final trim = Path()
      ..moveTo(w * 0.66, 0)
      ..quadraticBezierTo(w * 0.79, bottom * 1.08, w, bottom + 4);
    canvas.drawPath(
      trim,
      Paint()
        ..shader = brandGoldGradient.createShader(rect)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_CornerPainter old) => old.gradient != gradient || old.top != top;
}

/// Thin gold ring around an avatar; the ring adds [width] + 1.5 on every side.
class GoldRing extends StatelessWidget {
  const GoldRing({super.key, required this.child, this.width = 1.8});

  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(width),
    decoration: const BoxDecoration(shape: BoxShape.circle, gradient: brandGoldGradient),
    child: Container(
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(shape: BoxShape.circle, color: Theme.of(context).colorScheme.surface),
      child: child,
    ),
  );
}

/// "UZARO" wordmark: a deep-to-accent sweep on light backgrounds, plain white on dark ones.
class BrandWordmark extends StatelessWidget {
  const BrandWordmark({super.key, this.size = 30, this.onDark = false});

  final double size;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final text = Text(
      'UZARO',
      style: TextStyle(fontSize: size, height: 1.05, fontWeight: FontWeight.w800, letterSpacing: size * 0.04, color: Colors.white),
    );
    if (onDark) return text;
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) =>
          LinearGradient(colors: [Color.lerp(accent, Colors.black, 0.55)!, Color.lerp(accent, Colors.black, 0.2)!]).createShader(bounds),
      child: text,
    );
  }
}

/// App logo on a white disc with a gold rim and a soft accent glow.
class BrandLogoBadge extends StatelessWidget {
  const BrandLogoBadge({super.key, this.size = 132});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: brandGoldGradient,
      boxShadow: [BoxShadow(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.25), blurRadius: 28, offset: const Offset(0, 10))],
    ),
    child: ClipOval(
      child: ColoredBox(
        color: Colors.white,
        child: Padding(padding: EdgeInsets.all(size * 0.08), child: Image.asset('assets/logo.png')),
      ),
    ),
  );
}

/// Round accent-gradient action button with a gold rim (the "new message" button).
class BrandFab extends StatelessWidget {
  const BrandFab({super.key, required this.icon, required this.tooltip, required this.onPressed, this.busy = false});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// Shows a spinner instead of the icon and ignores taps.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 60,
        height: 60,
        padding: const EdgeInsets.all(2.5),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: brandGoldGradient,
          boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.35), blurRadius: 16, offset: const Offset(0, 6))],
        ),
        child: Material(
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: Ink(
            decoration: BoxDecoration(shape: BoxShape.circle, gradient: brandGradient(accent, vertical: true)),
            child: InkWell(
              onTap: busy ? null : onPressed,
              child: busy
                  ? const Center(
                      child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)),
                    )
                  : Icon(icon, color: Colors.white, size: 26),
            ),
          ),
        ),
      ),
    );
  }
}
