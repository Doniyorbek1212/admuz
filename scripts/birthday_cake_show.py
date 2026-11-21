"""UZARO v2 show: birthday_cake (tier 1, 96 f = 4 s).

The cake rises into frame and settles, five candles light one by one with flickering flames (real light on the
icing), then confetti (rigid bodies under a turbulence field) rains down and lands on the cake and the floor.
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

ID = "birthday_cake"
TOTAL = 96
SIZE = 7.6
GROUND_Z = -3.6
ARRIVE_F = 16
LIGHT_F = (20, 27, 34, 41, 48)
CONFETTI_F = 44
CONFETTI = 150
CANDLE_H, CANDLE_R, RING = 0.85, 0.075, 0.72   # RING: fraction of the cake radius
COLOURS = [(0.85, 0.05, 0.1), (0.95, 0.65, 0.05), (0.05, 0.45, 0.85), (0.9, 0.2, 0.55), (0.1, 0.65, 0.3), (0.95, 0.95, 0.9)]


def body_box(meshes):
    """The cake drum: the mesh whose box is the lowest and widest."""
    body = next(m for m in meshes if m.name.startswith("Circle"))
    lo, hi = gc.world_bbox([body])
    return (lo + hi) / 2, (hi.x - lo.x) / 2, hi.z


def flame_mesh(name):
    return stage.lathe(name, [(0, 0.0), (0.05, 0.03), (0.075, 0.1), (0.055, 0.2), (0.025, 0.3), (0, 0.38)], 16)


def candles(sc, parent, c, radius, top, icon=False):
    wax = [stage.pbr(f"Wax{i}", COLOURS[i % len(COLOURS)], roughness=0.3, coat=0.4) for i in range(5)]
    hot = stage.emit("Flame", (1.0, 0.62, 0.18), 22.0)
    inner = stage.emit("FlameCore", (1.0, 0.9, 0.6), 34.0)
    wick_mat = stage.pbr("Wick", (0.02, 0.02, 0.02), roughness=0.8)
    for i, a in enumerate(R(v) for v in (200, 235, 270, 305, 340)):
        pos = Vector((c.x + radius * RING * math.cos(a), c.y + radius * RING * 0.9 * math.sin(a), top))
        body = stage.lathe(f"Candle{i}", [(0, 0), (CANDLE_R, 0), (CANDLE_R, CANDLE_H), (CANDLE_R * 0.9, CANDLE_H + 0.015), (0, CANDLE_H + 0.015)], 18)
        stage.link(sc, f"Candle{i}", body, wax[i], parent=parent, loc=pos - Vector((0, 0, 0.05)))
        wick = stage.lathe(f"Wick{i}", [(0, 0), (0.012, 0), (0.012, 0.09), (0, 0.09)], 8)
        stage.link(sc, f"Wick{i}", wick, wick_mat, parent=parent, loc=pos + Vector((0, 0, CANDLE_H - 0.05)))
        tip = pos + Vector((0, 0, CANDLE_H + 0.01))
        fl = stage.link(sc, f"Flame{i}", flame_mesh(f"Flame{i}"), hot, parent=parent, loc=tip, shadow=False)
        core = stage.link(sc, f"Core{i}", stage.lathe(f"Core{i}", [(0, 0), (0.03, 0.03), (0.04, 0.09), (0.016, 0.17), (0, 0.22)], 12),
                          inner, parent=fl, shadow=False)
        _ = core
        ld = bpy.data.lights.new(f"CandleLight{i}", "POINT")
        ld.color, ld.shadow_soft_size = (1.0, 0.55, 0.2), 0.08
        lamp = stage.link(sc, f"CandleLight{i}", ld, parent=parent, loc=tip + Vector((0, 0, 0.2)))
        _ = lamp
        start = LIGHT_F[i]
        frames = range(1, stage.ICON_N + 1) if icon else range(1, TOTAL + 1)
        n = stage.ICON_N

        def flick(f, i=i, start=start):
            if icon:   # integer harmonics of the loop: seamless
                w = 2 * math.pi * f / n
                return 1.0 + 0.1 * math.sin(3 * w + i) + 0.06 * math.sin(7 * w + 2 * i)
            on = env(f, start, start + 5) * (1.0 + 0.5 * math.exp(-(f - start) / 3.0) if f >= start else 0.0)
            return on * (1.0 + 0.12 * math.sin(f * 1.7 + i) + 0.07 * math.sin(f * 3.1 + 2 * i))
        stage.key_path(fl, frames, lambda f: (max(1e-3, flick(f) ** 0.5), max(1e-3, flick(f) ** 0.5), max(1e-3, flick(f))), path="scale")
        stage.key_path(fl, frames, lambda f, i=i: (R(6) * math.sin(f * 0.9 + i) * (2 * math.pi / 0.9 / n * 0 + 1), 0, 0) if not icon else
                       (R(5) * math.sin(4 * math.pi * f / n + i), 0, 0), path="rotation_euler")
        for f in frames:
            ld.energy = 26.0 * flick(f)
            ld.keyframe_insert("energy", frame=f)


def confetti(sc, centre, radius, top):
    stage.rigid_world(sc, TOTAL, substeps=12)
    floor = stage.link(sc, "Floor", stage.box_mesh("Floor", 40, 40, 0.1), loc=(0, 0, GROUND_Z - 0.05))
    floor.hide_render = True
    stage.rigid(sc, floor, "PASSIVE", shape="BOX", bounce=0.1)
    drum = stage.link(sc, "Drum", stage.lathe("Drum", [(0, GROUND_Z), (radius, GROUND_Z), (radius, top), (0, top)], 32), loc=(centre.x, centre.y, 0))
    drum.hide_render = True
    stage.rigid(sc, drum, "PASSIVE", shape="MESH", bounce=0.05)
    rnd = stage.seeded(3)
    mats = [stage.pbr(f"Conf{i}", c, metallic=0.2, roughness=0.3) for i, c in enumerate(COLOURS)]
    for i in range(CONFETTI):
        w, h = rnd.uniform(0.09, 0.15), rnd.uniform(0.14, 0.26)
        ob = stage.link(sc, f"Confetti{i}", stage.box_mesh(f"Confetti{i}", w, h, 0.012), rnd.choice(mats))
        ob.location = (rnd.uniform(-3.6, 3.6), rnd.uniform(-1.5, 1.2), rnd.uniform(8.0, 15.0))
        ob.rotation_euler = (rnd.uniform(0, 6), rnd.uniform(0, 6), rnd.uniform(0, 6))
        rb = stage.rigid(sc, ob, "ACTIVE", mass=1.0, shape="BOX", friction=0.8, bounce=0.1)
        rb.linear_damping, rb.angular_damping = 0.55, 0.05
        rb.enabled = False                         # hold above the frame until the release
        rb.kinematic = True
        ob.keyframe_insert("rigid_body.kinematic", frame=CONFETTI_F - 8 + i % 8)
        rb.kinematic = False
        ob.keyframe_insert("rigid_body.kinematic", frame=CONFETTI_F - 7 + i % 8)
        rb.enabled = True
    # the gentle tumble of paper
    bpy.ops.object.effector_add(type="TURBULENCE", location=(0, 0, 3))
    tb = bpy.context.active_object
    tb.field.strength, tb.field.size, tb.field.flow = 9.0, 2.5, 0.2


def build_show(sc, opts):
    root, model, objs, meshes = stage.load("birthday_cake", SIZE)
    lo, hi = gc.world_bbox(meshes)
    model.location.z += (GROUND_Z - lo.z)
    bpy.context.view_layer.update()
    c, radius, top = body_box(meshes)
    candles(sc, root, c, radius, top)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.55, hdri="courtyard.exr", lights=0.35, fog=(1.3, 7), streak=5.0)
    gc_elev = R(8)
    cam.location = (0.0, -gc.CAM_DIST * math.cos(gc_elev), gc.CAM_DIST * math.sin(gc_elev))
    cam.rotation_euler = (R(90) - gc_elev, 0, 0)
    sh.shadow_catcher(sc, GROUND_Z, 40)
    confetti(sc, c, radius, top)
    stage.key_path(root, range(1, ARRIVE_F + 12), lambda f: (0, 0, -13.0 * (1 - stage.smooth((f - 1) / (ARRIVE_F - 1))) + 0.22 * math.sin(max(0, f - ARRIVE_F) / 2.2) * math.exp(-max(0, f - ARRIVE_F) / 4.0)))
    stage.key_path(root, range(1, ARRIVE_F + 12), lambda f: (0, 0, R(-14) * (1 - stage.smooth((f - 1) / (ARRIVE_F - 1)))), path="rotation_euler")
    mat = fx.fade_material("Sparkle", (1.0, 0.75, 0.35), 15.0)
    fx.particle_burst(sc, "Sparkle", gc.ico_mesh("SparkE", 1.0, 2), mat, 60, (LIGHT_F[-1], TOTAL), 20, 0.018, 0.5, rand=1.0,
                      location=(c.x, c.y, top + 1.0))
    stage.bake_all(sc)


def build_icon(sc, opts):
    root, model, objs, meshes = stage.load("birthday_cake", SIZE)
    bpy.context.view_layer.update()
    c, radius, top = body_box(meshes)
    candles(sc, root, c, radius, top, icon=True)
    cam = stage.setup_icon(sc, opts["samples"], world=0.55, hdri="courtyard.exr", lights=0.35, fog=(1.3, 7), streak=5.0)
    stage.frame_icon(cam, meshes, pad=1.16)


stage.run(ID, build_show, build_icon)
