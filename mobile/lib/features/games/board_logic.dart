/// Board squares for drawing and replays. Cells are 64 strings indexed a1=0 .. h8=63 (rank * 8 + file).
/// Chess pieces 'PNBRQK' white / 'pnbrqk' black; checkers 'w' 'W' (king) white / 'b' 'B' black; '' empty.
/// The server judges every move; this only places pieces, so replays need no rules beyond moving them.
library;

const _files = 'abcdefgh';

int squareIndex(String name) => (int.parse(name[1]) - 1) * 8 + _files.indexOf(name[0]);

String squareName(int index) => '${_files[index % 8]}${index ~/ 8 + 1}';

List<String> chessFromFen(String fen) {
  final cells = List<String>.filled(64, '');
  final rows = fen.split(' ').first.split('/');
  for (var r = 0; r < rows.length && r < 8; r++) {
    var file = 0;
    for (final ch in rows[r].split('')) {
      final skip = int.tryParse(ch);
      if (skip != null) {
        file += skip;
      } else if (file < 8) {
        cells[(7 - r) * 8 + file++] = ch;
      }
    }
  }
  return cells;
}

const chessStart = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

List<String> checkersFromServer(String position) =>
    [for (var i = 0; i < 64; i++) i < position.length && position[i] != '.' ? position[i] : ''];

List<String> checkersStart() =>
    [for (var i = 0; i < 64; i++) (i ~/ 8 + i % 8).isEven ? (i < 24 ? 'w' : i >= 40 ? 'b' : '') : ''];

/// Plays the UCI move [move] ("e2e4", "e7e8q") on [cells]: castling moves the rook, en passant takes the pawn.
List<String> playChess(List<String> cells, String move) {
  final next = [...cells];
  final from = squareIndex(move.substring(0, 2));
  final to = squareIndex(move.substring(2, 4));
  final piece = next[from];
  final white = piece == piece.toUpperCase();
  if (piece.toLowerCase() == 'k' && (to - from).abs() == 2) {
    final rookFrom = to > from ? from + 3 : from - 4;
    next[(from + to) ~/ 2] = next[rookFrom];
    next[rookFrom] = '';
  }
  if (piece.toLowerCase() == 'p' && from % 8 != to % 8 && next[to].isEmpty) {
    next[white ? to - 8 : to + 8] = '';
  }
  next[from] = '';
  next[to] = move.length > 4 ? (white ? move[4].toUpperCase() : move[4].toLowerCase()) : piece;
  return next;
}

/// Plays the checkers move [move] ("c3-d4", "c3:e5:c7"): removes every piece jumped over, crowns on the last row.
List<String> playCheckers(List<String> cells, String move) {
  final next = [...cells];
  final path = [for (final s in move.split(RegExp('[-:]'))) squareIndex(s)];
  var piece = next[path.first];
  next[path.first] = '';
  for (var i = 1; i < path.length; i++) {
    final a = path[i - 1], b = path[i];
    final df = (b % 8 - a % 8).sign, dr = (b ~/ 8 - a ~/ 8).sign;
    for (var x = a % 8 + df, y = a ~/ 8 + dr; x != b % 8; x += df, y += dr) {
      next[y * 8 + x] = '';
    }
    if ((piece == 'w' && b ~/ 8 == 7) || (piece == 'b' && b ~/ 8 == 0)) piece = piece.toUpperCase();
  }
  next[path.last] = piece;
  return next;
}

/// The position after each move (index 0 = start), for stepping through a game.
List<List<String>> replay(String kind, List<String> moves) {
  var cells = kind == 'chess' ? chessFromFen(chessStart) : checkersStart();
  final out = [cells];
  for (final move in moves) {
    cells = kind == 'chess' ? playChess(cells, move) : playCheckers(cells, move);
    out.add(cells);
  }
  return out;
}

/// The squares a move touched, for the last-move highlight.
List<int> moveSquares(String kind, String move) => kind == 'chess'
    ? [squareIndex(move.substring(0, 2)), squareIndex(move.substring(2, 4))]
    : [for (final s in move.split(RegExp('[-:]'))) squareIndex(s)];
