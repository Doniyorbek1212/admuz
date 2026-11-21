"""The two games behind one interface: replay a move list, get the position, the legal moves and the outcome.

The server is the only judge: every move a player sends is checked against [Analysis.legal] of the replayed game.
Both games start with white. Chess moves are UCI ("e2e4", "e7e8q"); checkers moves are square paths
("c3-d4", captures "c3:e5:c7").
"""

from dataclasses import dataclass
from typing import Literal

import chess

Side = Literal["white", "black"]
Winner = Literal["white", "black", "draw"]


@dataclass(frozen=True)
class Outcome:
    winner: Winner
    reason: str  # checkmate | stalemate | insufficient | repetition | fifty | no_moves | kings_only


@dataclass(frozen=True)
class Analysis:
    position: str  # chess: FEN; checkers: 64 cells a1..h8 row by row ('.', 'w', 'W', 'b', 'B')
    turn: Side
    legal: list[str]
    outcome: Outcome | None
    notation: tuple[str, ...] = ()  # the moves as players read them (chess SAN "Nf3", "O-O"; checkers as played)
    check: bool = False  # chess: the side to move is in check


def analyse(kind: str, moves: list[str]) -> Analysis:
    """Raises ValueError when [moves] is not a legal game."""
    if kind == "chess":
        return _analyse_chess(moves)
    if kind == "checkers":
        return _analyse_checkers(moves)
    raise ValueError(f"unknown game {kind}")


# ---- chess (python-chess does the rules) ----

_CHESS_REASONS = {
    chess.Termination.CHECKMATE: "checkmate",
    chess.Termination.STALEMATE: "stalemate",
    chess.Termination.INSUFFICIENT_MATERIAL: "insufficient",
    chess.Termination.SEVENTYFIVE_MOVES: "fifty",
    chess.Termination.FIVEFOLD_REPETITION: "repetition",
    chess.Termination.FIFTY_MOVES: "fifty",
    chess.Termination.THREEFOLD_REPETITION: "repetition",
}


def _analyse_chess(moves: list[str]) -> Analysis:
    board = chess.Board()
    notation: list[str] = []
    for move in moves:
        try:
            parsed = board.parse_uci(move)
        except ValueError as exc:
            raise ValueError(f"illegal move {move}") from exc
        notation.append(board.san(parsed))
        board.push(parsed)
    # A threefold repetition or fifty moves that have happened end the game at once instead of waiting for a claim.
    # (outcome(claim_draw=True) also counts a repetition the side to move could only reach next move.)
    result = board.outcome()
    outcome = None
    if result is not None:
        winner: Winner = "draw" if result.winner is None else ("white" if result.winner else "black")
        outcome = Outcome(winner, _CHESS_REASONS.get(result.termination, "draw"))
    elif board.is_repetition(3):
        outcome = Outcome("draw", "repetition")
    elif board.halfmove_clock >= 100:
        outcome = Outcome("draw", "fifty")
    legal = [] if outcome else [m.uci() for m in board.legal_moves]
    return Analysis(board.fen(), "white" if board.turn else "black", legal, outcome, tuple(notation), board.is_check())


# ---- Russian checkers (8x8): men capture backwards too, flying kings, captures are compulsory, a man that
# reaches the far row mid-capture is crowned and goes on capturing as a king, captured pieces leave the board
# only when the move ends (and may not be jumped twice). ----

_FILES = "abcdefgh"
_DIRS = ((1, 1), (-1, 1), (1, -1), (-1, -1))
KINGS_ONLY_DRAW_PLIES = 30  # 15 moves each with only kings moving and nothing captured


def _name(c: int, r: int) -> str:
    return f"{_FILES[c]}{r + 1}"


def _parse(square: str) -> tuple[int, int]:
    if len(square) != 2 or square[0] not in _FILES or not square[1].isdigit() or not 1 <= int(square[1]) <= 8:
        raise ValueError(f"bad square {square}")
    return _FILES.index(square[0]), int(square[1]) - 1


def _inside(c: int, r: int) -> bool:
    return 0 <= c < 8 and 0 <= r < 8


def initial_checkers() -> list[str]:
    cells = ["."] * 64
    for r in range(8):
        for c in range(8):
            if (c + r) % 2 == 0:
                cells[r * 8 + c] = "w" if r < 3 else "b" if r > 4 else "."
    return cells


def _enemy(piece: str, other: str) -> bool:
    return other != "." and other.lower() != piece.lower()


def _crown_row(piece: str) -> int:
    return 7 if piece.lower() == "w" else 0


def _captures(cells: list[str], c: int, r: int, piece: str, taken: frozenset[tuple[int, int]]) -> list[list[tuple[int, int]]]:
    """Every capture sequence for [piece] standing on (c, r): lists of landing squares, longest continuation first."""
    found: list[list[tuple[int, int]]] = []
    for dc, dr in _DIRS:
        x, y = c + dc, r + dr
        if piece.isupper():
            while _inside(x, y) and cells[y * 8 + x] == ".":
                x, y = x + dc, y + dr
        if not _inside(x, y) or (x, y) in taken or not _enemy(piece, cells[y * 8 + x]):
            continue
        landings = []
        lx, ly = x + dc, y + dr
        while _inside(lx, ly) and cells[ly * 8 + lx] == ".":
            landings.append((lx, ly))
            if piece.islower():
                break
            lx, ly = lx + dc, ly + dr
        branches = []
        for lx, ly in landings:
            crowned = piece.upper() if piece.islower() and ly == _crown_row(piece) else piece
            more = _captures(cells, lx, ly, crowned, taken | {(x, y)})
            branches.append(((lx, ly), more))
        # A king must stop on a square from which it can go on capturing, when there is one.
        if any(more for _, more in branches):
            branches = [b for b in branches if b[1]]
        for landing, more in branches:
            found.extend([[landing, *rest] for rest in more] if more else [[landing]])
    return found


def _checkers_moves(cells: list[str], side: str) -> list[str]:
    captures: list[str] = []
    quiet: list[str] = []
    for r in range(8):
        for c in range(8):
            piece = cells[r * 8 + c]
            if piece.lower() != side:
                continue
            board = cells.copy()
            board[r * 8 + c] = "."  # the moving piece may pass over its own starting square
            for path in _captures(board, c, r, piece, frozenset()):
                captures.append(":".join(_name(x, y) for x, y in [(c, r), *path]))
            if captures:
                continue
            forward = 1 if side == "w" else -1
            for dc, dr in _DIRS:
                if piece.islower() and dr != forward:
                    continue
                x, y = c + dc, r + dr
                while _inside(x, y) and cells[y * 8 + x] == ".":
                    quiet.append(f"{_name(c, r)}-{_name(x, y)}")
                    if piece.islower():
                        break
                    x, y = x + dc, y + dr
    return captures or quiet


def _play_checkers(cells: list[str], move: str) -> tuple[list[str], bool, bool]:
    """Plays an already legal move; returns the new cells, whether it captured and whether a man moved."""
    squares = [_parse(s) for s in move.replace("-", ":").split(":")]
    board = cells.copy()
    (c, r), piece = squares[0], cells[squares[0][1] * 8 + squares[0][0]]
    board[r * 8 + c] = "."
    captured = False
    for (x0, y0), (x1, y1) in zip(squares, squares[1:], strict=False):
        dc, dr = (1 if x1 > x0 else -1), (1 if y1 > y0 else -1)
        x, y = x0 + dc, y0 + dr
        while (x, y) != (x1, y1):
            if board[y * 8 + x] != ".":
                board[y * 8 + x] = "."
                captured = True
            x, y = x + dc, y + dr
        if piece.islower() and y1 == _crown_row(piece):
            piece = piece.upper()
    x, y = squares[-1]
    board[y * 8 + x] = piece
    return board, captured, cells[r * 8 + c].islower()


def _analyse_checkers(moves: list[str]) -> Analysis:
    cells = initial_checkers()
    seen: dict[str, int] = {}
    kings_only = 0
    side = "w"
    for move in moves:
        if move not in _checkers_moves(cells, side):
            raise ValueError(f"illegal move {move}")
        cells, captured, man_moved = _play_checkers(cells, move)
        kings_only = 0 if captured or man_moved else kings_only + 1
        side = "b" if side == "w" else "w"
        key = side + "".join(cells)
        seen[key] = seen.get(key, 0) + 1
    turn: Side = "white" if side == "w" else "black"
    legal = _checkers_moves(cells, side)
    outcome = None
    if not legal:
        outcome = Outcome("black" if side == "w" else "white", "no_moves")
    elif seen.get(side + "".join(cells), 0) >= 3:
        outcome = Outcome("draw", "repetition")
    elif kings_only >= KINGS_ONLY_DRAW_PLIES:
        outcome = Outcome("draw", "kings_only")
    return Analysis("".join(cells), turn, [] if outcome else legal, outcome, tuple(moves))
