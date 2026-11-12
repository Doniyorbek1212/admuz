"""UZARO v2 show: horse (tier 2, 132 f = 5.5 s).

A stallion gallops in from the left kicking up dust, pulls up at centre, rears with its forelegs pawing, neighs
(head up, ears back), drops and gallops out to the right. Tail and head follow through; dust is particles.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import animal  # noqa: E402
import gift_common as gc  # noqa: E402
import quadruped as qp  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, env, interp  # noqa: E402

ID = "horse"
TOTAL = 132
SIZE = 6.0
HEADING = R(90 - 18)      # nose (-Y in file) screen-right, turned toward the camera
GROUND_Z = -3.0
CYCLE_DIST = 7.0
GAIT = qp.Gait(cycle_dist=CYCLE_DIST, duty=0.42, lift=0.75, bob=0.16, hind_flex=35.0, fore_flex=70.0)
# path along screen X
TRAVEL = [(1, -10.5), (30, -1.6), (46, -0.2), (98, 0.0), (112, 2.4), (TOTAL, 12.0)]
REAR = (52, 72, 88, 100)  # up start, top, hold end, landed
NEIGH_F = 70
JOINTS = {
    "spine": [(0, 1.6, 0.7), (0, 0.45, 0.72), (0, -0.75, 0.82)],
    "neck": [(0, -1.1, 0.95), (0, -1.65, 1.45), (0, -2.15, 2.05)],
    "head": [(0, -2.3, 2.15), (0, -2.87, 0.95)],
    "ear": [(0.14, -2.4, 2.22), (0.14, -2.47, 2.65)],
    "tail": [(0, 2.3, 1.1), (0, 2.65, 0.3), (0, 2.72, -0.6), (0, 2.72, -1.8)],
    "hind": [(0.38, 1.5, 0.65), (0.38, 1.3, -0.2), (0.38, 2.1, -0.97), (0.38, 2.05, -2.0), (0.38, 1.85, -2.33)],
    "fore": [(0.38, -0.98, 0.35), (0.38, -0.92, -0.4), (0.38, -0.92, -1.05), (0.38, -0.92, -2.0), (0.38, -1.1, -2.33)],
}
X, Z = animal.X, animal.Z


def rear_angle(f):
    return -48.0 * env(f, REAR[0], REAR[1]) * (1 - env(f, REAR[2], REAR[3]))


def gallop_amp(f):
    return (1 - env(f, 36, 50)) + env(f, 100, 108)


def animate(root, arm, mover, total=TOTAL):
    frames = range(1, total + 1)
    dist = 0.0
    prev = interp(TRAVEL, 0)
    bobs = {}
    for f in frames:
        x = interp(TRAVEL, f)
        dist += abs(x - prev) + 0.04 * gallop_amp(f)
        prev = x
        bobs[f] = mover.legs_at(f, dist, gallop_amp(f))
        a = rear_angle(f)
        up = env(f, REAR[0], REAR[1]) * (1 - env(f, REAR[2], REAR[3]))
        if up > 0.02:     # pawing forelegs overlay the cycle pose while rearing
            for key, ph in (("LF", 0.0), ("RF", 2.2)):
                s = math.sin(f / 2.6 + ph)
                mover.leg(f, key, paw=(0.55 * up + 0.35 * up * s, 0.9 * up + 0.45 * up * s), flex=up * 1.1)
        c = math.cos(2 * math.pi * dist / CYCLE_DIST)
        amp = gallop_amp(f)
        neigh = env(f, NEIGH_F - 6, NEIGH_F) * (1 - env(f, NEIGH_F + 16, NEIGH_F + 24))
        mover.body(f, {
            "spine0": (X, a * 0.55 + 2.5 * amp * c),
            "spine1": (X, a * 0.45 - 3.0 * amp * c),
            "neck0": (X, -a * 0.25 + 5.0 * amp * c - 10 * neigh),
            "neck1": (X, -a * 0.2 - 4.0 * amp * c - 12 * neigh),
            "head": (X, -a * 0.1 + 3.0 * amp * c - 25 * neigh),
            "earL0": (X, 25 * neigh + 10 * (1 - neigh) * amp),
            "earR0": (X, 25 * neigh + 10 * (1 - neigh) * amp),
            "tail0": (X, -18 * amp + 8 * math.sin(f / 3.4) * amp + 26 * up),
            "tail1": (X, -14 * amp + 8 * math.sin(f / 3.4 - 0.9) + 18 * up),
            "tail2": (X, -8 * amp + 9 * math.sin(f / 3.4 - 1.8)),
        })
    stage.key_path(root, frames, lambda f: (interp(TRAVEL, f), 0.0, GROUND_Z + 2.33 + bobs[f] + 0.15 * gallop_amp(f) * abs(math.sin(f / 3.82))))


def dust(sc, root):
    """Puffs kicked at the hooves while moving fast, and a big one on landing."""
    for name, n, frames, rand, loc in (("Run", 420, (1, 46), 1.0, (0, 0, 0)), ("Land", 260, (REAR[3] - 2, REAR[3] + 6), 1.6, (0, 0, 0)), ("Out", 200, (100, 124), 1.0, (0, 0, 0))):
        mat = fx.fade_material(f"Dust{name}", (0.78, 0.64, 0.45), 1.1, 0.14, 1.2)
        em = fx.particle_burst(sc, f"Dust{name}", fx.ring_mesh(f"Dust{name}R", 1.3, 0.05, 32), mat, n, frames, 22, 0.32, 0.4, rand=rand,
                               damping=0.15, gravity=-0.02, location=loc)
        em.parent = root
        em.location = (0, 0, -2.25)


def load(sc):
    root, model, objs, meshes = stage.load("horse", SIZE)
    arm = animal.build(sc, "Stallion", JOINTS, meshes, power=7.0)
    wrap = bpy.data.objects.new("Heading", None)
    sc.collection.objects.link(wrap)
    wrap.parent = root
    wrap.rotation_euler = (0, 0, HEADING)
    arm.parent = wrap
    for m in meshes:
        for s in m.data.materials:
            stage.shiny(s, roughness=0.42, sheen=0.5)
    return root, arm, meshes


def build_show(sc, opts):
    root, arm, meshes = load(sc)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.8, follow=root, lights=0.9, fog=(1.7, 6), streak=8.0)
    e = R(6)
    cam.location, cam.rotation_euler = (0.0, -gc.CAM_DIST * math.cos(e), gc.CAM_DIST * math.sin(e)), (R(90) - e, 0, 0)
    sh.shadow_catcher(sc, GROUND_Z, 50)
    mover = animal.Mover(arm, GAIT, animal.GALLOP_PHASES)
    animate(root, arm, mover)
    dust(sc, root)
    sh.camera_shake(cam, REAR[3] - 1, 12, amp=0.05, rot_deg=0.3, seed=9)
    sh.screen_extent(sc, cam, meshes, (1, 46, REAR[1], TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Reared stallion, forelegs pawing: seamless with integer harmonics of the loop."""
    root, arm, meshes = load(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=0.8, follow=root, lights=0.9, fog=(1.7, 6), streak=8.0)
    n = stage.ICON_N
    mover = animal.Mover(arm, GAIT, animal.GALLOP_PHASES)
    for f in range(0, n + 1):
        w = 2 * math.pi * f / n
        mover.legs_at(f, 0.0, 0.0)
        for key, ph in (("LF", 0.0), ("RF", 2.2)):
            s = math.sin(2 * w + ph)
            mover.leg(f, key, paw=(0.55 + 0.35 * s, 0.9 + 0.45 * s), flex=1.1)
        mover.body(f, {"spine0": (X, -26.0 + 1.5 * math.sin(w)), "spine1": (X, -22.0 + 1.5 * math.sin(w)), "neck0": (X, 12), "neck1": (X, 10 + 3 * math.sin(w)),
                       "head": (X, -15 + 5 * math.sin(w + 1)), "tail0": (X, 20 + 6 * math.sin(w)), "tail1": (X, 14 + 8 * math.sin(w - 1)), "tail2": (X, 9 * math.sin(w - 2))})
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.12)
    _ = (Vector, Z)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
