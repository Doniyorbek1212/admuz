"""UZARO v2 show: teddy_bear (tier 1, 96 f = 4 s).

A honey-brown plush bear waddles in rolling side to side, turns to camera and waves, a red plush heart pops up with
sparkles, it hugs the heart and rocks, then bows. Autorig biped on the upright file pose; fur is particle hair.
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import animal  # noqa: E402
import autorig  # noqa: E402
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, env, interp  # noqa: E402

ID = "teddy_bear"
TOTAL = 96
SIZE = 6.0
K = 1.08
ROT = (R(0), R(90), R(-90))
GROUND_Z = -3.2
FEET_Z = -2.9
X, Y, Z = animal.X, animal.Y, animal.Z
TINT = (0.565, 0.85, 1.0)     # file texture is pink: push the hue to honey brown
FUR_TINT = (0.565, 0.75, 0.65)  # hair scatters light: darker and more saturated than the skin to read the same colour
FUR_RGB = (0.55, 0.3, 0.14)
EYES = ((-0.17, -0.96, 1.92), (0.17, -0.94, 1.88))
NOSE = (-0.01, -1.42, 1.55)
TRAVEL = [(1, -8.0), (32, -0.6), (38, 0.0)]
HEADING = [(1, 62.0), (30, 62.0), (40, 6.0)]
WADDLE_END = 36
WAVE = (38, 54)
HEART_F = 52
HUG = (54, 64, 76)        # close, hold until
BOW = (76, 84, 92)
BONES = [
    ("root", None, Vector((0, 0.1, -0.9)), Vector((0, 0.1, -0.6))),
    ("spine0", "root", Vector((0, 0.1, -0.9)), Vector((0, 0.1, 0.0))),
    ("spine1", "spine0", Vector((0, 0.1, 0.0)), Vector((0, 0.1, 0.95))),
    ("head", "spine1", Vector((-0.05, 0.1, 0.95)), Vector((-0.24, 0.1, 2.7))),
    ("armL0", "spine1", Vector((0.72, 0.1, 0.85)), Vector((1.3, 0.15, 0.5))),
    ("armL1", "armL0", Vector((1.3, 0.15, 0.5)), Vector((1.9, 0.25, 0.0))),
    ("armR0", "spine1", Vector((-0.92, 0.1, 0.85)), Vector((-1.42, 0.1, 0.1))),
    ("armR1", "armR0", Vector((-1.42, 0.1, 0.1)), Vector((-1.75, 0.1, -0.8))),
    ("legL0", "root", Vector((0.35, 0.15, -0.95)), Vector((0.85, 0.45, -1.55))),
    ("legL1", "legL0", Vector((0.85, 0.45, -1.55)), Vector((1.4, 0.3, -2.1))),
    ("legR0", "root", Vector((-0.5, 0.15, -0.95)), Vector((-0.62, 0.1, -1.85))),
    ("legR1", "legR0", Vector((-0.62, 0.1, -1.85)), Vector((-0.7, -0.2, -2.7))),
]


def limits():
    above = lambda z: (lambda c: (c[:, 2] > z) * 1.0)
    below = lambda z: (lambda c: (c[:, 2] < z) * 1.0)
    side = lambda s, zlim: (lambda c: (c[:, 0] * s > 0.0) * (c[:, 2] < zlim))
    return {
        "root": lambda c: c[:, 0] * 0.0,
        "head": above(0.75),
        "spine0": below(0.8),
        "spine1": below(1.05),
        "armL0": lambda c: (c[:, 0] > 0.85) * (c[:, 2] < 1.2) * (c[:, 2] > 0.55 - 0.72 * c[:, 0]),
        "armL1": lambda c: (c[:, 0] > 1.05) * (c[:, 2] < 1.2) * (c[:, 2] > 0.55 - 0.72 * c[:, 0]),
        "armR0": lambda c: (c[:, 0] < -0.95) * (c[:, 2] < 1.2),
        "armR1": lambda c: (c[:, 0] < -1.15) * (c[:, 2] < 1.2),
        "legL0": side(1.0, -0.75),
        "legL1": side(1.0, -1.1),
        "legR0": side(-1.0, -0.75),
        "legR1": side(-1.0, -1.1),
    }


def tint_material(mat):
    b = stage.bsdf(mat)
    tree = mat.node_tree
    if b.inputs["Base Color"].links:
        l = b.inputs["Base Color"].links[0]
        src = l.from_socket
        tree.links.remove(l)
        hs = tree.nodes.new("ShaderNodeHueSaturation")
        hs.inputs["Hue"].default_value, hs.inputs["Saturation"].default_value, hs.inputs["Value"].default_value = TINT
        tree.links.new(src, hs.inputs["Color"])
        tree.links.new(hs.outputs["Color"], b.inputs["Base Color"])
    stage.shiny(mat, roughness=0.85, sheen=0.8)


def load(sc):
    root, model, objs, meshes = stage.load(ID, SIZE, rot=ROT, strip_rig=True)
    autorig.bake_world(meshes)
    for m in meshes:
        tint_material(m.data.materials[0])
        m.data.polygons.foreach_set("use_smooth", [True] * len(m.data.polygons))
    arm = autorig.add_rig(sc, "Bear", BONES, meshes, power=7.0, limits=limits())
    wrap = bpy.data.objects.new("Heading", None)
    sc.collection.objects.link(wrap)
    wrap.parent = root
    arm.parent = wrap
    root.scale = (K, K, K)
    add_face(sc, arm)
    for i, m in enumerate(meshes):
        animal.fur(m, 0.13, count=12000, children=40, radius=0.012, seed=7 + i, clump=0.3, tint=FUR_TINT, multiply=FUR_RGB, density_vg=face_mask(m))
    return root, wrap, arm, meshes


def face_mask(m):
    """Short clear patch for the eyes and nose so the beads are not buried."""
    vg = m.vertex_groups.new(name="FurMask")
    for v in m.data.vertices:
        near = min((Vector(p) - v.co).length for p in (*EYES, NOSE))
        vg.add([v.index], 0.0 if near < 0.26 else 1.0, "REPLACE")
    return vg.name


def add_face(sc, arm):
    """Black glossy beads: the file only paints them, which fur would hide."""
    bead = stage.pbr("Bead", (0.006, 0.005, 0.005), roughness=0.08, coat=1.0)
    for name, p, s in (("EyeA", EYES[0], (0.15, 0.1, 0.17)), ("EyeB", EYES[1], (0.15, 0.1, 0.17)), ("Nose", NOSE, (0.27, 0.16, 0.2))):
        me = gc.ico_mesh(name, 1.0, 3)
        me.transform(Matrix.LocRotScale(Vector(p), None, Vector(s)))
        me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
        ob = stage.link(sc, name, me, bead, parent=arm)
        ob.vertex_groups.new(name="head").add(list(range(len(me.vertices))), 1.0, "REPLACE")
        ob.modifiers.new("Rig", "ARMATURE").object = arm


def add_heart(sc, arm):
    me = stage.heart_mesh("HeartPlush", size=0.95, depth=0.42)
    ob = stage.link(sc, "HeartPlush", me, stage.pbr("HeartPlush", (0.42, 0.004, 0.012), roughness=0.55, coat=0.3))
    ob.parent = arm
    ob.location = (0.02, -1.25, -0.18)
    ob.rotation_euler = (0, R(-4), 0)
    for f in range(1, TOTAL + 1):
        pop = env(f, HEART_F, HEART_F + 3) * (1 + 0.28 * math.exp(-(f - HEART_F - 3) / 3.0) * math.sin((f - HEART_F) * 1.2) if f >= HEART_F + 3 else 1.0)
        squeeze = 0.1 * env(f, HUG[0], HUG[1]) * (0.6 + 0.4 * math.sin(f / 1.8))
        s = max(0.001, pop)
        ob.scale = (s * (1 + squeeze), s * (1 - 1.2 * squeeze), s * (1 + squeeze * 0.6))
        ob.keyframe_insert("scale", frame=f)
    return ob


def sparkle(sc, arm):
    mat = stage.emit("Sparkle", (1.0, 0.82, 0.45), 8.0)
    em = fx.particle_burst(sc, "Sparkle", fx.point_mesh("SparkleP", 0.12), mat, 70, (HEART_F, HEART_F + 3), 16, 0.035, 3.0, rand=1.0, damping=0.08, gravity=-0.06)
    em.parent = arm
    em.location = (0.0, -1.3, -0.1)
    return em


def animate(root, wrap, pose):
    prev, step = interp(TRAVEL, 0), 0.0
    for f in range(1, TOTAL + 1):
        x = interp(TRAVEL, f)
        step += abs(x - prev) / K / 1.5     # one stride per 1.5 units
        prev = x
        amp = 1 - env(f, WADDLE_END - 8, WADDLE_END)
        s = math.sin(step * math.pi)
        wave_a = env(f, WAVE[0], WAVE[0] + 5) * (1 - env(f, WAVE[1], WAVE[1] + 4))
        wave_s = math.sin((f - WAVE[0]) * 2 * math.pi / 7.0)
        hug = env(f, HUG[0], HUG[1]) * (1 - env(f, BOW[1] + 2, BOW[2] + 2) * 0.4)
        rock = hug * math.sin((f - HUG[0]) * 2 * math.pi / 22.0) * (1 - env(f, BOW[0] - 2, BOW[0] + 3))
        bow = env(f, BOW[0], BOW[1]) * (1 - env(f, BOW[1] + 4, BOW[2] + 4))
        pose.key(f, {
            "root": [(Y, 8.0 * s * amp + 7.0 * rock), (X, 0.0)],
            "spine0": [(X, 2.5 * amp * abs(s) + 24.0 * bow), (Z, 5.0 * s * amp)],
            "spine1": [(X, 14.0 * bow + 4.0 * hug), (Y, -3.0 * s * amp)],
            "head": [(Z, -22.0 * amp), (X, 8.0 * hug + 10.0 * bow - 3.0 * wave_a), (Y, 9.0 * rock - 6.0 * s * amp + 6.0 * wave_a * wave_s)],
            # +x arm waves; both close over the heart in the hug
            "armL0": [(Y, -68.0 * wave_a + 18.0 * s * amp), (Z, -64.0 * hug), (X, -15.0 * hug)],
            "armL1": [(Y, -18.0 * wave_a + 22.0 * wave_a * wave_s), (Z, -46.0 * hug)],
            "armR0": [(X, 16.0 * s * amp), (Z, 58.0 * hug), (X, -15.0 * hug)],
            "armR1": (Z, 40.0 * hug),
            # file pose has the +x leg kicked out: bring it under the body, then swing both legs alternately
            "legL0": [(Y, 40.0), (X, 8.0 - 22.0 * s * amp)],
            "legL1": (X, 8.0 * max(0.0, -s) * amp),
            "legR0": (X, 22.0 * s * amp),
            "legR1": (X, 8.0 * max(0.0, s) * amp),
        })
        wrap.rotation_euler = (0, 0, R(interp(HEADING, f)))
        wrap.keyframe_insert("rotation_euler", frame=f)
        z = GROUND_Z - FEET_Z * K + 0.13 * abs(math.sin(step * math.pi)) * amp
        root.location = (x, 0.0, z)
        root.keyframe_insert("location", frame=f)


def build_show(sc, opts):
    root, wrap, arm, meshes = load(sc)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=1.0, follow=root, lights=0.75, fog=(1.8, 5), streak=12.0)
    sc.view_settings.view_transform, sc.view_settings.look = "Filmic", "Medium High Contrast"   # AgX bleaches the red heart
    e = R(5)
    cam.location, cam.rotation_euler = (0.0, -gc.CAM_DIST * math.cos(e), gc.CAM_DIST * math.sin(e)), (R(90) - e, 0, 0)
    sh.shadow_catcher(sc, GROUND_Z, 50)
    pose = autorig.Pose(arm)
    add_heart(sc, arm)
    sparkle(sc, arm)
    animate(root, wrap, pose)
    sh.screen_extent(sc, cam, meshes, (1, 30, 46, 70, 84))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Hugging the heart and rocking on the loop."""
    root, wrap, arm, meshes = load(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=1.0, follow=root, lights=0.75, fog=(1.8, 5), streak=12.0)
    sc.view_settings.view_transform, sc.view_settings.look = "Filmic", "Medium High Contrast"
    pose = autorig.Pose(arm)
    heart = stage.link(sc, "HeartPlush", stage.heart_mesh("HeartPlush", size=0.95, depth=0.42), stage.pbr("HeartPlush", (0.42, 0.004, 0.012), roughness=0.55, coat=0.3))
    heart.parent = arm
    heart.location = (0.02, -1.25, -0.18)
    wrap.rotation_euler = (0, 0, R(6))
    root.location = (0, 0, GROUND_Z - FEET_Z * K)
    n = stage.ICON_N
    for f in range(0, n + 1):
        w = 2 * math.pi * f / n
        rock = math.sin(w)
        squeeze = 0.05 + 0.05 * math.sin(2 * w)
        heart.scale = (1 + squeeze, 1 - 1.2 * squeeze, 1 + squeeze * 0.6)
        heart.keyframe_insert("scale", frame=f)
        pose.key(f, {
            "root": (Y, 7.0 * rock),
            "spine1": (X, 4.0),
            "head": [(X, 8.0), (Y, 9.0 * rock)],
            "armL0": [(Z, -64.0), (X, -15.0)], "armL1": (Z, -46.0),
            "armR0": [(Z, 58.0), (X, -15.0)], "armR1": (Z, 40.0),
            "legL0": [(Y, 40.0), (X, 8.0)],
        })
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.14)
    stage.bake_all(sc)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
