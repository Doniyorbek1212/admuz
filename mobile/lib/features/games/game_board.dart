import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'board_logic.dart';

const _chessLight = Color(0xFFEEEED2);
const _chessDark = Color(0xFF769656);
const _checkersLight = Color(0xFFF1DDB8);
const _checkersDark = Color(0xFFA8703F);
const _lastMove = Color(0x8CF6F669);
const _selected = Color(0x99BACA44);
const _hint = Color(0x33000000);
// Filled glyphs for both colours (painted white or black), with the text-presentation selector so the pawn is not an emoji.
const _glyphs = {'k': '♚︎', 'q': '♛︎', 'r': '♜︎', 'b': '♝︎', 'n': '♞︎', 'p': '♟︎'};

/// A chess or checkers board: draws [cells] (see board_logic.dart), and when [legal] is not empty lets the
/// player pick one of those moves by tapping (a piece, then its target; checkers captures square by square).
class GameBoard extends StatefulWidget {
  const GameBoard({
    super.key,
    required this.kind,
    required this.cells,
    required this.flipped,
    this.legal = const [],
    this.lastMove = const [],
    this.checkSquare,
    this.onMove,
  });

  final String kind;
  final List<String> cells;
  final bool flipped;
  final List<String> legal;
  final List<int> lastMove;
  final int? checkSquare;
  final ValueChanged<String>? onMove;

  @override
  State<GameBoard> createState() => _GameBoardState();
}

class _GameBoardState extends State<GameBoard> {
  /// Squares picked so far: chess [from]; checkers the path of the move being built.
  List<int> _path = const [];

  bool get _chess => widget.kind == 'chess';

  @override
  void didUpdateWidget(GameBoard old) {
    super.didUpdateWidget(old);
    // By value: the game screen rebuilds the lists on every clock tick, and that must not drop the selection.
    if (!listEquals(old.cells, widget.cells) || !listEquals(old.legal, widget.legal)) _path = const [];
  }

  List<List<int>> get _legalPaths => [for (final m in widget.legal) _chess ? moveSquares('chess', m) : moveSquares('checkers', m)];

  /// Legal moves that start with the squares picked so far.
  List<int> _candidates() {
    final out = <int>[];
    final paths = _legalPaths;
    for (var i = 0; i < paths.length; i++) {
      final p = paths[i];
      if (p.length > _path.length && _startsWith(p, _path)) out.add(i);
    }
    return out;
  }

  static bool _startsWith(List<int> path, List<int> prefix) {
    for (var i = 0; i < prefix.length; i++) {
      if (path[i] != prefix[i]) return false;
    }
    return true;
  }

  Set<int> get _targets {
    if (_path.isEmpty) return const {};
    final paths = _legalPaths;
    return {for (final i in _candidates()) paths[i][_path.length]};
  }

  Set<int> get _movable => {for (final p in _legalPaths) p.first};

  Future<void> _tap(int square) async {
    if (widget.onMove == null || widget.legal.isEmpty) return;
    if (_path.isNotEmpty && _targets.contains(square)) {
      final path = [..._path, square];
      final paths = _legalPaths;
      final matches = [for (var i = 0; i < paths.length; i++) if (_startsWith(paths[i], path) && paths[i].length >= path.length) widget.legal[i]];
      final exact = [for (var i = 0; i < paths.length; i++) if (paths[i].length == path.length && _startsWith(paths[i], path)) widget.legal[i]];
      if (_chess) {
        final move = exact.length > 1 ? await _promotion(exact) : exact.firstOrNull;
        if (!mounted) return;
        setState(() => _path = const []);
        if (move != null) _play(move);
        return;
      }
      if (exact.isNotEmpty && matches.length == exact.length) {
        setState(() => _path = const []);
        _play(exact.first);
      } else {
        setState(() => _path = path);
      }
      return;
    }
    if (_movable.contains(square) && (_path.length <= 1 || _chess)) {
      setState(() => _path = _path.length == 1 && _path.first == square ? const [] : [square]);
    } else if (_path.length <= 1 || square == _path.first) {
      setState(() => _path = const []);
    }
  }

  void _play(String move) {
    HapticFeedback.selectionClick();
    widget.onMove?.call(move);
  }

  Future<String?> _promotion(List<String> moves) {
    final white = widget.cells[squareIndex(moves.first.substring(0, 2))] == 'P';
    return showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            for (final p in ['q', 'r', 'b', 'n'])
              if (moves.any((m) => m.endsWith(p)))
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.of(context).pop(moves.firstWhere((m) => m.endsWith(p))),
                  child: SizedBox.square(dimension: 64, child: CustomPaint(painter: _PiecePainter(white ? p.toUpperCase() : p))),
                ),
          ]),
        ),
      ),
    );
  }

  int _squareAt(Offset local, double size) {
    final file = (local.dx / (size / 8)).floor().clamp(0, 7);
    final row = (local.dy / (size / 8)).floor().clamp(0, 7);
    return widget.flipped ? row * 8 + (7 - file) : (7 - row) * 8 + file;
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(builder: (context, box) {
        final size = box.maxWidth;
        return GestureDetector(
          onTapUp: (d) => _tap(_squareAt(d.localPosition, size)),
          child: CustomPaint(
            size: Size.square(size),
            painter: _BoardPainter(
              kind: widget.kind,
              cells: widget.cells,
              flipped: widget.flipped,
              lastMove: widget.lastMove,
              path: _path,
              targets: _targets,
              checkSquare: widget.checkSquare,
            ),
          ),
        );
      }),
    );
  }
}

class _BoardPainter extends CustomPainter {
  _BoardPainter({
    required this.kind,
    required this.cells,
    required this.flipped,
    required this.lastMove,
    required this.path,
    required this.targets,
    required this.checkSquare,
  });

  final String kind;
  final List<String> cells;
  final bool flipped;
  final List<int> lastMove;
  final List<int> path;
  final Set<int> targets;
  final int? checkSquare;

  Rect _rect(int square, double cell) {
    final file = square % 8, rank = square ~/ 8;
    final x = flipped ? 7 - file : file, y = flipped ? rank : 7 - rank;
    return Rect.fromLTWH(x * cell, y * cell, cell, cell);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / 8;
    final chess = kind == 'chess';
    final light = chess ? _chessLight : _checkersLight, dark = chess ? _chessDark : _checkersDark;
    for (var sq = 0; sq < 64; sq++) {
      final isDark = (sq ~/ 8 + sq % 8).isEven;
      final rect = _rect(sq, cell);
      canvas.drawRect(rect, Paint()..color = isDark ? dark : light);
      if (lastMove.contains(sq)) canvas.drawRect(rect, Paint()..color = _lastMove);
      if (path.contains(sq)) canvas.drawRect(rect, Paint()..color = _selected);
      if (sq == checkSquare) {
        canvas.drawRect(rect, Paint()..shader = const RadialGradient(colors: [Color(0xFFFF2020), Color(0x00FF2020)]).createShader(rect));
      }
    }
    _coordinates(canvas, cell, light, dark);
    for (var sq = 0; sq < 64; sq++) {
      final piece = cells[sq];
      if (piece.isEmpty) continue;
      final rect = _rect(sq, cell);
      if (chess) {
        paintChessPiece(canvas, rect, piece);
      } else {
        _checker(canvas, rect, piece);
      }
    }
    for (final sq in targets) {
      final rect = _rect(sq, cell);
      if (cells[sq].isNotEmpty) {
        canvas.drawCircle(rect.center, cell * 0.46, Paint()
          ..color = _hint
          ..style = PaintingStyle.stroke
          ..strokeWidth = cell * 0.08);
      } else {
        canvas.drawCircle(rect.center, cell * 0.16, Paint()..color = _hint);
      }
    }
  }

  void _coordinates(Canvas canvas, double cell, Color light, Color dark) {
    for (var i = 0; i < 8; i++) {
      final file = flipped ? 7 - i : i, rank = flipped ? i + 1 : 8 - i;
      // Files along the bottom row, ranks down the left column, in the opposite square colour.
      final bottomDark = ((flipped ? 7 : 0) + file).isEven;
      _label(canvas, 'abcdefgh'[file], Offset((i + 1) * cell - cell * 0.2, 8 * cell - cell * 0.3), bottomDark ? light : dark, cell);
      final leftDark = (rank - 1 + (flipped ? 7 : 0)).isEven;
      _label(canvas, '$rank', Offset(cell * 0.06, i * cell + cell * 0.04), leftDark ? light : dark, cell);
    }
  }

  void _label(Canvas canvas, String text, Offset at, Color color, double cell) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: cell * 0.2, fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
  }

  void _checker(Canvas canvas, Rect rect, String piece) {
    final white = piece.toLowerCase() == 'w';
    final r = rect.width * 0.4;
    final c = rect.center;
    canvas.drawCircle(c.translate(0, r * 0.12), r, Paint()..color = const Color(0x55000000));
    canvas.drawCircle(c, r, Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.3, -0.4),
        colors: white ? const [Color(0xFFFFFFFF), Color(0xFFD9D2C3)] : const [Color(0xFF5A5A5A), Color(0xFF151515)],
      ).createShader(Rect.fromCircle(center: c, radius: r)));
    canvas.drawCircle(c, r * 0.72, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.08
      ..color = white ? const Color(0x33000000) : const Color(0x33FFFFFF));
    if (piece == piece.toUpperCase()) {
      final crown = TextPainter(
        text: TextSpan(text: '♛︎', style: TextStyle(fontSize: r * 1.05, color: const Color(0xFFE8B422))),
        textDirection: TextDirection.ltr,
      )..layout();
      crown.paint(canvas, c - Offset(crown.width / 2, crown.height / 2));
    }
  }

  @override
  bool shouldRepaint(_BoardPainter old) =>
      old.cells != cells || old.flipped != flipped || old.path != path || old.lastMove != lastMove ||
      old.checkSquare != checkSquare || old.targets.length != targets.length || old.kind != kind;
}

/// One chess piece in [rect]: a filled glyph in white or black with a contrasting outline.
void paintChessPiece(Canvas canvas, Rect rect, String piece) {
  final white = piece == piece.toUpperCase();
  final glyph = _glyphs[piece.toLowerCase()] ?? '';
  final size = rect.width * 0.84;
  TextPainter layer(Paint paint) => TextPainter(
        text: TextSpan(text: glyph, style: TextStyle(fontSize: size, height: 1, foreground: paint)),
        textDirection: TextDirection.ltr,
      )..layout();
  final outline = layer(Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = rect.width * 0.06
    ..strokeJoin = StrokeJoin.round
    ..color = white ? const Color(0xFF333333) : const Color(0xFFDDDDDD));
  final fill = layer(Paint()..color = white ? const Color(0xFFFFFFFF) : const Color(0xFF222222));
  final at = rect.center - Offset(fill.width / 2, fill.height / 2);
  outline.paint(canvas, at);
  fill.paint(canvas, at);
}

class _PiecePainter extends CustomPainter {
  _PiecePainter(this.piece);

  final String piece;

  @override
  void paint(Canvas canvas, Size size) => paintChessPiece(canvas, Offset.zero & size, piece);

  @override
  bool shouldRepaint(_PiecePainter old) => old.piece != piece;
}
