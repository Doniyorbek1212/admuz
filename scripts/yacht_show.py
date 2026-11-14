"""UZARO v2 show: yacht (tier 2, 120 f = 5 s).

A yacht crosses from left to right on a patch of real Ocean-modifier water that fades to alpha around it, pitching on
the swell, throwing a bow wave of spray, leaving a churned wake; a cloth pennant streams from the mast.
Bow spray is droplets and mist particles, not a fluid sim: a moving FLIP domain costs far more than it shows at 540 px.
"""
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
import water  # noqa: E402
from stage import R, interp  # noqa: E402

ID = "yacht"
TOTAL = 120
SIZE = 6.0
K = 1.22
WATER_Z = -2.4
LINE_Z = -0.6           # waterline in the file at SIZE
TRAVEL = [(1, -10.0), (TOTAL, 10.0)]
YAW = R(90 - 24)        # bow to screen right, a little toward the camera
BOW = (0.0, -2.75, -0.45)
MAST_TOP = (0.0, 0.1, 1.1)


def x_at(f):
    return -10.0 + 20.0 * (f - 1) / (TOTAL - 1)


def pitch_at(f):
    return 2.4 * math.sin(f / 9.0)


def heave_at(f):
    return 0.1 * math.sin(f / 9.0 - 0.7)


def spray(sc, hull):
    """Bow wave: droplets flung sideways and up, plus soft mist hanging behind them. Emitters ride the hull."""
    drop = stage.pbr("Droplet", (0.86, 0.93, 1.0), roughness=0.08, coat=1.0, emission=(0.6, 0.75, 0.9), strength=0.5)
    mist = fx.fade_material("Mist", (0.9, 0.95, 1.0), 1.2, 0.1, 1.0)
    for name, n, sign in (("Sea1", 900, 1.0), ("Sea2", 900, -1.0)):
        em = fx.particle_burst(sc, name, gc.ico_mesh(f"{name}E", 0.16, 1), drop, n, (1, TOTAL), 20, 0.026, 1.3, rand=1.2,
                               align=(sign * 2.6, -1.6, 2.5), gravity=0.45, location=BOW)
        em.parent = hull
    em = fx.particle_burst(sc, "Mist", gc.ico_mesh("MistE", 0.2, 1), mist, 420, (1, TOTAL), 24, 0.4, 0.5, rand=0.8, align=(0, 0.8, 0.7), damping=0.1, location=BOW)
    em.parent = hull
    wake = fx.fade_material("WakeMist", (0.88, 0.94, 0.98), 1.0, 0.1, 1.2)
    em = fx.particle_burst(sc, "Stern", gc.ico_mesh("SternE", 0.34, 1), wake, 240, (1, TOTAL), 22, 0.32, 0.3, rand=0.6, align=(0, 1.0, 0.2), damping=0.1, location=(0, 2.6, -0.5))
    em.parent = hull


def pennant(sc, hull):
    """Cloth flag on the mast, streaming aft (+Y of the hull)."""
    ob = stage.flag(sc, "Pennant", hull, (MAST_TOP[0], MAST_TOP[1] + 0.05, MAST_TOP[2]), 0.72, 0.3, (0.38, 0.008, 0.012), TOTAL, yaw=R(90))
    stage.wind()
    return ob


def build_show(sc, opts):
    root, model, objs, meshes = stage.load(ID, SIZE)
    root.rotation_mode = "XYZ"
    root.scale = (K, K, K)
    frames = range(1, TOTAL + 1)
    z0 = WATER_Z - LINE_Z * K
    stage.key_path(root, frames, lambda f: (x_at(f), 0.0, z0 + heave_at(f)))
    # pitch about the hull's lateral axis: bow rides up and slams; roll gentle
    stage.key_path(root, frames, lambda f: (R(pitch_at(f) * math.cos(YAW)), R(pitch_at(f) * math.sin(YAW) + 1.5 * math.sin(f / 14.0)), YAW), path="rotation_euler")
    for m in meshes:
        for s in m.data.materials:
            if s and s.use_nodes and any(n.type == "BSDF_PRINCIPLED" for n in s.node_tree.nodes):
                stage.shiny(s, coat=0.25)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=1.0, hdri="sunrise.exr", follow=root, lights=0.8, fog=(2.0, 6), streak=9.0)
    e = R(9)
    cam.location, cam.rotation_euler = (0.0, -gc.CAM_DIST * math.cos(e), gc.CAM_DIST * math.sin(e) - 0.5), (R(90) - e, 0, 0)
    # patch centre trails the hull: calm water ahead of the bow read as a teal beam from the ship
    bow_x = [(f, x_at(f) - 1.3) for f in (1, TOTAL)]
    mat = water.material("Water", 5.2, 3.8, wake=True, center_keys=bow_x, wake_y=0.0)
    for fc in mat.node_tree.animation_data.action.fcurves:
        for kp in fc.keyframe_points:
            kp.interpolation = "LINEAR"
    water.patch(sc, "Sea", WATER_Z, TOTAL, mat, span=34.0)
    spray(sc, root)
    pennant(sc, root)
    sh.screen_extent(sc, cam, meshes, (1, 60, TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Riding swell at a fixed spot: everything on integer harmonics; the water patch is replaced by a small round one."""
    root, model, objs, meshes = stage.load(ID, SIZE)
    root.rotation_mode = "XYZ"
    cam = stage.setup_icon(sc, opts["samples"], world=1.0, follow=root, lights=0.8, fog=(2.0, 6), streak=9.0)
    n = stage.ICON_N
    z0 = -LINE_Z
    for f in range(0, n + 1):
        w = 2 * math.pi * f / n
        root.location = (0, 0, z0 + 0.08 * math.sin(w))
        root.rotation_euler = (R(2.5 * math.sin(w) * math.cos(YAW)), R(2.5 * math.sin(w) * math.sin(YAW)), YAW)
        root.keyframe_insert("location", frame=f)
        root.keyframe_insert("rotation_euler", frame=f)
    mat = water.material("Water", 4.0, 4.0)
    sea = water.patch(sc, "Sea", 0.0, n, mat, span=20.0, res=8)
    sea.animation_data_clear()
    # shortcut: frozen ocean, a loop would need matching FFT phases. Swell is carried by the hull and the cloth-free spray.
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.25)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
