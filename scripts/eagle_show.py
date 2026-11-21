"""UZARO v2 show: eagle (tier 2, 120 f = 5 s).

The eagle folds and dives from the top left, flares at centre with wings thrown wide toward camera, beak open in a
scream, then beats its way up and out to the right. Autorig on the spread-pose scan: wing chain, neck, jaw, tail, legs.
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import autorig  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, env, interp  # noqa: E402

ID = "eagle"
TOTAL = 120
SIZE = 8.0
K = 0.86
X, Y, Z = (1, 0, 0), (0, 1, 0), (0, 0, 1)
PATH = [(1, (-7.5, 3.0, 11.0)), (26, (-3.0, 1.0, 4.2)), (46, (-0.2, -1.5, -0.6)), (60, (0.0, -2.0, -0.2)), (78, (0.3, -1.4, 0.6)), (TOTAL, (8.0, 3.0, 9.5))]
PITCH = [(1, 62.0), (34, 66.0), (46, 18.0), (54, -28.0), (72, -24.0), (84, -8.0), (TOTAL, 8.0)]
YAW = [(1, 48.0), (34, 44.0), (54, 24.0), (74, 18.0), (92, 58.0), (TOTAL, 66.0)]
ROLL = [(1, 0.0), (30, 8.0), (54, 0.0), (76, 0.0), (92, -18.0), (TOTAL, -8.0)]
FOLD = (1, 34, 48)        # folded until 34, fully spread by 48
SCREAM = (54, 58, 70, 76)
FLAP_FROM = 76
SIDES = (("L", 1.0), ("R", -1.0))


def v(*a):
    return Vector(a)


def bones():
    out = [
        ("root", None, v(0, 0.2, 0.3), v(0, 0.45, 0.3)),
        ("spine0", "root", v(0, 0.8, 0.28), v(0, -0.7, 0.35)),
        ("neck0", "spine0", v(0, -0.7, 0.35), v(0, -1.25, 0.4)),
        ("head", "neck0", v(0, -1.25, 0.4), v(0, -2.1, 0.22)),
        ("jaw", "head", v(0, -1.72, 0.26), v(0, -2.08, 0.14)),
        ("tail0", "spine0", v(0, 0.8, 0.26), v(0, 1.4, 0.2)),
        ("tail1", "tail0", v(0, 1.4, 0.2), v(0, 1.95, 0.12)),
    ]
    for side, s in SIDES:
        out += [
            (f"wing{side}0", "spine0", v(0.28 * s, -0.2, 0.35), v(1.4 * s, -0.35, 0.45)),
            (f"wing{side}1", f"wing{side}0", v(1.4 * s, -0.35, 0.45), v(2.5 * s, -0.95, 0.52)),
            (f"wing{side}2", f"wing{side}1", v(2.5 * s, -0.95, 0.52), v(3.9 * s, -1.5, 0.56)),
            (f"leg{side}", "spine0", v(0.25 * s, 0.45, 0.0), v(0.3 * s, 0.56, -0.42)),
        ]
    return out


def limits():
    lim = {
        "root": lambda c: c[:, 0] * 0.0,
        "jaw": lambda c: ((c[:, 1] < -1.7) & (c[:, 2] < 0.2) & (abs(c[:, 0]) < 0.2)) * 1.0,
        "head": lambda c: (abs(c[:, 0]) < 0.42) * 1.0,
        "neck0": lambda c: (abs(c[:, 0]) < 0.45) * 1.0,
        "tail0": lambda c: (abs(c[:, 0]) < 0.75) * (c[:, 1] > 0.6),
        "tail1": lambda c: (abs(c[:, 0]) < 0.75) * (c[:, 1] > 0.6),
    }
    for side, s in SIDES:
        for i in range(3):
            lim[f"wing{side}{i}"] = lambda c, s=s: (c[:, 0] * s > 0.15) * (c[:, 1] < 1.3)
        lim[f"leg{side}"] = lambda c, s=s: (c[:, 0] * s > 0.0) * (c[:, 2] < 0.02) * (abs(c[:, 0]) < 0.55)
    return lim


def load(sc):
    root, model, objs, meshes = stage.load(ID, SIZE, strip_rig=True)
    autorig.bake_world(meshes)
    arm = autorig.add_rig(sc, "Eagle", bones(), meshes, power=7.0, limits=limits())
    arm.parent = root
    root.scale = (K, K, K)
    root.rotation_mode = "XYZ"
    return root, arm, meshes


def pose_frame(pose, f, flap, fold, scream, tail_fan=0.0):
    """flap: signed -1..1 (down positive); fold: 0 spread, 1 tucked for the stoop; scream: 0..1."""
    spec = {
        "spine0": (X, -4.0 * flap),
        "neck0": [(X, 12.0 * scream + 8.0 * fold)],
        "head": [(X, 16.0 * scream + 10.0 * fold), (Y, 6.0 * scream * math.sin(f / 2.2))],
        "jaw": (X, 26.0 * scream),
        "tail0": (X, -10.0 * fold + 14.0 * (1 - fold) * abs(flap) + 10.0 * scream),
        "tail1": (X, 6.0 * flap),
    }
    for side, s in SIDES:
        d0 = 26.0 * flap * (1 - fold)
        d1 = 22.0 * math.sin(flap * 1.2) * (1 - fold)
        d2 = 26.0 * flap * (1 - fold) - 14.0 * abs(flap)
        spec[f"wing{side}0"] = [(Z, s * 66.0 * fold), (Y, s * (d0 - 14.0 * fold))]
        spec[f"wing{side}1"] = [(Z, -s * 118.0 * fold), (Y, s * d1)]
        spec[f"wing{side}2"] = [(Z, s * 92.0 * fold), (Y, s * d2)]
        spec[f"leg{side}"] = (X, 30.0 * fold - 62.0 * scream)
    pose.key(f, spec)


def flap_at(f):
    """Beats speed up out of the flare; one big downbeat holds the scream pose open."""
    if f < FLAP_FROM:
        return 0.32 * math.sin(f / 2.4) * env(f, 46, 54) * 0.5
    return math.sin((f - FLAP_FROM) * 2 * math.pi / 13.0 - 0.6) * env(f, FLAP_FROM, FLAP_FROM + 4)


def animate(root, pose):
    for f in range(1, TOTAL + 1):
        fold = 1 - env(f, FOLD[1], FOLD[2])
        scream = env(f, SCREAM[0], SCREAM[1]) * (1 - env(f, SCREAM[2], SCREAM[3]))
        flap = flap_at(f)
        pose_frame(pose, f, flap, fold, scream)
        x, y, z = interp(PATH, f)
        root.location = (x, y, z + 0.28 * flap * (1 if f >= FLAP_FROM else 0))
        root.keyframe_insert("location", frame=f)
        root.rotation_euler = (R(interp(PITCH, f)), R(interp(ROLL, f)), R(interp(YAW, f)))
        root.keyframe_insert("rotation_euler", frame=f)


def wind(sc, cam):
    """Streaks from the speed of the dive, and feathers torn loose at the flare."""
    mat = stage.pbr("Feather", (0.5, 0.46, 0.4), roughness=0.7)
    em = fx.particle_burst(sc, "Feathers", fx.ring_mesh("FeatherR", 0.9, 0.3, 24), mat, 26, (48, 56), 70, 0.11, 1.6, rand=1.3, damping=0.14, gravity=0.05, location=(0.0, -1.9, -0.2))
    st = em.particle_systems[0].settings
    st.instance_object.data = stage.lathe("FeatherShape", [(0, 0.5), (0.12, 0.3), (0.18, -0.1), (0.07, -0.5), (0, -0.55)], 8)   # flattened below
    st.instance_object.data.transform(Matrix.Scale(0.06, 4, (0, 1, 0)))
    st.instance_object.data.materials.append(mat)
    st.use_rotations, st.rotation_factor_random, st.angular_velocity_mode, st.angular_velocity_factor = True, 1.0, "RAND", 3.0
    return em


def build_show(sc, opts):
    root, arm, meshes = load(sc)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=1.0, follow=root, lights=0.9, fog=(1.9, 6), streak=8.0, shutter=0.6)
    pose = autorig.Pose(arm)
    animate(root, pose)
    wind(sc, cam)
    sh.camera_shake(cam, 50, 12, amp=0.04, rot_deg=0.25, seed=5)
    sh.screen_extent(sc, cam, meshes, (1, 30, 46, 60, 90, TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Hovering front-on, wings beating on an integer number of cycles."""
    root, arm, meshes = load(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=1.0, follow=root, lights=0.9, fog=(1.9, 6), streak=8.0)
    pose = autorig.Pose(arm)
    root.rotation_euler = (R(-22), 0, R(12))
    n = stage.ICON_N
    for f in range(0, n + 1):
        w = 2 * math.pi * f / n
        flap = math.sin(2 * w)
        pose_frame(pose, f, flap * 0.8, 0.0, 0.5 + 0.5 * math.sin(w))
        root.location = (0.0, 0.0, -0.3 * flap)
        root.keyframe_insert("location", frame=f)
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.2)
    bpy.context.view_layer.update()


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
