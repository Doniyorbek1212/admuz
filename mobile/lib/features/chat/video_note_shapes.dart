import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../../core/video_note_crop.dart';

/// Shapes a round video message can be shown in (aka-style "video shapes").
///
/// Telegram has no field for this, so the shape rides in the video note's `length` (its pixel size):
/// circle is the plain [videoNoteSize], every other shape adds its index. Official clients still crop the
/// square video to a circle; UZARO reads the shape back with [fromLength].
/// The server does normalise `length` after sending, so the length only covers the moment before the
/// server answers; the lasting copy is the file marker ([writeMarker] / [readMarker]).
enum VideoNoteShape {
  circle,
  square,
  heart,
  star,
  flower,
  cloud,
  blob,
  cat,
  hexagon;

  /// The `length` to send for this shape.
  int get length => videoNoteSize + index;

  static VideoNoteShape fromLength(int length) {
    final i = length - videoNoteSize;
    return i >= 0 && i < values.length ? values[i] : circle;
  }

  static VideoNoteShape byName(String? name) => values.firstWhere((s) => s.name == name, orElse: () => circle);

  /// Telegram's server resets `length` to the plain size once the note is sent, so the shape also rides
  /// inside the file: a trailing MP4 `free` box (players skip it, Telegram stores the file unchanged).
  static const _marker = 'uzaro-shape:';

  /// Appends the shape marker to a finished video note file; circles need none.
  Future<void> writeMarker(String path) async {
    if (this == circle) return;
    final payload = latin1.encode('$_marker$name');
    final size = 8 + payload.length;
    final box = [size >> 24 & 0xff, size >> 16 & 0xff, size >> 8 & 0xff, size & 0xff, ...latin1.encode('free'), ...payload];
    await File(path).writeAsBytes(box, mode: FileMode.append, flush: true);
  }

  /// The shape a downloaded note carries in its file, or null when it has no marker.
  static Future<VideoNoteShape?> readMarker(String path) async {
    final file = await File(path).open();
    try {
      final length = await file.length();
      final tail = min(length, 64);
      await file.setPosition(length - tail);
      return markerIn(await file.read(tail));
    } finally {
      await file.close();
    }
  }

  /// The shape named by a marker inside a file's last bytes, or null when they hold none.
  static VideoNoteShape? markerIn(List<int> tail) {
    final text = latin1.decode(tail, allowInvalid: true);
    final at = text.lastIndexOf(_marker);
    if (at < 0) return null;
    final name = text.substring(at + _marker.length);
    return values.where((s) => s.name == name).firstOrNull;
  }

  /// Outline filling a [size] box, centred.
  Path path(Size size) {
    final s = min(size.width, size.height);
    final path = switch (this) {
      // From 12 o'clock, so progress along the outline starts at the top like Telegram's ring.
      circle => Path()
        ..addArc(Rect.fromLTWH(0, 0, s, s), -pi / 2, 2 * pi - 0.0001)
        ..close(),
      square => Path()..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, s, s), Radius.circular(s * 0.24))),
      heart => _heart(s),
      star => _polygon(s, points: 5, inner: 0.52, rotation: -pi / 2),
      flower => _polar(s, (a) => 0.86 + 0.14 * cos(8 * a)),
      cloud => _cloud(s),
      blob => _polar(s, (a) => 1 + 0.09 * sin(3 * a + 0.6) + 0.05 * cos(5 * a + 1.3)),
      cat => _cat(s),
      hexagon => _polygon(s, points: 6, inner: 1, rotation: pi / 6),
    };
    return path.shift(Offset((size.width - s) / 2, (size.height - s) / 2));
  }

  static Path _heart(double s) => Path()
    ..moveTo(s * 0.5, s * 0.94)
    ..cubicTo(s * 0.12, s * 0.70, s * 0.0, s * 0.48, s * 0.02, s * 0.30)
    ..cubicTo(s * 0.04, s * 0.10, s * 0.22, s * 0.02, s * 0.34, s * 0.04)
    ..cubicTo(s * 0.43, s * 0.05, s * 0.48, s * 0.12, s * 0.5, s * 0.18)
    ..cubicTo(s * 0.52, s * 0.12, s * 0.57, s * 0.05, s * 0.66, s * 0.04)
    ..cubicTo(s * 0.78, s * 0.02, s * 0.96, s * 0.10, s * 0.98, s * 0.30)
    ..cubicTo(s * 1.0, s * 0.48, s * 0.88, s * 0.70, s * 0.5, s * 0.94)
    ..close();

  /// Regular polygon ([inner] 1) or star ([inner] < 1: radius of the inner corners).
  static Path _polygon(double s, {required int points, required double inner, required double rotation}) {
    final r = s / 2;
    final step = inner < 1 ? pi / points : 2 * pi / points;
    final count = inner < 1 ? points * 2 : points;
    final path = Path();
    for (var i = 0; i < count; i++) {
      final radius = inner < 1 && i.isOdd ? r * inner : r;
      final p = Offset(r + radius * cos(rotation + i * step), r + radius * sin(rotation + i * step));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    return path..close();
  }

  /// Closed curve r(a) around the centre, scaled so its widest point touches the box.
  static Path _polar(double s, double Function(double a) radius) {
    const samples = 180;
    final rs = [for (var i = 0; i < samples; i++) radius(2 * pi * i / samples)];
    final scale = s / 2 / rs.reduce(max);
    final path = Path();
    for (var i = 0; i < samples; i++) {
      final a = 2 * pi * i / samples;
      final p = Offset(s / 2 + rs[i] * scale * cos(a), s / 2 + rs[i] * scale * sin(a));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    return path..close();
  }

  static Path _cloud(double s) {
    var path = Path()..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(s * 0.02, s * 0.45, s * 0.96, s * 0.45), Radius.circular(s * 0.22)));
    for (final (x, y, r) in [(0.28, 0.48, 0.24), (0.55, 0.36, 0.30), (0.78, 0.52, 0.20)]) {
      path = Path.combine(PathOperation.union, path, Path()..addOval(Rect.fromCircle(center: Offset(s * x, s * y), radius: s * r)));
    }
    return path;
  }

  static Path _cat(double s) {
    final head = Path()..addOval(Rect.fromLTWH(s * 0.02, s * 0.16, s * 0.96, s * 0.82));
    final ears = Path()
      ..moveTo(s * 0.10, s * 0.42)
      ..lineTo(s * 0.12, s * 0.02)
      ..lineTo(s * 0.42, s * 0.22)
      ..close()
      ..moveTo(s * 0.58, s * 0.22)
      ..lineTo(s * 0.88, s * 0.02)
      ..lineTo(s * 0.90, s * 0.42)
      ..close();
    return Path.combine(PathOperation.union, head, ears);
  }
}

/// Clips a video note to its shape.
class VideoNoteShapeClipper extends CustomClipper<Path> {
  const VideoNoteShapeClipper(this.shape);

  final VideoNoteShape shape;

  @override
  Path getClip(Size size) => shape.path(size);

  @override
  bool shouldReclip(VideoNoteShapeClipper oldClipper) => oldClipper.shape != shape;
}

/// The shape's outline: a faint full track and, with [progress], the played / recorded part drawn over it.
class VideoNoteShapeOutline extends CustomPainter {
  const VideoNoteShapeOutline({required this.shape, this.progress, this.color = const Color(0xFFFFFFFF), this.strokeWidth = 3, this.track = 0.28});

  final VideoNoteShape shape;
  final double? progress;
  final Color color;
  final double strokeWidth;

  /// Opacity of the full outline behind the progress; 0 hides it.
  final double track;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = strokeWidth / 2;
    final path = shape.path(Size(size.width - strokeWidth, size.height - strokeWidth)).shift(Offset(inset, inset));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (track > 0) canvas.drawPath(path, paint..color = color.withValues(alpha: track));
    final p = progress;
    if (p == null || p <= 0) return;
    paint.color = color;
    var left = path.computeMetrics().fold<double>(0, (sum, m) => sum + m.length) * p.clamp(0.0, 1.0);
    for (final metric in path.computeMetrics()) {
      if (left <= 0) break;
      canvas.drawPath(metric.extractPath(0, min(left, metric.length)), paint);
      left -= metric.length;
    }
  }

  @override
  bool shouldRepaint(VideoNoteShapeOutline old) =>
      old.shape != shape || old.progress != progress || old.color != color || old.strokeWidth != strokeWidth || old.track != track;
}
