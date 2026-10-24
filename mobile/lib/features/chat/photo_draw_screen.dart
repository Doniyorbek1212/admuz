import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../l10n/strings.dart';

/// Telegram's "draw" tool: free-hand strokes over a photo, saved as a new PNG next to it. Pops with the new path.
class PhotoDrawScreen extends StatefulWidget {
  const PhotoDrawScreen({super.key, required this.path});

  final String path;

  @override
  State<PhotoDrawScreen> createState() => _PhotoDrawScreenState();
}

class _Stroke {
  _Stroke(this.color, this.width);

  final Color color;
  final double width; // In image pixels.
  final List<Offset> points = []; // In image pixels.
}

class _PhotoDrawScreenState extends State<PhotoDrawScreen> {
  static const _colors = [Colors.white, Colors.black, Color(0xFFE53935), Color(0xFFFFB300), Color(0xFF43A047), Color(0xFF1E88E5), Color(0xFF8E24AA)];

  ui.Image? _image;
  final List<_Stroke> _strokes = [];
  Color _color = const Color(0xFFE53935);
  double _brush = 8; // In screen points.
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    final codec = await ui.instantiateImageCodec(await File(widget.path).readAsBytes());
    final frame = await codec.getNextFrame();
    if (mounted) setState(() => _image = frame.image);
  }

  /// Image rectangle inside [size] (BoxFit.contain) and the image-pixels-per-point scale.
  (Rect, double) _layout(Size size, ui.Image image) {
    final scale = (size.width / image.width) < (size.height / image.height) ? size.width / image.width : size.height / image.height;
    final w = image.width * scale;
    final h = image.height * scale;
    return (Rect.fromLTWH((size.width - w) / 2, (size.height - h) / 2, w, h), scale);
  }

  Future<void> _save() async {
    final image = _image;
    if (image == null) return;
    setState(() => _saving = true);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(image, Offset.zero, Paint());
    _paintStrokes(canvas, _strokes, 1);
    final rendered = await recorder.endRecording().toImage(image.width, image.height);
    final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
    final file = File('${(await getTemporaryDirectory()).path}/drawn_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    if (mounted) Navigator.pop(context, file.path);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final image = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.undo_rounded),
            tooltip: s.t('undo'),
            onPressed: _strokes.isEmpty ? null : () => setState(_strokes.removeLast),
          ),
          IconButton(
            icon: _saving ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.check_rounded),
            tooltip: s.t('done'),
            onPressed: _saving || _strokes.isEmpty ? null : _save,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: image == null
                ? const Center(child: CircularProgressIndicator())
                : LayoutBuilder(builder: (context, constraints) {
                    final (rect, scale) = _layout(constraints.biggest, image);
                    Offset toImage(Offset p) => (p - rect.topLeft) / scale;
                    return GestureDetector(
                      onPanStart: (d) => setState(() => _strokes.add(_Stroke(_color, _brush / scale)..points.add(toImage(d.localPosition)))),
                      onPanUpdate: (d) => setState(() => _strokes.last.points.add(toImage(d.localPosition))),
                      child: CustomPaint(
                        size: constraints.biggest,
                        painter: _DrawPainter(image, rect, scale, _strokes),
                      ),
                    );
                  }),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  for (final color in _colors)
                    GestureDetector(
                      onTap: () => setState(() => _color = color),
                      child: Container(
                        width: 30,
                        height: 30,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(color: color == _color ? Colors.white : Colors.white24, width: color == _color ? 3 : 1),
                        ),
                      ),
                    ),
                  Expanded(
                    child: Slider(value: _brush, min: 3, max: 24, onChanged: (v) => setState(() => _brush = v), activeColor: _color),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

void _paintStrokes(Canvas canvas, List<_Stroke> strokes, double scale) {
  for (final stroke in strokes) {
    final paint = Paint()
      ..color = stroke.color
      ..strokeWidth = stroke.width * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    if (stroke.points.length == 1) {
      canvas.drawCircle(stroke.points.first * scale, stroke.width * scale / 2, paint..style = PaintingStyle.fill);
      continue;
    }
    final path = Path()..moveTo(stroke.points.first.dx * scale, stroke.points.first.dy * scale);
    for (final p in stroke.points.skip(1)) {
      path.lineTo(p.dx * scale, p.dy * scale);
    }
    canvas.drawPath(path, paint);
  }
}

class _DrawPainter extends CustomPainter {
  _DrawPainter(this.image, this.rect, this.scale, this.strokes);

  final ui.Image image;
  final Rect rect;
  final double scale;
  final List<_Stroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    paintImage(canvas: canvas, rect: rect, image: image, fit: BoxFit.fill);
    canvas.save();
    canvas.translate(rect.left, rect.top);
    canvas.clipRect(Offset.zero & rect.size);
    _paintStrokes(canvas, strokes, scale);
    canvas.restore();
  }

  // Strokes grow in place, so always repaint.
  @override
  bool shouldRepaint(_DrawPainter old) => true;
}
