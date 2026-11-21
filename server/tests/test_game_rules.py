"""Game rules: chess through python-chess, Russian checkers by our own move generator."""

import pytest

from app.games import rules
from app.games.models import Game
from app.games.rules import analyse
from app.games.service import scores_points


def _cells(**pieces: str) -> list[str]:
    cells = ["."] * 64
    for square, piece in pieces.items():
        c, r = rules._parse(square)
        cells[r * 8 + c] = piece
    return cells


def test_chess_start_mate_and_illegal():
    start = analyse("chess", [])
    assert start.turn == "white" and len(start.legal) == 20 and start.outcome is None
    mate = analyse("chess", ["f2f3", "e7e5", "g2g4", "d8h4"])
    assert mate.outcome == rules.Outcome("black", "checkmate") and mate.legal == []
    with pytest.raises(ValueError):
        analyse("chess", ["e2e5"])


def test_chess_threefold_repetition_ends_the_game():
    dance = ["g1f3", "g8f6", "f3g1", "f6g8"] * 2
    assert analyse("chess", dance).outcome == rules.Outcome("draw", "repetition")
    # One ply earlier the position has only been seen twice: the game goes on.
    assert analyse("chess", dance[:-1]).outcome is None


def test_short_arena_games_score_no_points():
    def game(plies: int, winner: str, reason: str) -> Game:
        return Game(moves=["e2e4"] * plies, winner=winner, reason=reason)

    assert not scores_points(game(2, "white", "resign"))
    assert scores_points(game(10, "white", "resign"))
    assert not scores_points(game(20, "draw", "agreement"))
    assert scores_points(game(20, "draw", "repetition"))
    assert scores_points(game(40, "draw", "agreement"))


def test_checkers_start_has_seven_moves_for_white():
    start = analyse("checkers", [])
    assert start.turn == "white" and sorted(start.legal) == sorted(
        ["a3-b4", "c3-b4", "c3-d4", "e3-d4", "e3-f4", "g3-f4", "g3-h4"])
    assert start.position[:8] == "w.w.w.w."  # a1 is a dark square


def test_checkers_capture_is_compulsory_and_men_capture_backwards():
    cells = _cells(c3="w", d4="b", f2="b", h8="b")
    assert rules._checkers_moves(cells, "w") == ["c3:e5"]
    back = _cells(e5="w", d4="b", a7="b")
    assert rules._checkers_moves(back, "w") == ["e5:c3"]


def test_checkers_multi_capture_and_crowning_mid_capture():
    cells = _cells(a1="w", b2="b", d4="b", h8="b")
    assert rules._checkers_moves(cells, "w") == ["a1:c3:e5"]
    # The man is crowned on d8 and goes on capturing as a king along the long diagonal.
    crown = _cells(e5="w", d6="b", e7="b", a1="b")
    assert "e5:c7:f8" not in rules._checkers_moves(crown, "w")
    assert any(m.startswith("e5:c7:d8") or m.startswith("e5:c7") for m in rules._checkers_moves(crown, "w"))


def test_checkers_flying_king_and_the_continue_rule():
    cells = _cells(a1="W", c3="b", f4="b", h8="b")
    moves = rules._checkers_moves(cells, "w")
    # After c3 the king must stop on e5 (from there f4 can be taken), not on d4 or past it.
    assert sorted(moves) == ["a1:e5:g3", "a1:e5:h2"]
    board, captured, man_moved = rules._play_checkers(cells, "a1:e5:h2")
    assert captured and not man_moved and board[1 * 8 + 7] == "W" and board.count("b") == 1


def test_checkers_no_moves_loses():
    cells = _cells(a1="w", b2="b", c3="b")  # the white man is blocked and cannot capture
    assert rules._checkers_moves(cells, "w") == []
