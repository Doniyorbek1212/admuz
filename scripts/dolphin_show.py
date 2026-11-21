"""UZARO v2 show: dolphin (tier 2, 120 f = 5 s).

Two dolphins burst from the sea one after the other, arc across the frame shedding droplets and dive; each entry and exit
throws a splash and a foam ring, and a faint rainbow forms in the mist over the arc. Autorig: a spine wave drives the
tail beat. Splash is droplets and mist, not a fluid sim. The low-poly mesh is welded, subdivided and repainted.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import autorig  # noqa: E402
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
import water  # noqa: E402
from stage import R  # noqa: E402

ID = "dolphin"
TOTAL = 120
SIZE = 5.2
WATER_Z = -3.5
ELEV = R(12)
X = (1, 0, 0)
LEAPS = (
    {"from": (-3.3, 0.0), "to": (3.1, -0.3), "apex": 2.6, "f0": 14, "f1": 74, "beat": 0.0, "size": 1.0},
    {"from": (-3.0, 2.0), "to": (3.4, 1.8), "apex": 0.9, "f0": 30, "f1": 86, "beat": 1.7, "size": 0.86},
)
# measured at length 6, nose -Y: spine runs along z = -0.1
SPINE_Y = (-1.5, -0.5, 0.5, 1.4, 2.2, 3.0)
WAVE = (3.0, 5.0, 8.0, 13.0, 20.0)


def leap_pos(leap, f):
    t = (f - leap["f0"]) / (leap["f1"] - leap["f0"])
    x = leap["from"][0] + (leap["to"][0] - leap["from"][0]) * t
    y = leap["from"][1] + (leap["to"][1] - leap["from"][1]) * t
    z = WATER_Z - 1.0 + (leap["apex"] - WATER_Z + 1.0) * (1 - (2 * t - 1) ** 2)
    return Vector((x, y, z))


def paint(ob):
    """Dark blue-grey back to pale belly by rest height: a per-vertex value, so it follows the swimming body."""
    me = ob.data
    if "custom_normal" in me.attributes:
        me.attributes.remove(me.attributes["custom_normal"])
    stage.weld(ob)     # the file has flat, split faces: subdivision would shrink each one to a blob
    zs = [v.co.z for v in me.vertices]
    lo, hi = min(zs), max(zs)
    attr = me.attributes.new("back", "FLOAT", "POINT")
    attr.data.foreach_set("value", [(z - lo) / (hi - lo) for z in zs])
    m = bpy.data.materials.new("DolphinSkin")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out, b, a, r = N("ShaderNodeOutputMaterial"), N("ShaderNodeBsdfPrincipled"), N("ShaderNodeAttribute"), N("ShaderNodeValToRGB")
    a.attribute_name = "back"
    e = r.color_ramp.elements
    e[0].position, e[0].color = 0.22, (0.5, 0.53, 0.56, 1)
    e[1].position, e[1].color = 0.38, (0.018, 0.035, 0.065, 1)
    L(a.outputs["Fac"], r.inputs["Fac"])
    L(r.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = 0.34
    b.inputs["Coat Weight"].default_value = 0.25
    b.inputs["Coat Roughness"].default_value = 0.2
    L(b.outputs[0], out.inputs["Surface"])
    me.materials.clear()
    me.materials.append(m)
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))


def load(sc, leap):
    size = SIZE * leap["size"]
    root, model, objs, meshes = stage.load(ID, size, hide=("Plane_0",), strip_rig=True)
    s = size / 6.0
    autorig.bake_world(meshes)
    for m in meshes:
        paint(m)
        stage.apply_modifier(m, "SUBSURF", levels=2, render_levels=2)
        m.data.polygons.foreach_set("use_smooth", [True] * len(m.data.polygons))
    z = -0.1 * s
    bones = [("root", None, Vector((0, -2.0 * s, z)), Vector((0, -1.5 * s, z))), ("head", "root", Vector((0, SPINE_Y[0] * s, z)), Vector((0, -3.0 * s, z)))]
    bones += autorig.chain("spine", [Vector((0, y * s, z)) for y in SPINE_Y], "root")
    arm = autorig.add_rig(sc, f"Dolphin{leap['size']}", bones, meshes, power=5.0, limits={"root": lambda c: c[:, 0] * 0.0})
    arm.parent = root
    root.rotation_mode = "XYZ"
    return root, arm, meshes


def beat(pose, f, phase, amp=1.0, rate=0.75):
    """Travelling wave down the spine: small at the shoulders, big at the flukes."""
    pose.key(f, {f"spine{i}": (X, a * amp * math.sin(f * rate + phase - i * 0.85)) for i, a in enumerate(WAVE)})


def animate(root, arm, meshes, leap):
    pose = autorig.Pose(arm)
    f0, f1 = leap["f0"], leap["f1"]
    for f in range(1, TOTAL + 1):
        c = min(max(f, f0), f1)
        t = (c - f0) / (f1 - f0)
        p = leap_pos(leap, c)
        d = leap_pos(leap, c + 0.5) - leap_pos(leap, c - 0.5)
        pitch, yaw = stage.aim(d)
        root.location = p
        root.rotation_euler = (pitch, R(5.0 * math.sin((c - f0) / 9.0)), yaw - R(16))
        root.keyframe_insert("location", frame=f)
        root.keyframe_insert("rotation_euler", frame=f)
        # hard strokes leaving and entering the water, a lazy flex at the top of the arc
        out_of_water = 4.0 * t * (1 - t)
        beat(pose, f, leap["beat"], amp=1.0 - 0.6 * out_of_water, rate=0.8 - 0.4 * out_of_water)
        hide = f < f0 - 1 or f > f1 + 1
        for m in meshes:
            m.hide_render = hide
            m.keyframe_insert("hide_render", frame=f)


def splash(sc, name, at, f, big=1.0):
    """Crown of droplets, a thin mist, a foam ring."""
    drop = stage.pbr(f"{name}Drop", (0.85, 0.93, 1.0), roughness=0.08, coat=1.0, emission=(0.6, 0.76, 0.92), strength=0.6)
    fx.particle_burst(sc, f"{name}D", fx.ring_mesh(f"{name}DR", 0.75, 0.05, 40), drop, int(700 * big), (f - 1, f + 6), 24, 0.03, 2.4 * big, rand=1.4,
                      align=(0, 0, 5.0 * big), gravity=0.8, location=(at[0], at[1], WATER_Z))
    mist = fx.fade_material(f"{name}M", (0.92, 0.96, 1.0), 0.9, 0.035, 1.1)
    fx.particle_burst(sc, f"{name}M", fx.ring_mesh(f"{name}MR", 0.7, 0.05, 28), mist, int(90 * big), (f - 1, f + 8), 26, 0.38, 0.7 * big, rand=1.0,
                      align=(0, 0, 1.8), damping=0.1, location=(at[0], at[1], WATER_Z))
    fx.shock_ring(sc, f"{name}Ring", (at[0], at[1], WATER_Z + 0.03), (f, f + 22), 3.2 * big, (0.9, 0.96, 1.0), 0.9, width=0.03)


def shed(sc, root, leap):
    """Droplets falling off the body in flight."""
    tag = leap["size"]
    drop = stage.pbr(f"Shed{tag}", (0.85, 0.93, 1.0), roughness=0.08, coat=1.0, emission=(0.6, 0.76, 0.92), strength=0.8)
    em = fx.particle_burst(sc, f"Shed{tag}", gc.ico_mesh(f"ShedE{tag}", 0.5, 1), drop, 500, (leap["f0"], leap["f0"] + 34), 22, 0.02, 0.3, rand=0.8, gravity=0.8)
    em.parent = root


def rainbow(sc):
    """Soft spectral arc behind the leaps: only ever faint, a mist effect, never a solid band."""
    verts, faces = [], []
    n, inner, outer = 64, 4.3, 5.5
    for i in range(n + 1):
        a = math.pi * i / n
        for r in (inner, outer):
            verts.append((r * math.cos(a), 0.0, r * math.sin(a)))
    faces = [(2 * i, 2 * i + 2, 2 * i + 3, 2 * i + 1) for i in range(n)]
    me = bpy.data.meshes.new("Rainbow")
    me.from_pydata(verts, [], faces)
    m = bpy.data.materials.new("Rainbow")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out, tc, ln = N("ShaderNodeOutputMaterial"), N("ShaderNodeTexCoord"), N("ShaderNodeVectorMath")
    ln.operation = "LENGTH"
    L(tc.outputs["Object"], ln.inputs[0])
    t = N("ShaderNodeMapRange")
    t.inputs["From Min"].default_value, t.inputs["From Max"].default_value = inner, outer
    L(ln.outputs["Value"], t.inputs["Value"])
    ramp = N("ShaderNodeValToRGB")
    els = ramp.color_ramp.elements
    els[0].position, els[0].color = 0.08, (0.35, 0.05, 0.9, 1)
    els[1].position, els[1].color = 0.92, (1.0, 0.04, 0.03, 1)
    for pos, col in ((0.25, (0.03, 0.2, 1.0, 1)), (0.42, (0.05, 0.9, 0.2, 1)), (0.6, (1.0, 0.9, 0.05, 1)), (0.76, (1.0, 0.35, 0.02, 1))):
        els.new(pos).color = col
    L(t.outputs["Result"], ramp.inputs["Fac"])
    bell = N("ShaderNodeFloatCurve")
    cv = bell.mapping.curves[0]
    cv.points[0].location, cv.points[1].location = (0.0, 0.0), (1.0, 0.0)
    cv.points.new(0.5, 1.0)
    bell.mapping.update()
    L(t.outputs["Result"], bell.inputs["Value"])
    pos = N("ShaderNodeSeparateXYZ")
    L(tc.outputs["Object"], pos.inputs[0])
    feet = N("ShaderNodeMapRange")
    feet.interpolation_type = "SMOOTHSTEP"
    feet.inputs["From Min"].default_value, feet.inputs["From Max"].default_value = 0.1, 2.4
    L(pos.outputs["Z"], feet.inputs["Value"])
    mul = N("ShaderNodeMath")
    mul.operation = "MULTIPLY"
    L(bell.outputs[0], mul.inputs[0])
    L(feet.outputs["Result"], mul.inputs[1])
    amt = N("ShaderNodeMath")
    amt.operation = "MULTIPLY"
    L(mul.outputs[0], amt.inputs[0])
    stage.key_socket(amt.inputs[1], [(28, 0.0), (52, 0.16), (92, 0.16), (112, 0.0)])
    em, tr, mix = N("ShaderNodeEmission"), N("ShaderNodeBsdfTransparent"), N("ShaderNodeMixShader")
    L(ramp.outputs["Color"], em.inputs["Color"])
    em.inputs["Strength"].default_value = 1.4
    L(amt.outputs[0], mix.inputs[0])
    L(tr.outputs[0], mix.inputs[1])
    L(em.outputs[0], mix.inputs[2])
    L(mix.outputs[0], out.inputs["Surface"])
    ob = stage.link(sc, "Rainbow", me, m, loc=(0.0, 3.5, WATER_Z + 0.2), shadow=False)
    ob.visible_glossy = False     # its mirror image in the sea read as cracks


def build_show(sc, opts):
    rig = [load(sc, leap) for leap in LEAPS]
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.85, hdri="sunrise.exr", lights=0.7, fog=(2.0, 6), streak=14.0)
    sc.cycles.transparent_max_bounces = 128
    cam.location, cam.rotation_euler = (0.0, -gc.CAM_DIST * math.cos(ELEV), gc.CAM_DIST * math.sin(ELEV) - 0.8), (R(90) - ELEV, 0, 0)
    for (root, arm, meshes), leap in zip(rig, LEAPS):
        animate(root, arm, meshes, leap)
        shed(sc, root, leap)
        out_f = int(leap["f0"] + (leap["f1"] - leap["f0"]) * 0.08)
        in_f = int(leap["f0"] + (leap["f1"] - leap["f0"]) * 0.92)
        tag = leap["size"]
        splash(sc, f"Out{tag}", leap_pos(leap, out_f), out_f, leap["size"])
        splash(sc, f"In{tag}", leap_pos(leap, in_f), in_f, leap["size"] * 1.15)
    mat = water.material("Water", 7.0, 5.0, radius_keys=[(1, 0.02), (16, 1.0), (98, 1.0), (TOTAL, 0.02)])
    water.patch(sc, "Sea", WATER_Z, TOTAL, mat, span=30.0, wave=0.2, foam=False)
    rainbow(sc)
    sh.screen_extent(sc, cam, rig[0][2], (20, 44, 70))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """One dolphin jumps over a frozen sea: it is hidden under the surface at the seam, so the loop is exact."""
    leap = {"from": (-2.6, 0.0), "to": (2.6, 0.0), "apex": 1.1, "f0": 3, "f1": 27, "beat": 0.0, "size": 0.8}
    global WATER_Z
    WATER_Z = -1.0
    root, arm, meshes = load(sc, leap)
    cam = stage.setup_icon(sc, opts["samples"], world=1.05, hdri="sunrise.exr", lights=0.85, fog=(2.0, 6), streak=8.0)
    n = stage.ICON_N
    pose = autorig.Pose(arm)
    f0, f1 = leap["f0"], leap["f1"]
    for f in range(0, n + 1):
        c = min(max(f, f0), f1)
        pitch, yaw = stage.aim(leap_pos(leap, c + 0.5) - leap_pos(leap, c - 0.5))
        root.location = leap_pos(leap, c)
        root.rotation_euler = (pitch, 0.0, yaw - R(16))
        root.keyframe_insert("location", frame=f)
        root.keyframe_insert("rotation_euler", frame=f)
        beat(pose, f, 0.0, amp=0.7, rate=4 * math.pi / n)
        hide = f < f0 or f > f1
        for m in meshes:
            m.hide_render = hide
            m.keyframe_insert("hide_render", frame=f)
    mat = water.material("Water", 4.2, 5.0)
    sea = water.patch(sc, "Sea", WATER_Z, n, mat, span=22.0, res=8, wave=0.16, foam=False)
    sea.animation_data_clear()
    # shortcut: frozen ocean in the icon, a loop would need matching FFT phases; hardly visible at 192 px
    cam.location, cam.rotation_euler = (0.0, -gc.CAM_DIST * math.cos(ELEV), gc.CAM_DIST * math.sin(ELEV)), (R(90) - ELEV, 0, 0)
    cam.data.lens = gc.CAM_DIST * 18.0 / 3.4
    sc.frame_set(1)
    stage.bake_all(sc)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
