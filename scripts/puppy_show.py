"""UZARO v2 show: puppy (tier 1, 90 f = 3.75 s).

A golden puppy gallops in with ears flopping, crouches and jumps with joy, lands, stands wagging its tail hard with
the tongue bouncing, then gallops out. Ears and tongue are damped springs driven by the body's vertical motion.
"""
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import animal  # noqa: E402
import gift_common as gc  # noqa: E402
import quadruped as qp  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, env, interp  # noqa: E402

ID = "puppy"
TOTAL = 90
SIZE = 6.0
K = 1.05
CENTER_X = 0.13                 # the tail swings the file's box off the body axis
GROUND_Z = -3.0
PAW_Z = -1.9
X, Y, Z = animal.X, animal.Y, animal.Z
HEADING = R(90 - 20)
GAIT = qp.Gait(cycle_dist=5.2, duty=0.42, lift=0.5, bob=0.12, hind_flex=30.0, fore_flex=55.0)
TRAVEL = [(1, -9.6), (28, -1.0), (34, -0.5), (58, 0.5), (72, 0.6), (TOTAL, 10.5)]
CROUCH, TAKEOFF, LAND = 28, 35, 50
JUMP_H = 1.9
RUN_OUT = 72
JOINTS = {
    "spine": [(0, 1.15, 0.45), (0, 0.15, 0.45), (0, -0.9, 0.55)],
    "neck": [(0, -1.15, 0.55), (0, -1.5, 0.95), (0, -1.75, 1.35)],
    "head": [(0, -1.75, 1.35), (0, -2.95, 1.2)],
    "jaw": [(0, -2.15, 1.05), (0, -2.8, 0.82)],
    "tongue": [(0, -2.4, 0.95), (0, -2.75, 0.85), (0, -3.0, 0.72)],
    "ear": [(0.5, -1.95, 1.4), (0.52, -1.92, 1.1), (0.54, -1.88, 0.8)],
    "tail": [(0, 1.3, 0.72), (0, 1.9, 0.72), (0, 2.45, 1.0), (0, 2.7, 1.85)],
    "hind": [(0.5, 0.9, 0.5), (0.5, 1.1, -0.36), (0.5, 1.8, -1.06), (0.5, 1.66, -1.62), (0.5, 1.5, -1.88)],
    "fore": [(0.5, -1.2, 0.5), (0.5, -1.1, -0.36), (0.5, -1.2, -1.37), (0.5, -1.25, -1.65), (0.5, -1.4, -1.88)],
}


def limits():
    lim = animal.side_limits(JOINTS)
    for s, name in ((1.0, "earL"), (-1.0, "earR")):
        for i in range(2):
            lim[f"{name}{i}"] = lambda c, s=s: ((c[:, 0] * s > 0.33) & (c[:, 1] < -1.55) & (c[:, 1] > -2.3) & (c[:, 2] < 1.5)) * 1.0
    for i in range(2):
        lim[f"tongue{i}"] = lambda c: ((abs(c[:, 0]) < 0.25) & (c[:, 1] < -2.25) & (c[:, 2] < 1.02)) * 1.0
    lim["jaw"] = lambda c: ((abs(c[:, 0]) < 0.4) & (c[:, 1] < -2.0) & (c[:, 2] < 1.1)) * 1.0
    for i in range(3):
        lim[f"tail{i}"] = lambda c: (c[:, 1] > 1.2) * (c[:, 2] > 0.3)
    return lim


def load(sc):
    root, model, objs, meshes = stage.load(ID, SIZE)
    model.location.x += CENTER_X
    for m in meshes:
        stage.apply_modifier(m, "DECIMATE", ratio=0.18)
        for s in m.data.materials:
            stage.shiny(s, roughness=0.55, metallic=0.0, sheen=0.7)
    arm = animal.build(sc, "Puppy", JOINTS, meshes, power=8.0, limits=limits())
    wrap = bpy.data.objects.new("Heading", None)
    sc.collection.objects.link(wrap)
    wrap.parent = root
    wrap.rotation_euler = (0, 0, HEADING)
    arm.parent = wrap
    root.scale = (K, K, K)
    return root, arm, meshes


def jump_z(f):
    """Ballistic arc from takeoff to landing plus crouch and landing squash."""
    if TAKEOFF <= f <= LAND:
        t = (f - TAKEOFF) / (LAND - TAKEOFF)
        return JUMP_H * 4 * t * (1 - t)
    return -0.42 * env(f, CROUCH, TAKEOFF - 1) if f < TAKEOFF else -0.4 * env(f, LAND, LAND + 3) * (1 - env(f, LAND + 3, LAND + 10))


def run_amp(f):
    return (1 - env(f, 24, 32)) + env(f, RUN_OUT - 2, RUN_OUT + 6)


def animate(root, mover):
    zs = {f: jump_z(f) for f in range(0, TOTAL + 2)}
    # ear lag: vertical velocity drives the flop, running adds a swing
    ear = stage.spring({f: 16.0 * (zs[f + 1] - zs[f]) / 0.1 + 18.0 * run_amp(f) * abs(math.sin(f / 2.6)) for f in range(1, TOTAL + 1)}, k=0.16, c=0.24)
    tongue = stage.spring({f: 14.0 * (zs[f + 1] - zs[f]) / 0.1 + 12.0 * math.sin(f / 1.7) for f in range(1, TOTAL + 1)}, k=0.2, c=0.2)
    dist, prev = 0.0, interp(TRAVEL, 0)
    for f in range(1, TOTAL + 1):
        x = interp(TRAVEL, f)
        amp = run_amp(f)
        dist += abs(x - prev) / K + 0.03 * amp
        prev = x
        bob = mover.legs_at(f, dist, amp)
        z = zs[f]
        air = env(f, TAKEOFF - 1, TAKEOFF + 2) * (1 - env(f, LAND - 3, LAND))
        crouch = env(f, CROUCH, TAKEOFF - 1) * (1 - env(f, TAKEOFF - 1, TAKEOFF + 1)) + 0.9 * env(f, LAND, LAND + 3) * (1 - env(f, LAND + 3, LAND + 10))
        if air > 0.01:     # legs tuck: fore reach ahead, hind trail
            t = (f - TAKEOFF) / (LAND - TAKEOFF)
            for key, off in (("LF", (0.55, 0.7)), ("RF", (0.75, 0.55)), ("LB", (-0.6, 0.55)), ("RB", (-0.8, 0.45))):
                reach = 0.45 + 0.55 * math.sin(math.pi * t)
                mover.leg(f, key, paw=(off[0] * air * reach, off[1] * air * reach), flex=0.8 * air * reach)
        elif crouch > 0.01:
            for key in ("LF", "RF", "LB", "RB"):
                mover.leg(f, key, paw=(0.0, 0.42 * crouch), flex=0.0)
        wag_on = env(f, 38, 46) * (1 - 0.5 * env(f, RUN_OUT, RUN_OUT + 6))
        wag = math.sin(f * 2 * math.pi / 5.0)
        c = math.cos(2 * math.pi * dist / GAIT.cycle_dist)
        stand = env(f, 54, 60) * (1 - env(f, RUN_OUT - 2, RUN_OUT + 4))
        pant = 0.5 + 0.5 * math.sin(f * 2 * math.pi / 7.0)
        mover.body(f, {
            "spine0": (X, 3.0 * amp * c + 10.0 * air * (0.5 - (f - TAKEOFF) / (LAND - TAKEOFF)) * 2),
            "spine1": [(X, -3.5 * amp * c), (Z, 6.0 * wag * wag_on * 0.35)],
            "neck0": (X, 5.0 * amp * c - 8.0 * air),
            "neck1": (X, -3.0 * amp * c - 6.0 * air),
            "head": [(Z, -18.0 * stand), (X, 3.0 * amp * c - 4.0 * stand), (Y, 10.0 * stand * math.sin(f / 8.0))],
            "jaw": (X, 6.0 + 7.0 * pant),
            "tongue0": (X, tongue[f] * 0.9),
            "tongue1": (X, tongue[f] * 1.3),
            "earL0": [(X, ear[f] * 0.5), (Y, -ear[f] * 0.5)],
            "earL1": (Y, -ear[f] * 0.35),
            "earR0": [(X, ear[f] * 0.5), (Y, ear[f] * 0.5)],
            "earR1": (Y, ear[f] * 0.35),
            "tail0": [(Z, 22.0 * wag * wag_on), (X, -8.0 * amp + 14.0 * air)],
            "tail1": (Z, 26.0 * math.sin(f * 2 * math.pi / 5.0 - 0.9) * wag_on + 5.0 * amp * math.sin(f / 2.6)),
            "tail2": (Z, 30.0 * math.sin(f * 2 * math.pi / 5.0 - 1.8) * wag_on),
        })
        root.location = (x, 0.0, GROUND_Z - PAW_Z * K + (bob + z) * K + 0.12 * amp * abs(math.sin(f / 3.0)))
        root.keyframe_insert("location", frame=f)


def dust(sc, root):
    for name, n, frames in (("Kick", 180, (1, 34)), ("Land", 200, (LAND, LAND + 5)), ("Out", 140, (RUN_OUT, TOTAL - 4))):
        mat = fx.fade_material(f"Dust{name}", (0.82, 0.68, 0.5), 1.0, 0.12, 1.2)
        em = fx.particle_burst(sc, f"Dust{name}", fx.ring_mesh(f"Dust{name}R", 1.0, 0.05, 28), mat, n, frames, 20, 0.42, 0.45, rand=1.0, damping=0.15, gravity=-0.02)
        em.parent = root
        em.location = (0, 0, PAW_Z + 0.05)


def build_show(sc, opts):
    root, arm, meshes = load(sc)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=1.0, follow=root, lights=0.9, fog=(1.8, 5), streak=9.0)
    e = R(5)
    cam.location, cam.rotation_euler = (0.0, -gc.CAM_DIST * math.cos(e), gc.CAM_DIST * math.sin(e)), (R(90) - e, 0, 0)
    sh.shadow_catcher(sc, GROUND_Z, 50)
    mover = animal.Mover(arm, GAIT, animal.GALLOP_PHASES)
    animate(root, mover)
    dust(sc, root)
    sh.camera_shake(cam, LAND, 8, amp=0.03, rot_deg=0.2, seed=4)
    sh.screen_extent(sc, cam, meshes, (1, 30, 43, 60, TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Standing, wagging, panting: all on integer harmonics of the loop."""
    root, arm, meshes = load(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=1.0, follow=root, lights=0.9, fog=(1.8, 5), streak=9.0)
    mover = animal.Mover(arm, GAIT, animal.GALLOP_PHASES)
    n = stage.ICON_N
    for f in range(0, n + 1):
        w = 2 * math.pi * f / n
        wag = math.sin(5 * w)
        pant = 0.5 + 0.5 * math.sin(4 * w)
        mover.legs_at(f, 0.0, 0.0)
        mover.body(f, {
            "spine1": (Z, 2.0 * wag),
            "head": [(Z, -18.0), (X, -4.0 + 2.0 * math.sin(w)), (Y, 8.0 * math.sin(w))],
            "jaw": (X, 6.0 + 7.0 * pant),
            "tongue0": (X, 8.0 * math.sin(4 * w)),
            "tongue1": (X, 12.0 * math.sin(4 * w - 0.8)),
            "earL0": (X, 4.0 * math.sin(2 * w)), "earR0": (X, 4.0 * math.sin(2 * w)),
            "tail0": (Z, 22.0 * wag),
            "tail1": (Z, 26.0 * math.sin(5 * w - 0.9)),
            "tail2": (Z, 30.0 * math.sin(5 * w - 1.8)),
        })
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.12)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
