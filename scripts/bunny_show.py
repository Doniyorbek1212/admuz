"""UZARO v2 show: bunny (tier 1, 96 f = 4 s).

A rabbit hops in from the left, stops and sits, twitches its nose, flops one ear and tilts its head, then hops away to
the right. The file has one 10-frame hop cycle played in place: it is slowed to a 15-frame hop, cut to the crouch
(its first frame) for the sit, and the root travels at the speed measured from a planted hind foot. The nose, ear and
head moves are hand keys combined on top; a little glitter puffs up where it stops.
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

ID = "bunny"
TOTAL = 96
SIZE = 4.0
GROUND_Z = -2.6
YAW = R(64)                                    # nose (-Y) turned to hop right and a little toward the lens
TAKE = "Take 001"
HOP = (0, 10)
SLOW = 1.5                                     # hop stretched to 15 frames
FOOT = "backToes_L_041"
STOP, GO = 34, 70                              # sits from STOP, hops off from GO
NOSE, HEAD, EAR_L = "Nose_M_021", "Head_M_020", "Ear_L_028"


def cute_keys(a):
    """From frame a: nose twitches, head tilts, the left ear flops down (+Z on this rig) and springs back up."""
    nose = [(a + 2 * i, "Z", (7.0 if i % 2 else -5.0)) for i in range(10)] + [(a + 20, "Z", 0.0)]
    head = [(a, "Y", 0.0), (a + 8, "Y", 14.0), (a + 26, "Y", 14.0), (a + 34, "Y", 0.0)]
    ear = [(a + 4, "Z", 0.0), (a + 9, "Z", 34.0), (a + 12, "Z", 24.0), (a + 22, "Z", 28.0), (a + 28, "Z", 0.0)]
    return {NOSE: nose, HEAD: head, EAR_L: ear}


def slow(seq, k):
    """Stretch the hop strips in time (scale also moves their ends)."""
    for tk, s in seq:
        if tk.speed:
            s.scale = k


def glitter(sc, root):
    mat = fx.fade_material("Glitter", (1.0, 0.75, 0.85), 7.0)
    em = fx.particle_burst(sc, "Glitter", fx.point_mesh("GlitterSrc", 0.3), mat, 90, (STOP + 2, STOP + 8), 22, 0.022, 1.1,
                           rand=1.0, align=(0.0, 0.0, 1.2), damping=0.2, gravity=0.3)
    em.parent = root
    em.location = (0.0, 0.0, 0.1)
    return em


def build_show(sc, opts):
    root, arm, meshes = cs.load(ID, SIZE)
    v = cs.foot_speed(sc, arm, TAKE, FOOT, HOP) / SLOW
    hold = cs.Take(TAKE, STOP - 2, (0, 0.2), repeat=(GO - STOP + 4) / 0.2, blend=4)
    seq = cs.sequence(arm, [cs.Take(TAKE, 1, HOP, repeat=STOP / (10 * SLOW) + 0.1, speed=v), hold,
                            cs.Take(TAKE, GO, HOP, repeat=3, blend=3, speed=v)])
    slow(seq, SLOW)
    cs.travel(root, TOTAL, YAW, seq, STOP + 6, (0.0, 0.5))
    cs.overlay(arm, "BunnyCute", cute_keys(STOP + 6))
    cs.lift_to(sc, root, meshes, GROUND_Z, STOP + 10)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.9, hdri="sunrise.exr", lights=0.85, fog=(2.0, 6), streak=8.0)
    sh.shadow_catcher(sc, GROUND_Z, 40)
    glitter(sc, root)
    sh.screen_extent(sc, cam, meshes, (1, 20, STOP + 10, GO + 10, TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Sitting: nose twitch, ear flop and head tilt, back to rest by the last frame."""
    root, arm, meshes = cs.load(ID, SIZE)
    cam = stage.setup_icon(sc, opts["samples"], world=0.9, hdri="sunrise.exr", lights=0.85, fog=(2.0, 6), streak=8.0)
    root.rotation_euler = (0.0, 0.0, R(35))
    n = stage.ICON_N
    cs.sequence(arm, [cs.Take(TAKE, 0, (0, 0.2), blend=0, repeat=(n + 2) / 0.2)])
    keys = {NOSE: [(1 + 2 * i, "Z", (7.0 if i % 2 else -5.0) if 0 < i < 11 else 0.0) for i in range(12)],
            HEAD: [(1, "Y", 0.0), (8, "Y", 14.0), (20, "Y", 14.0), (n - 2, "Y", 0.0)],
            EAR_L: [(2, "Z", 0.0), (7, "Z", 34.0), (10, "Z", 24.0), (19, "Z", 28.0), (n - 3, "Z", 0.0)]}
    cs.overlay(arm, "IconCute", keys)
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.15)
    sh.shadow_catcher(sc, gc.world_bbox(meshes)[0].z, 30)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
