"""Glicko-2 ratings (as on lichess / chess.com), updated after every rated game.

Each game is its own rating period; the deviation grows back with idle time, so a returning player's rating
moves faster again. Reference: Glickman, "Example of the Glicko-2 system" (2013).
"""

import math
from dataclasses import dataclass

SCALE = 173.7178
TAU = 0.5
START_RATING = 1500.0
START_DEVIATION = 350.0
START_VOLATILITY = 0.06
MIN_DEVIATION = 45.0
# Deviation regained per idle day (lichess-like): about 1 year idle brings an established player back near 350.
DAILY_DRIFT = 0.0025


@dataclass(frozen=True)
class Glicko:
    rating: float = START_RATING
    deviation: float = START_DEVIATION
    volatility: float = START_VOLATILITY


def with_idle_days(player: Glicko, days: float) -> Glicko:
    if days <= 0:
        return player
    phi = player.deviation / SCALE
    grown = math.sqrt(phi * phi + DAILY_DRIFT * days) * SCALE
    return Glicko(player.rating, min(START_DEVIATION, grown), player.volatility)


def _g(phi: float) -> float:
    return 1 / math.sqrt(1 + 3 * phi * phi / math.pi**2)


def update(player: Glicko, opponent: Glicko, score: float) -> Glicko:
    """[score]: 1 win, 0.5 draw, 0 loss for [player]."""
    mu, phi = (player.rating - START_RATING) / SCALE, player.deviation / SCALE
    mu_j, phi_j = (opponent.rating - START_RATING) / SCALE, opponent.deviation / SCALE
    g = _g(phi_j)
    expected = 1 / (1 + math.exp(-g * (mu - mu_j)))
    v = 1 / (g * g * expected * (1 - expected))
    delta = v * g * (score - expected)

    # New volatility by the Illinois algorithm (step 5 of the paper).
    a = math.log(player.volatility**2)

    def f(x: float) -> float:
        ex = math.exp(x)
        return ex * (delta**2 - phi**2 - v - ex) / (2 * (phi**2 + v + ex) ** 2) - (x - a) / TAU**2

    lo = a
    if delta**2 > phi**2 + v:
        hi = math.log(delta**2 - phi**2 - v)
    else:
        k = 1
        while f(a - k * TAU) < 0:
            k += 1
        hi = a - k * TAU
    f_lo, f_hi = f(lo), f(hi)
    for _ in range(100):
        if abs(hi - lo) <= 1e-6:
            break
        mid = lo + (lo - hi) * f_lo / (f_hi - f_lo)
        f_mid = f(mid)
        if f_mid * f_hi <= 0:
            lo, f_lo = hi, f_hi
        else:
            f_lo /= 2
        hi, f_hi = mid, f_mid
    sigma = math.exp(lo / 2)

    phi_star = math.sqrt(phi**2 + sigma**2)
    phi_new = 1 / math.sqrt(1 / phi_star**2 + 1 / v)
    mu_new = mu + phi_new**2 * g * (score - expected)
    return Glicko(
        rating=mu_new * SCALE + START_RATING,
        deviation=max(MIN_DEVIATION, min(START_DEVIATION, phi_new * SCALE)),
        volatility=sigma,
    )


def provisional(player: Glicko) -> bool:
    """Shown with a "?" like lichess until the deviation settles."""
    return player.deviation > 110
