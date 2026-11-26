"""UZARO v2 show: panda (tier 1, 96 f = 4 s).

A panda pops in with a puff of sparkles mid-waddle, sits down and chews a bamboo stalk, blinks, waves a paw, and
pops out again (its walk is too short to come on from the edge in four seconds). The file's Walk and
Sit_Eat_Bamboo takes are cross-faded on the NLA; walk speed is measured from a planted foot so it does not slide.
Blink and wave are hand keys combined on top. Fur is the model's own fur cards (no hair sim).
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

ID = "panda"
TOTAL = 96
SIZE = 3.6
GROUND_Z = -2.6
YAW = R(62)                                   # nose (-Y) turned to walk right and a little toward the lens
WALK, SIT = "02_Walk", "04_Sit_Eat"
FOOT = "DEF-foot.L_16"
SIT_AT = 34
LIDS = ("DEF-lid.upper.L_72", "DEF-lid.upper.R_74")
ARM = "DEF-upper_arm.R_121"


def load():
    root, arm, meshes = cs.load(ID, SIZE)
    for m in meshes:
        for mat in m.data.materials:
            if mat and mat.use_nodes and any(n.type == "BSDF_PRINCIPLED" for n in mat.node_tree.nodes):
                stage.shiny(mat, sheen=0.4)
    return root, arm, meshes


def wave_keys(start):
    """Lift the right arm and rock it twice, then lower it."""
    ks = [(start, "X", 0.0), (start + 6, "X", -55.0)]
    for i in range(4):
        ks.append((start + 9 + 4 * i, "X", -55.0 + (12.0 if i % 2 else -12.0)))
    ks += [(start + 26, "X", -55.0), (start + 32, "X", 0.0)]
    return ks


def build_show(sc, opts):
    root, arm, meshes = load()
    v = cs.foot_speed(sc, arm, WALK, FOOT)
    plan = [cs.Take(WALK, 1, repeat=SIT_AT / 26 + 0.5, speed=v), cs.Take(SIT, SIT_AT - 6, (0, 70), blend=10)]
    seq = cs.sequence(arm, plan)
    cs.travel(root, TOTAL, YAW, seq, SIT_AT + 4, (0.2, 0.4))
    keys = cs.blink(LIDS, (52, 80))
    keys[ARM] = wave_keys(54)
    cs.overlay(arm, "PandaExtras", keys)
    cs.lift_to(sc, root, meshes, GROUND_Z, 12)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.9, hdri="sunrise.exr", lights=0.85, fog=(2.0, 6), streak=10.0)
    sh.shadow_catcher(sc, GROUND_Z, 40)
    fx.pop(sc, root, (1, 10), (86, TOTAL - 1), rgb=(1.0, 0.9, 0.75), size=1.2)
    sh.screen_extent(sc, cam, meshes, (10, 20, SIT_AT + 4, 70, 86))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Sitting and chewing: a short stretch of the eat take played forward then back, so the loop closes."""
    root, arm, meshes = load()
    cam = stage.setup_icon(sc, opts["samples"], world=0.9, hdri="sunrise.exr", lights=0.85, fog=(2.0, 6), streak=8.0)
    root.rotation_euler = (0.0, 0.0, R(30))
    n = stage.ICON_N
    cs.sequence(arm, [cs.Take(SIT, 0, (20, 34), blend=0), cs.Take(SIT, n / 2, (20, 34), blend=0, reverse=True)])
    for tr in arm.animation_data.nla_tracks:
        for s in tr.strips:
            s.frame_end = s.frame_start + n / 2         # fill the half-loop exactly
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.1)
    sh.shadow_catcher(sc, gc.world_bbox(meshes)[0].z, 30)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
