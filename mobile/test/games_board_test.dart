import 'package:flutter_test/flutter_test.dart';
import 'package:sado/features/games/board_logic.dart';
import 'package:sado/features/games/game_screen.dart' show formatClock;

void main() {
  test('FEN start position puts the pieces on the right squares', () {
    final cells = chessFromFen(chessStart);
    expect(cells[squareIndex('e1')], 'K');
    expect(cells[squareIndex('d8')], 'q');
    expect(cells[squareIndex('a2')], 'P');
    expect(cells.where((c) => c.isEmpty).length, 32);
  });

  test('chess replay handles castling, en passant and promotion', () {
    var cells = replay('chess', ['e2e4', 'a7a6', 'e4e5', 'd7d5', 'e5d6', 'a6a5', 'g1f3', 'a5a4', 'f1e2', 'a4a3', 'e1g1']).last;
    expect(cells[squareIndex('d5')], '', reason: 'en passant took the pawn');
    expect(cells[squareIndex('d6')], 'P');
    expect(cells[squareIndex('g1')], 'K');
    expect(cells[squareIndex('f1')], 'R');
    expect(cells[squareIndex('h1')], '');
    cells = playChess(List.filled(64, '')..[squareIndex('b7')] = 'P', 'b7b8n');
    expect(cells[squareIndex('b8')], 'N');
  });

  test('checkers moves remove jumped pieces and crown on the last row', () {
    final start = checkersStart();
    expect(start.where((c) => c == 'w').length, 12);
    expect(start[squareIndex('a1')], 'w');
    expect(start[squareIndex('h8')], 'b');
    final board = List.filled(64, '')
      ..[squareIndex('c5')] = 'w'
      ..[squareIndex('d6')] = 'b'
      ..[squareIndex('f8')] = '';
    final after = playCheckers(board, 'c5:e7');
    expect(after[squareIndex('d6')], '');
    expect(after[squareIndex('e7')], 'w');
    final crowned = playCheckers(List.filled(64, '')..[squareIndex('g7')] = 'w', 'g7-h8');
    expect(crowned[squareIndex('h8')], 'W');
    final king = playCheckers(List.filled(64, '')
      ..[squareIndex('a1')] = 'W'
      ..[squareIndex('c3')] = 'b'
      ..[squareIndex('f6')] = 'b', 'a1:e5:g7');
    expect(king.where((c) => c == 'b'), isEmpty);
    expect(king[squareIndex('g7')], 'W');
  });

  test('server checkers position maps dots to empty squares', () {
    final cells = checkersFromServer('w.w.w.w.${'.' * 56}');
    expect(cells[0], 'w');
    expect(cells[1], '');
  });

  test('clock shows tenths under ten seconds without a broken carry', () {
    expect(formatClock(9950), '0:09.9');
    expect(formatClock(4321), '0:04.3');
    expect(formatClock(65000), '1:05');
  });
}
