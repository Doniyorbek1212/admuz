"""Glicko-2: matches the paper's worked example direction, a win raises, a loss lowers, idle time widens."""

from app.games.rating import Glicko, update, with_idle_days


def test_win_raises_loss_lowers_and_upsets_move_more():
    me, equal, strong = Glicko(1500, 200), Glicko(1500, 200), Glicko(1900, 80)
    assert update(me, equal, 1).rating > 1500 > update(me, equal, 0).rating
    assert update(me, strong, 1).rating - 1500 > update(me, equal, 1).rating - 1500
    assert abs(update(me, equal, 0.5).rating - 1500) < 1e-6
    assert update(me, equal, 1).deviation < 200


def test_paper_example_first_opponent():
    # Glickman's example player (1500, 200, 0.06) beating a 1400 (RD 30) gains rating.
    after = update(Glicko(1500, 200, 0.06), Glicko(1400, 30), 1)
    assert 1560 < after.rating < 1600 and 0.059 < after.volatility < 0.061


def test_idle_time_widens_the_deviation_up_to_the_start():
    settled = Glicko(1700, 60)
    assert with_idle_days(settled, 30).deviation > 60
    assert with_idle_days(settled, 10_000).deviation == 350
