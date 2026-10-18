import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';

/// App bar toggle for ghost mode: outlined ghost when off, filled when on.
class GhostModeButton extends ConsumerWidget {
  const GhostModeButton({super.key, this.color});

  /// Icon color when ghost mode is off; defaults to the app bar foreground.
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ghost = ref.watch(settingsProvider.select((s) => s.ghostMode));
    final idle = color ?? context.onAppBar;
    return IconButton(
      tooltip: context.t('ghost_mode'),
      isSelected: ghost,
      icon: SizedBox.square(
        dimension: 24,
        child: CustomPaint(painter: GhostPainter(color: ghost ? const Color(0xFFFFC94D) : idle, filled: ghost)),
      ),
      onPressed: () {
        final value = !ghost;
        ref.read(settingsProvider.notifier).setGhostMode(value);
        unawaited(ref.read(accountProvider).setOnline(!value));
        showToast(context, context.t(value ? 'ghost_on' : 'ghost_off'));
      },
    );
  }
}

/// Ghost glyph drawn on a 24×24 grid (Material has no ghost icon).
class GhostPainter extends CustomPainter {
  const GhostPainter({required this.color, required this.filled});

  final Color color;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final body = Path()
      ..moveTo(5, 21)
      ..lineTo(5, 10)
      ..arcToPoint(const Offset(19, 10), radius: const Radius.circular(7))
      ..lineTo(19, 21)
      ..lineTo(16.7, 19)
      ..lineTo(14.3, 21)
      ..lineTo(12, 19)
      ..lineTo(9.7, 21)
      ..lineTo(7.3, 19)
      ..close();
    final eyes = Path()
      ..addOval(Rect.fromCircle(center: const Offset(9.5, 10.5), radius: 1.4))
      ..addOval(Rect.fromCircle(center: const Offset(14.5, 10.5), radius: 1.4));
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    if (filled) {
      // Eyes are cut out of the filled body.
      canvas.drawPath(Path.combine(PathOperation.difference, body, eyes), paint);
      return;
    }
    canvas.drawPath(
      body,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(eyes, paint);
  }

  @override
  bool shouldRepaint(GhostPainter old) => old.color != color || old.filled != filled;
}
