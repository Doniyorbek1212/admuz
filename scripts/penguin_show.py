"""UZARO v2 show: penguin (tier 1, 96 f = 4 s).

A penguin pops in with a puff of ice sparkles mid-waddle, flops onto its belly and slides across in a spray of ice
sparkles, pushes itself back up, flaps its flippers proudly and pops out again. The file's Walk, Fall, Slide and Idle takes are cross-faded on the NLA (the get-up is the
Fall take reversed); the walk speed is measured from a planted foot; the proud flaps are hand keys combined on top.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import clipshow as cs  # noqa: E402
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R  # noqa: E402

ID = "penguin"
TOTAL = 96
SIZE = 2.6
GROUND_Z = -2.4
YAW = R(68)                                    # beak (-Y) turned to travel right and a little toward the lens
FOOT = "Foot_l_017"
FLIPPERS = ("Flipper1_l_010", "Flipper1_r_012")
FLOP, SLIDE, RISE, PROUD = 22, 40, 62, 78
SLIDE_V = 0.11


def plan(walk_v):
    return [
        cs.Take("Walk", 1, (0, 24), repeat=1.0, speed=walk_v),
        cs.Take("Fall", FLOP, (22, 45), blend=5, speed=walk_v * 1.6),
        cs.Take("Slide", SLIDE - 2, (0, 15), repeat=(RISE - SLIDE + 4) / 15, blend=4, speed=SLIDE_V),
        cs.Take("Fall", RISE, (22, 45), blend=4, reverse=True, speed=0.02),
        cs.Take("Iddle", PROUD - 2, (0, 20), blend=6),
    ]


def flap_keys():
    """Both flippers lift and beat four times, then fold back."""
    out = {}
    for n, b in enumerate(FLIPPERS):
        s = 1 if n == 0 else -1
        ks = [(PROUD, "Y", 0.0)]
        for i in range(4):
            ks.append((PROUD + 3 + 3 * i, "Y", s * (48.0 if i % 2 == 0 else 22.0)))
        ks.append((PROUD + 17, "Y", 0.0))
        out[b] = ks
    return out


def sparkles(sc, root):
    mat = fx.fade_material("IceSpark", (0.75, 0.9, 1.0), 9.0)
    em = fx.particle_burst(sc, "Ice", fx.point_mesh("IceSrc", 0.25), mat, 260, (SLIDE, RISE), 16, 0.025, 1.4, rand=1.0,
                           align=(0.0, 0.0, 1.6), damping=0.15, gravity=0.35)
    em.parent = root
    em.location = (0.0, 0.0, 0.1)
    return em


def build_show(sc, opts):
    root, arm, meshes = cs.load(ID, SIZE)
    v = cs.foot_speed(sc, arm, "Walk", FOOT)
    seq = cs.sequence(arm, plan(v))
    cs.travel(root, TOTAL, YAW, seq, SLIDE, (-0.6, 0.4))
    cs.overlay(arm, "PenguinFlaps", flap_keys())
    cs.lift_to(sc, root, meshes, GROUND_Z, 10)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.9, hdri="sunrise.exr", lights=0.85, fog=(2.0, 6), streak=8.0)
    sh.shadow_catcher(sc, GROUND_Z, 40)
    sparkles(sc, root)
    fx.pop(sc, root, (1, 9), (88, TOTAL - 1), rgb=(0.75, 0.9, 1.0))
    sh.screen_extent(sc, cam, meshes, (9, FLOP, SLIDE + 10, RISE, PROUD + 8, 88))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Standing, flapping: two beats per loop, closing on the folded pose."""
    root, arm, meshes = cs.load(ID, SIZE)
    cam = stage.setup_icon(sc, opts["samples"], world=0.9, hdri="sunrise.exr", lights=0.85, fog=(2.0, 6), streak=8.0)
    root.rotation_euler = (0.0, 0.0, R(25))
    n = stage.ICON_N
    cs.sequence(arm, [cs.Take("Iddle", 0, (0, 30), blend=0)])
    keys = {}
    for i, b in enumerate(FLIPPERS):
        s = 1 if i == 0 else -1
        keys[b] = [(0, "Y", 0.0), (5, "Y", s * 45.0), (10, "Y", s * 18.0), (15, "Y", s * 45.0), (22, "Y", 0.0), (n, "Y", 0.0)]
    cs.overlay(arm, "IconFlaps", keys)
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.15)
    sh.shadow_catcher(sc, gc.world_bbox(meshes)[0].z, 30)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
