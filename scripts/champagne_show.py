"""UZARO v2 show: champagne (tier 1, 96 f = 4 s).

The bottle slides in, the cork shoots off with a spray of foam and droplets (particles), the bottle tips and pours
into two flutes that fill with bubbling wine, leaves, and the flutes clink with a sparkle.
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
from stage import R, env  # noqa: E402

ID = "champagne"
TOTAL = 96
BOTTLE_H = 5.6
ENTER, POP_F = (1, 14), 18
POUR_A, POUR_B, LEAVE = (30, 46), (48, 62), (63, 76)
CLINK_F = 80
GLASS_X, GLASS_Z, GLASS_SCALE = 1.05, -6.0, 1.0
CLINK_X = 1.33                                  # foot offset where tilted rims just touch
RIM_H = 4.0                                     # flute height at scale 1
FOOT_ALONG = (-2.0, 0.0)


def flute_profile():
    """Outer wall bottom to rim, then inner wall back down: real thickness so refraction reads."""
    return [(0, 0.0), (0.62, 0.0), (0.64, 0.04), (0.5, 0.08), (0.08, 0.18), (0.055, 0.5), (0.05, 1.3), (0.09, 1.5), (0.3, 1.85),
            (0.44, 2.6), (0.47, 3.3), (0.43, 4.0), (0.415, 4.0), (0.452, 3.3), (0.425, 2.6), (0.28, 1.88), (0.1, 1.58), (0, 1.54)]


def liquid_mesh():
    return stage.lathe("Liquid", [(0, 1.56), (0.1, 1.6), (0.27, 1.9), (0.415, 2.6), (0.445, 3.3), (0.42, 3.9), (0, 3.9)], 32)


def flute(sc, name, glass, wine, foam):
    pivot = bpy.data.objects.new(name, None)
    sc.collection.objects.link(pivot)
    me = stage.lathe(name + "Glass", flute_profile(), 64)
    stage.link(sc, name + "Glass", me, glass, parent=pivot)
    liq = stage.link(sc, name + "Wine", liquid_mesh(), wine, parent=pivot, shadow=False)
    top = stage.link(sc, name + "Head", stage.lathe(name + "Head", [(0, 0.0), (0.41, 0.0), (0.41, 0.05), (0, 0.09)], 32), foam, parent=pivot, shadow=False)
    return pivot, liq, top


def fill(liq, top, window, level=0.92):
    """Liquid grows from the bowl bottom (1.56) by scaling Z about it."""
    z0, z1 = 1.56, 3.9
    liq.location.z = z0 - z0
    frames = [1] + list(range(window[0], window[1] + 1, 2))

    def k(f):
        return max(1e-3, level * env(f, window[0], window[1]))
    stage.key_path(liq, frames, lambda f: (0.97, 0.97, k(f)), path="scale")
    stage.key_path(liq, frames, lambda f: (0, 0, z0 * (1 - k(f))))
    stage.key_path(top, frames, lambda f: (0, 0, z0 + (z1 - z0) * k(f)))
    # the bowl narrows at the bottom: head scales with the bowl radius at that height
    stage.key_path(top, frames, lambda f: (min(1.05, 0.25 + 1.0 * k(f) ** 0.6),) * 2 + (1.0 if k(f) > 0.02 else 0.001,), path="scale")


def bottle_pose(f):
    """Root location/tilt: mouth-driven while pouring."""
    mouth_a = Vector((GLASS_X - 0.1, 0.0, -0.1))
    mouth_b = Vector((-GLASS_X + 0.1, 0.0, -0.1))
    upright = Vector((-0.5, 0.0, 0.1))
    tilt = R(112) * env(f, POP_F + 6, POUR_A[0] + 2) * (1 - env(f, LEAVE[0], LEAVE[1]) * 0.55)
    enter = stage.smooth((f - ENTER[0]) / (ENTER[1] - ENTER[0]))
    k = env(f, POUR_A[1] - 1, POUR_B[0] + 2)
    target = mouth_a.lerp(mouth_b, k)
    h = BOTTLE_H / 2
    d = Vector((math.sin(tilt), 0, math.cos(tilt)))
    pour = target - d * h
    base = upright.lerp(pour, env(f, POP_F + 6, POUR_A[0] + 2))
    gone = env(f, LEAVE[0], LEAVE[1])
    out = Vector((-9.0, 0, 9.0))
    loc = base.lerp(out, gone) + Vector((-9.0 * (1 - enter), 0, 0))
    return loc, (0.0, tilt - R(10) * (1 - enter), 0.0)


def pour_stream(sc, mat, window, x):
    """Thin wine column from the mouth to the rising surface."""
    st = stage.lathe(f"Stream{x}", [(0, 0.0), (0.05, 0.0), (0.045, -1.0), (0, -1.0)], 10)
    ob = stage.link(sc, f"Stream{x}", st, mat, shadow=False)
    ob.location = (x, 0, -0.05)
    frames = [1, window[0] - 1, window[0], window[0] + 1, window[1] - 2, window[1] - 1, window[1]]
    length = 3.3
    stage.key_path(ob, frames, lambda f: (1.0, 1.0, length if window[0] <= f < window[1] else 0.001), path="scale")


def build_show(sc, opts):
    root, model, objs, meshes = stage.load("champagne", BOTTLE_H)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=1.0, hdri="interior.exr", lights=0.8, fog=(1.4, 7), streak=3.0)
    sc.cycles.max_bounces, sc.cycles.transmission_bounces = 12, 12
    frames = list(range(1, TOTAL + 1))
    stage.key_path(root, frames, lambda f: bottle_pose(f)[0])
    stage.key_path(root, frames, lambda f: bottle_pose(f)[1], path="rotation_euler")
    glass = stage.pbr("FluteGlass", (1, 1, 1), roughness=0.02, transmission=1.0, ior=1.5)
    wine = stage.pbr("Wine", (1.0, 0.72, 0.28), roughness=0.05, transmission=1.0, ior=1.33, emission=(1.0, 0.62, 0.2), strength=0.1)
    foam = stage.pbr("Foam", (1.0, 0.96, 0.85), roughness=0.7)
    pivots = []
    for x, window, name in ((GLASS_X, POUR_A, "A"), (-GLASS_X, POUR_B, "B")):
        p, liq, top = flute(sc, name, glass, wine, foam)
        fill(liq, top, (window[0] + 2, window[1] + 1))
        pivots.append(p)
        side = -1 if x < 0 else 1

        def loc(f, x=x, side=side):
            enter = stage.smooth((f - 2) / 16)
            cl = env(f, LEAVE[1] - 4, CLINK_F)
            back = env(f, CLINK_F, CLINK_F + 5) * 0.12
            return (x + side * (CLINK_X - GLASS_X) * cl + side * back + side * 5.0 * (1 - enter), 0.0, GLASS_Z + (1.0) * cl - 7.0 * (1 - enter))

        def rot(f, side=side):
            cl = env(f, LEAVE[1] - 4, CLINK_F)
            ring = math.sin(max(0, f - CLINK_F) * 1.8) * math.exp(-max(0, f - CLINK_F) / 4.0) * R(2.0)
            return (0.0, side * -R(13) * cl + ring * side, 0.0)
        stage.key_path(p, frames, loc)
        stage.key_path(p, frames, rot, path="rotation_euler")
    pour_stream(sc, wine, POUR_A, GLASS_X - 0.1)
    pour_stream(sc, wine, POUR_B, -GLASS_X + 0.1)
    # cork: drives off the mouth at the pop
    cork_m = stage.pbr("Cork", (0.55, 0.4, 0.22), roughness=0.8)
    cork = stage.link(sc, "Cork", stage.lathe("Cork", [(0, 0), (0.17, 0), (0.2, 0.12), (0.24, 0.32), (0.22, 0.44), (0, 0.47)], 20), cork_m)
    mouth0 = bottle_pose(POP_F)[0] + Vector((0, 0, BOTTLE_H / 2))

    def cork_loc(f):
        t = max(0.0, f - POP_F) / sh.FPS
        base = bottle_pose(f)[0] + Vector((0, 0, BOTTLE_H / 2 - 0.05)) if f <= POP_F else mouth0
        return base + Vector((2.4 * t, -1.0 * t, 18.0 * t))
    stage.key_path(cork, range(1, POP_F + 16), cork_loc)
    stage.key_path(cork, range(1, POP_F + 16), lambda f: (11.0 * max(0.0, f - POP_F) / sh.FPS, 15.0 * max(0.0, f - POP_F) / sh.FPS, 0.0), path="rotation_euler")
    for name, rgb, n, size, sp in (("FoamSpray", (1.0, 0.96, 0.85), 900, 0.05, 11.0), ("Drops", (1.0, 0.82, 0.45), 300, 0.025, 15.0)):
        mat = fx.fade_material(name, rgb, 2.2 if name == "FoamSpray" else 7.0, 1.0, 0.6)
        fx.particle_burst(sc, name, gc.ico_mesh(name + "E", 0.1, 1), mat, n, (POP_F, POP_F + 9), 18, size * 1.5, 0.0, rand=1.1,
                          align=(0.12 * sp, -0.05 * sp, sp), gravity=0.7, emit_from="VOLUME", location=mouth0)
    glint = fx.fade_material("Clink", (1.0, 0.85, 0.5), 22.0)
    fx.particle_burst(sc, "Clink", gc.ico_mesh("ClinkE", 0.08, 1), glint, 120, (CLINK_F, CLINK_F + 2), 14, 0.018, 3.2, rand=1.2, gravity=0.18,
                      location=(0, 0, GLASS_Z + 1.0 + 3.7))
    bub = fx.fade_material("Bubble", (1.0, 0.95, 0.75), 4.0, 1.0, 0.3)
    for k, p in enumerate(pivots):
        em = fx.particle_burst(sc, f"Bub{k}", gc.ico_mesh(f"BubE{k}", 0.08, 1), bub, 45, (POUR_A[0], TOTAL), 16, 0.012, 0.0, rand=0.1,
                               align=(0, 0, 1.1), gravity=0.0, emit_from="VOLUME", location=(0, 0, 1.7))
        em.parent = p
    sh.camera_shake(cam, POP_F, 7, amp=0.05, rot_deg=0.3, seed=5)
    sh.camera_shake(cam, CLINK_F, 4, amp=0.012, rot_deg=0.08, seed=6)
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Two full flutes touching, wine glowing; bubbles and a slight rock: frame 30 == frame 0."""
    cam = stage.setup_icon(sc, opts["samples"], world=1.0, hdri="interior.exr", lights=0.8, fog=(1.4, 7), streak=3.0)
    sc.cycles.max_bounces, sc.cycles.transmission_bounces = 12, 12
    glass = stage.pbr("FluteGlass", (1, 1, 1), roughness=0.02, transmission=1.0, ior=1.5)
    wine = stage.pbr("Wine", (1.0, 0.72, 0.28), roughness=0.05, transmission=1.0, ior=1.33, emission=(1.0, 0.62, 0.2), strength=0.1)
    foam = stage.pbr("Foam", (1.0, 0.96, 0.85), roughness=0.7)
    n = stage.ICON_N
    for x, name, side in ((-0.62, "A", -1), (0.62, "B", 1)):
        p, liq, top = flute(sc, name, glass, wine, foam)
        liq.scale = (0.97, 0.97, 0.92)
        liq.location.z = 1.56 * 0.08
        top.location.z = 1.56 + 2.34 * 0.92
        stage.key_path(p, range(0, n + 1), lambda f, x=x, side=side: (x, 0.0, -2.1), )
        stage.key_path(p, range(0, n + 1), lambda f, side=side: (0.0, -side * R(11) + R(1.8) * math.sin(2 * math.pi * f / n), 0.0), path="rotation_euler")
    cam.location = (0, -gc.CAM_DIST, 0.0)
    cam.data.lens = gc.CAM_DIST * 18.0 / 2.6


stage.run(ID, build_show, build_icon)
