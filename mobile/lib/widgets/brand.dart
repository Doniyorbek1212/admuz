import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

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
    // Hugs the bottom edge with open space above it: rising higher would cut through the action icons.
    final curve = Path()
      ..moveTo(w * 0.35, h)
      ..quadraticBezierTo(w * 0.8, h - 2, w, h - 14);
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

/// Light header ornament: an accent band behind the status bar (so white status icons stay readable
/// on every phone) that flows into a wave with a gold trim in the top-right corner.
/// Pair it with [SystemUiOverlayStyle.light].
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
    final bottom = top + 24;
    final shape = Path()
      ..moveTo(0, 0)
      ..lineTo(0, top)
      ..lineTo(w * 0.6, top)
      ..quadraticBezierTo(w * 0.82, top + 2, w, bottom)
      ..lineTo(w, 0)
      ..close();
    canvas.drawPath(shape, Paint()..shader = gradient.createShader(Rect.fromLTWH(0, 0, w, bottom)));
    // Gold hairline under the band, thickening into the corner trim.
    final gold = Paint()
      ..shader = brandGoldGradient.createShader(Rect.fromLTWH(0, top, w, bottom - top + 4))
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(0, top + 0.5), Offset(w * 0.6, top + 0.5), gold..strokeWidth = 1.2);
    final trim = Path()
      ..moveTo(w * 0.6, top + 0.5)
      ..quadraticBezierTo(w * 0.83, top + 3, w, bottom + 3);
    canvas.drawPath(trim, gold..strokeWidth = 2.4);
  }

  @override
  bool shouldRepaint(_CornerPainter old) => old.gradient != gradient || old.top != top;
}

/// Ink of the light phone headers: white in dark mode, a deep shade of the accent in light mode.
Color brandHeaderInk(BuildContext context) {
  final theme = Theme.of(context);
  return theme.brightness == Brightness.dark ? Colors.white : Color.lerp(theme.colorScheme.primary, Colors.black, 0.5)!;
}

/// Header of the bottom-bar tabs (To'plam, Contacts, Profile): the same light header as the chat list —
/// accent band and gold corner wave behind the status bar, a large title in accent ink on the page color.
class BrandTabBar extends StatelessWidget implements PreferredSizeWidget {
  const BrandTabBar({super.key, required this.title, this.actions});

  final String title;
  final List<Widget>? actions;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = brandHeaderInk(context);
    return AppBar(
      toolbarHeight: 64,
      automaticallyImplyLeading: false,
      backgroundColor: theme.scaffoldBackgroundColor,
      foregroundColor: ink,
      iconTheme: IconThemeData(color: ink),
      actionsIconTheme: IconThemeData(color: ink),
      // White status icons sit on the corner wave's accent band in both themes.
      systemOverlayStyle: SystemUiOverlayStyle.light,
      flexibleSpace: const BrandCornerWave(),
      titleSpacing: 20,
      title: Text(title, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.3, color: ink)),
      actions: [...?actions, const SizedBox(width: 8)],
    );
  }
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

/// Round accent-gradient action button (the "new message" button).
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
        width: 58,
        height: 58,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
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
