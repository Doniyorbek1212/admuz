"""UZARO v2 show: heart_balloons (tier 1, 90 f = 3.75 s).

Foil heart balloons float up on verlet-simulated strings (the strings react to every sway), one pops into glitter
and its string drops away, the rest drift out of the top.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R  # noqa: E402

ID = "heart_balloons"
TOTAL = 90
POP_F, POP_I = 56, 1
SEGS, SEG_LEN = 14, 0.3
# (x, y, z offset, size, colour)
BALLOONS = [(-1.1, 0.2, 0.2, 1.25, (0.62, 0.012, 0.03)), (1.25, 0.6, 0.9, 1.05, (0.75, 0.05, 0.22)),
            (0.1, -0.5, -0.5, 1.45, (0.7, 0.008, 0.015)), (-1.55, 0.9, 2.1, 0.9, (0.8, 0.42, 0.06)),
            (1.1, 0.0, 2.6, 1.15, (0.66, 0.015, 0.05)), (-0.2, 1.1, 3.0, 0.95, (0.8, 0.18, 0.32))]
RISE = [(1, -14.0), (32, -2.6), (70, -1.4), (TOTAL, 16.0)]
DT = 1.0 / sh.FPS


def balloon_pos(i, f):
    x, y, dz, size, _ = BALLOONS[i]
    p = i * 1.7
    return Vector((x + 0.28 * math.sin(f / 13 + p), y + 0.15 * math.cos(f / 17 + p),
                   stage.interp(RISE, f) + dz + 0.18 * math.sin(f / 9 + p)))


def tip(i, f):
    return balloon_pos(i, f) + Vector((0, 0, -BALLOONS[i][3] * 1.1))


def rope(i, frames):
    """Verlet chain hung from the balloon knot; a released rope (popped balloon) simply falls."""
    pts = [tip(i, 1) + Vector((0, 0, -SEG_LEN * k)) for k in range(SEGS)]
    old = [p.copy() for p in pts]
    out = {}
    for f in range(1, frames + 1):
        free = i == POP_I and f >= POP_F
        for sub in range(4):
            t = f + sub / 4
            wind = Vector((0.9 * math.sin(t / 8 + i), 0, 0))
            for k in range(0 if free else 1, SEGS):
                v = (pts[k] - old[k]) * 0.985
                old[k] = pts[k].copy()
                pts[k] = pts[k] + v + (Vector((0, 0, -5.0)) + wind) * (DT / 4) ** 2
            for _ in range(6):
                if not free:
                    pts[0] = tip(i, t)
                for k in range(SEGS - 1):
                    d = pts[k + 1] - pts[k]
                    fix = d * (0.5 * (d.length - SEG_LEN) / max(d.length, 1e-5))
                    if k > 0 or free:
                        pts[k] = pts[k] + fix
                        pts[k + 1] = pts[k + 1] - fix
                    else:
                        pts[k + 1] = pts[k + 1] - 2 * fix
        out[f] = [p.copy() for p in pts]
    return out


def string(sc, i, mat):
    cu = bpy.data.curves.new(f"String{i}", "CURVE")
    cu.dimensions, cu.bevel_depth, cu.bevel_resolution = "3D", 0.012, 2
    sp = cu.splines.new("POLY")
    sp.points.add(SEGS - 1)
    cu.materials.append(mat)
    ob = bpy.data.objects.new(f"String{i}", cu)
    sc.collection.objects.link(ob)
    for f, pts in rope(i, TOTAL).items():
        for pt, p in zip(sp.points, pts):
            pt.co = (*p, 1.0)
            pt.keyframe_insert("co", frame=f)
    return ob


def balloon(sc, i):
    _, _, _, size, rgb = BALLOONS[i]
    mat = stage.pbr(f"Foil{i}", rgb, metallic=0.75, roughness=0.2, coat=1.0)
    ob = stage.link(sc, f"Heart{i}", stage.heart_mesh(f"Heart{i}", size), mat)
    knot = stage.lathe(f"Knot{i}", [(0, 0.0), (0.03, -0.06), (0.09, -0.16), (0.11, -0.18), (0, -0.18)], 12)
    stage.link(sc, f"Knot{i}", knot, mat, parent=ob, loc=(0, 0, -size * 1.1 + 0.1))
    return ob


def build_show(sc, opts):
    cam = stage.setup(sc, TOTAL, opts["samples"], world=1.0, hdri="city.exr", lights=0.7, fog=(1.5, 7), streak=3.0)
    for light in bpy.data.lights:    # square rim lights mirrored on the foil as hard white parallelograms
        light.shape = "DISK"
    white = stage.pbr("StringMat", (0.85, 0.85, 0.82), roughness=0.5)
    frames = list(range(1, TOTAL + 1, 2))
    objs = []
    for i in range(len(BALLOONS)):
        ob = balloon(sc, i)
        objs.append(ob)
        stage.key_path(ob, frames, lambda f, i=i: balloon_pos(i, f))
        stage.key_path(ob, frames, lambda f, i=i: (R(5) * math.sin(f / 11 + i), R(7) * math.sin(f / 15 + 2 * i),
                                                   R(14) * math.sin(f / 19 + i)), path="rotation_euler")
        string(sc, i, white)
    pop = objs[POP_I]
    for f, s in ((POP_F - 1, 1.0), (POP_F, 1.18), (POP_F + 1, 0.001)):
        pop.scale = (s, s, s)
        pop.keyframe_insert("scale", frame=f)
    at = balloon_pos(POP_I, POP_F)
    for name, rgb, n, size in (("Gold", (1.0, 0.72, 0.25), 420, 0.022), ("Pink", (1.0, 0.25, 0.4), 260, 0.018)):
        mat = fx.fade_material(f"Glitter{name}", rgb, 14.0, 1.0, 0.8)
        fx.particle_burst(sc, f"Glitter{name}", gc.ico_mesh(f"G{name}", 0.55, 2), mat, n, (POP_F, POP_F + 2), 30, size,
                          4.5, rand=1.2, damping=0.1, gravity=0.28, location=at)
    sh.camera_shake(cam, POP_F, 8, amp=0.03, rot_deg=0.2, seed=3)
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Three balloons swing as one pendulum from a shared tie point: frame 30 == frame 0."""
    cam = stage.setup_icon(sc, opts["samples"], world=1.0, hdri="city.exr", lights=0.7, fog=(1.5, 7), streak=3.0)
    n = stage.ICON_N
    pivot = bpy.data.objects.new("Pivot", None)
    sc.collection.objects.link(pivot)
    pivot.location = (0, 0, -3.4)
    white = stage.pbr("StringMat", (0.85, 0.85, 0.82), roughness=0.5)
    for k, (x, z, size, rgb) in enumerate(((-1.15, 4.3, 1.15, (0.66, 0.012, 0.03)), (1.2, 4.7, 1.05, (0.75, 0.05, 0.22)),
                                           (0.0, 3.3, 1.3, (0.7, 0.008, 0.015)))):
        BALLOONS[k] = (x, 0.0, z, size, rgb)
        ob = balloon(sc, k)
        ob.parent = pivot
        ob.location = (x, 0.3 * k, z)
        a, b = Vector((x, 0.3 * k, z - size * 1.1)), Vector((0, 0, 0))
        cu = bpy.data.curves.new(f"S{k}", "CURVE")
        cu.dimensions, cu.bevel_depth = "3D", 0.016
        sp = cu.splines.new("POLY")
        sp.points.add(1)
        sp.points[0].co, sp.points[1].co = (*a, 1.0), (*b, 1.0)
        cu.materials.append(white)
        so = bpy.data.objects.new(f"S{k}", cu)
        sc.collection.objects.link(so)
        so.parent = pivot
    stage.key_path(pivot, range(0, n + 1), lambda f: (0, R(4.5) * math.sin(2 * math.pi * f / n), 0), path="rotation_euler")
    cam.location = (0, -gc.CAM_DIST, 0.2)
    cam.data.lens = gc.CAM_DIST * 18.0 / 4.6


stage.run(ID, build_show, build_icon)
