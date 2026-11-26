"""UZARO v2 show: latte (tier 1, 96 f = 4 s).

A tall glass of layered latte slides in on a saucer. A steel jug tips over it and pours a thin stream of milk; a white
disc spreads on the crema and is pulled through into a heart. The jug lifts away, steam curls up and closes into a
small heart, and the glass slides out. All meshes are built here (lathe); the latte art is a shader (circle to heart
implicit curve), not a fluid sim.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, env, interp  # noqa: E402

ID = "latte"
TOTAL = 96
ELEV = R(32)
GROUND_Z = -2.3
CUP_R, CUP_H = 1.25, 2.6
SURF_Z = GROUND_Z + 0.12 + CUP_H - 0.32          # liquid level, world
IN, POUR, SPREAD, PULL, LIFT, STEAM, OUT = (1, 18), (22, 50), (26, 44), (44, 54), (52, 64), (58, 88), (86, 96)
MILK = (0.95, 0.92, 0.86)
CREMA = (0.42, 0.22, 0.09)


# ---------------------------------------------------------------- materials
def glass():
    m = stage.pbr("Glass", (1.0, 1.0, 1.0), roughness=0.02, transmission=1.0, ior=1.45)
    return m


def latte_body():
    """Layered latte seen through the glass: espresso at the bottom, milk above, a crema band on top."""
    m = stage.pbr("LatteBody", CREMA, roughness=0.25)
    nt = m.node_tree
    N, L = nt.nodes.new, nt.links.new
    tc, sep, ramp = N("ShaderNodeTexCoord"), N("ShaderNodeSeparateXYZ"), N("ShaderNodeValToRGB")
    L(tc.outputs["Generated"], sep.inputs[0])
    e = ramp.color_ramp.elements
    e[0].position, e[0].color = 0.28, (0.05, 0.02, 0.008, 1)
    e[1].position, e[1].color = 0.92, (0.62, 0.45, 0.3, 1)
    e.new(0.5).color = (0.48, 0.3, 0.17, 1)
    e.new(0.97).color = (*CREMA, 1)
    L(sep.outputs["Z"], ramp.inputs["Fac"])
    b = stage.bsdf(m)
    L(ramp.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Subsurface Weight"].default_value = 0.4
    b.inputs["Subsurface Radius"].default_value = (0.3, 0.18, 0.1)
    return m


def art_material():
    """Crema with a milk shape: f = mix(circle, heart) implicit on the disc, scaled by keyed Size, morph keyed Heart."""
    m = stage.pbr("LatteArt", CREMA, roughness=0.32)
    nt = m.node_tree
    N, L = nt.nodes.new, nt.links.new

    def op(o, a, b=None, clamp=False):
        n = N("ShaderNodeMath")
        n.operation, n.use_clamp = o, clamp
        for i, x in enumerate((a, b)):
            if x is None:
                continue
            if isinstance(x, (int, float)):
                n.inputs[i].default_value = x
            else:
                L(x, n.inputs[i])
        return n.outputs[0]

    tc, sep = N("ShaderNodeTexCoord"), N("ShaderNodeSeparateXYZ")
    L(tc.outputs["Object"], sep.inputs[0])
    size, heart = N("ShaderNodeValue"), N("ShaderNodeValue")
    size.name, heart.name = "Size", "Heart"
    x = op("DIVIDE", sep.outputs["X"], size.outputs[0])
    y = op("SUBTRACT", op("DIVIDE", sep.outputs["Y"], size.outputs[0]), 0.15)   # disc +Y = away from the lens = heart top
    x2, y2 = op("MULTIPLY", x, x), op("MULTIPLY", y, y)
    q = op("SUBTRACT", op("ADD", x2, y2), 1.0)
    circle = q
    heart_f = op("SUBTRACT", op("MULTIPLY", op("MULTIPLY", q, q), q), op("MULTIPLY", x2, op("MULTIPLY", y2, y)))
    f = N("ShaderNodeMix")
    f.data_type = "FLOAT"
    L(heart.outputs[0], f.inputs["Factor"])
    L(circle, f.inputs["A"])
    L(heart_f, f.inputs["B"])
    milk = N("ShaderNodeMapRange")
    milk.interpolation_type = "SMOOTHSTEP"
    milk.inputs["From Min"].default_value, milk.inputs["From Max"].default_value = 0.04, -0.06
    L(f.outputs["Result"], milk.inputs["Value"])
    noise = N("ShaderNodeTexNoise")                                  # foam mottling and a soft crema rim
    noise.inputs["Scale"].default_value = 18.0
    L(tc.outputs["Object"], noise.inputs["Vector"])
    col = N("ShaderNodeMix")
    col.data_type = "RGBA"
    col.inputs["A"].default_value = (*CREMA, 1)
    col.inputs["B"].default_value = (*MILK, 1)
    L(milk.outputs["Result"], col.inputs["Factor"])
    mott = N("ShaderNodeMix")
    mott.data_type, mott.blend_type = "RGBA", "MULTIPLY"
    mott.inputs["Factor"].default_value = 0.12
    L(col.outputs["Result"], mott.inputs["A"])
    L(noise.outputs["Color"], mott.inputs["B"])
    b = stage.bsdf(m)
    L(mott.outputs["Result"], b.inputs["Base Color"])
    return m, size, heart


def steam_material(name):
    """Soft wisps: transparent white with a moving noise mask; nodes['Fade'] keyed."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out, tc, noise = N("ShaderNodeOutputMaterial"), N("ShaderNodeTexCoord"), N("ShaderNodeTexNoise")
    noise.noise_dimensions = "4D"
    noise.inputs["Scale"].default_value, noise.inputs["Detail"].default_value = 3.0, 4.0
    L(tc.outputs["Object"], noise.inputs["Vector"])
    stage.key_socket(noise.inputs["W"], [(1, 0.0), (TOTAL, 3.0)], "LINEAR")
    cut = N("ShaderNodeMapRange")
    cut.inputs["From Min"].default_value, cut.inputs["From Max"].default_value = 0.35, 0.75
    L(noise.outputs["Fac"], cut.inputs["Value"])
    lw = N("ShaderNodeLayerWeight")
    lw.inputs["Blend"].default_value = 0.5
    soft = N("ShaderNodeMapRange")
    soft.inputs["From Min"].default_value, soft.inputs["From Max"].default_value = 0.8, 0.25
    L(lw.outputs["Facing"], soft.inputs["Value"])
    fade = N("ShaderNodeValue")
    fade.name = "Fade"
    a = N("ShaderNodeMath")
    a.operation = "MULTIPLY"
    L(cut.outputs["Result"], a.inputs[0])
    L(soft.outputs["Result"], a.inputs[1])
    b = N("ShaderNodeMath")
    b.operation, b.use_clamp = "MULTIPLY", True
    L(a.outputs[0], b.inputs[0])
    L(fade.outputs[0], b.inputs[1])
    fx._emit_mix(nt, (1.0, 0.98, 0.95), 0.9, b.outputs[0], out)
    return m


# ---------------------------------------------------------------- meshes
def torus_arc(name, major, minor, a0, a1, segs=28, ring=12):
    """Part of a torus in the XZ plane (cup handle), centred at the origin."""
    bm = bmesh.new()
    rows = []
    for i in range(segs + 1):
        a = a0 + (a1 - a0) * i / segs
        c = Vector((major * math.cos(a), 0.0, major * math.sin(a)))
        n = c.normalized()
        rows.append([bm.verts.new(c + minor * (math.cos(2 * math.pi * k / ring) * n + math.sin(2 * math.pi * k / ring) * Vector((0, 1, 0))))
                     for k in range(ring)])
    for r0, r1 in zip(rows, rows[1:]):
        for k in range(ring):
            bm.faces.new((r0[k], r0[(k + 1) % ring], r1[(k + 1) % ring], r1[k]))
    for r in (rows[0], rows[-1]):
        bm.faces.new(r)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    return me


def heart_curve(name, size):
    """Thin closed tube along a heart outline in the XZ plane (faces the lens): the steam heart."""
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "3D"
    sp = cu.splines.new("POLY")
    n = 64
    sp.points.add(n - 1)
    for i in range(n):
        t = 2 * math.pi * i / n
        x = 16 * math.sin(t) ** 3
        z = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        sp.points[i].co = (x / 16 * size, 0.0, (z + 2.5) / 16 * size, 1.0)
    sp.use_cyclic_u = True
    cu.bevel_depth, cu.bevel_resolution = 0.07 * size, 4
    return cu


def build_cup(sc):
    root = bpy.data.objects.new("Cup", None)
    sc.collection.objects.link(root)
    g, ceramic = glass(), stage.pbr("Saucer", (0.93, 0.92, 0.9), roughness=0.18, coat=0.6)
    base = 0.12
    outer = [(0.0, base), (CUP_R * 0.86, base), (CUP_R * 0.9, base + 0.08), (CUP_R, base + CUP_H), (CUP_R - 0.06, base + CUP_H + 0.02),
             (CUP_R - 0.1, base + CUP_H - 0.04), (CUP_R * 0.84, base + 0.22), (0.0, base + 0.22)]
    parts = [stage.link(sc, "Glass", stage.lathe("Glass", outer, 72), g, parent=root)]
    level = CUP_H - 0.32
    liquid = [(0.0, base + 0.225), (CUP_R * 0.84 - 0.005, base + 0.225), (CUP_R - 0.105 - 0.03 * 0.32, base + level), (0.0, base + level)]
    parts.append(stage.link(sc, "Latte", stage.lathe("Latte", liquid, 72), latte_body(), parent=root))
    saucer = [(0.0, 0.0), (1.2, 0.0), (1.95, 0.08), (2.1, 0.17), (2.05, 0.2), (1.8, 0.12), (1.3, 0.1), (0.0, 0.1)]
    parts.append(stage.link(sc, "Saucer", stage.lathe("Saucer", saucer, 72), ceramic, parent=root))
    handle = stage.link(sc, "Handle", torus_arc("Handle", 0.62, 0.11, R(-80), R(80)), g, parent=root, loc=(CUP_R - 0.05, 0.0, base + CUP_H * 0.55))
    parts.append(handle)
    art, size, heart = art_material()
    r_top = CUP_R - 0.105 - 0.03 * 0.32 - 0.005
    disc = bmesh.new()
    bmesh.ops.create_circle(disc, cap_ends=True, radius=r_top, segments=96)
    me = bpy.data.meshes.new("Art")
    disc.to_mesh(me)
    disc.free()
    parts.append(stage.link(sc, "Art", me, art, parent=root, loc=(0.0, 0.0, base + level + 0.002)))
    return root, parts, size, heart


def build_jug(sc):
    """Plain steel jug, pivoting at its lip."""
    pivot = bpy.data.objects.new("JugPivot", None)
    sc.collection.objects.link(pivot)
    steel = stage.pbr("Jug", (0.8, 0.8, 0.82), metallic=1.0, roughness=0.16)
    prof = [(0.0, -1.5), (0.55, -1.5), (0.62, -1.42), (0.66, -0.6), (0.6, -0.1), (0.64, 0.0), (0.6, 0.0), (0.56, -0.1), (0.6, -0.6),
            (0.56, -1.4), (0.0, -1.4)]
    jug = stage.link(sc, "Jug", stage.lathe("Jug", prof, 56), steel, parent=pivot, loc=(-0.6, 0.0, 0.0))
    handle = stage.link(sc, "JugHandle", torus_arc("JugHandle", 0.45, 0.07, R(100), R(260)), steel, parent=pivot, loc=(-1.2, 0.0, -0.7))
    return pivot, [jug, handle]


# ---------------------------------------------------------------- animation
def cup_x(f):
    if f < IN[1]:
        u = (f - IN[0]) / (IN[1] - IN[0])
        return 6.5 * (1 - u) ** 3 - 0.12 * math.sin(u * math.pi) * (1 - u)
    if f >= OUT[0]:
        u = (f - OUT[0]) / (OUT[1] - OUT[0])
        return -6.5 * u ** 2.2
    return 0.0


def animate(root, pivot, size, heart, stream):
    for f in range(1, TOTAL + 1):
        root.location = (cup_x(f), 0.0, GROUND_Z)
        settle = env(f, IN[1] - 6, IN[1] + 4) * (1 - env(f, IN[1] + 4, IN[1] + 14))
        root.rotation_euler = (0.0, R(4) * settle * math.sin(f * 0.9) - R(5) * (1 - env(f, IN[0], IN[1])), 0.0)
        root.keyframe_insert("location", frame=f)
        root.keyframe_insert("rotation_euler", frame=f)
        tilt = interp([(POUR[0] - 10, 0.0), (POUR[0], R(62)), (POUR[1], R(70)), (LIFT[1], R(10))], f)
        lift = interp([(1, 9.0), (POUR[0] - 10, 0.0), (LIFT[0], 0.0), (LIFT[1], 9.0)], f)   # fully out of frame above
        pivot.location = (0.25, 0.0, SURF_Z + 1.25 + lift)
        pivot.rotation_euler = (0.0, tilt, 0.0)
        pivot.keyframe_insert("location", frame=f)
        pivot.keyframe_insert("rotation_euler", frame=f)
    stage.key_socket(size.outputs[0], [(1, 0.01), (SPREAD[0], 0.01), (SPREAD[1], 0.62), (PULL[1], 0.7)])
    stage.key_socket(heart.outputs[0], [(PULL[0], 0.0), (PULL[1], 1.0)])
    top = SURF_Z + 1.2
    for f, s in ((POUR[0] - 1, 0.0), (POUR[0] + 3, 1.0), (POUR[1] - 3, 1.0), (POUR[1], 0.0)):
        stream.scale = (s if s else 0.3, s if s else 0.3, 1.0 if f < POUR[1] - 2 else 0.05)
        stream.keyframe_insert("scale", frame=f)
    stream.location = (0.25, 0.0, top)
    for f, hidden in ((1, True), (POUR[0] - 1, True), (POUR[0], False), (POUR[1], False), (POUR[1] + 1, True)):
        stream.hide_render = hidden                # thinned to a line it still showed before and after the pour
        stream.keyframe_insert("hide_render", frame=f)


def milk_stream(sc):
    me = stage.lathe("Stream", [(0.0, 0.0), (0.06, -0.02), (0.045, -0.6), (0.05, -1.18), (0.0, -1.2)], 20)
    milk = stage.pbr("Milk", MILK, roughness=0.18)
    stage.bsdf(milk).inputs["Subsurface Weight"].default_value = 0.5
    return stage.link(sc, "Stream", me, milk, shadow=False)


def steam(sc):
    """Wisps rise and close into a small heart above the glass, then fade."""
    mat = steam_material("SteamHeart")
    cu = heart_curve("SteamHeart", 0.9)
    ob = bpy.data.objects.new("SteamHeart", cu)
    sc.collection.objects.link(ob)
    cu.materials.append(mat)
    ob.visible_shadow = False
    for f, z, s in ((STEAM[0] + 8, SURF_Z + 0.6, 0.4), (STEAM[0] + 22, SURF_Z + 1.6, 1.0), (STEAM[1], SURF_Z + 2.6, 1.25)):
        ob.location = (0.0, 0.0, z)
        ob.scale = (s, s, s)
        ob.keyframe_insert("location", frame=f)
        ob.keyframe_insert("scale", frame=f)
    stage.key_socket(mat.node_tree.nodes["Fade"].outputs[0], [(STEAM[0] + 8, 0.0), (STEAM[0] + 18, 0.85), (STEAM[1] - 10, 0.7), (STEAM[1], 0.0)])
    wisps = fx.fade_material("Wisp", (1.0, 0.98, 0.95), 0.6, 0.12, 1.2)
    fx.particle_burst(sc, "Wisps", fx.ring_mesh("WispR", 0.7, 0.02, 24), wisps, 60, (STEAM[0], STEAM[1] - 16), 30, 0.28, 0.05, rand=0.2,
                      align=(0, 0, 0.9), damping=0.05, location=(0.0, 0.0, SURF_Z + 0.05))


def camera(cam):
    cam.location = (0.0, -gc.CAM_DIST * math.cos(ELEV), gc.CAM_DIST * math.sin(ELEV) - 0.5)
    cam.rotation_euler = (R(90) - ELEV, 0, 0)


def build_show(sc, opts):
    root, parts, size, heart = build_cup(sc)
    pivot, jug = build_jug(sc)
    for o in jug:                                  # lifted high, its shadow fell far below the saucer as a ghost cup
        o.visible_shadow = False
    stream = milk_stream(sc)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.9, hdri="interior.exr", lights=0.8, fog=(2.2, 6), streak=12.0)
    sc.cycles.transparent_max_bounces = 32
    sc.cycles.transmission_bounces = 12
    camera(cam)
    sh.shadow_catcher(sc, GROUND_Z, 40)
    animate(root, pivot, size, heart, stream)
    steam(sc)
    sh.screen_extent(sc, cam, parts + jug, (IN[1], POUR[0] + 10, PULL[1], STEAM[0] + 20))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """The finished latte heart, a jug-free still with steam hearts rising on a loop."""
    root, parts, size, heart = build_cup(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=0.9, hdri="interior.exr", lights=0.8, fog=(2.2, 6), streak=12.0)
    sc.cycles.transmission_bounces = 12
    root.location = (0.0, 0.0, GROUND_Z)
    size.outputs[0].default_value, heart.outputs[0].default_value = 0.7, 1.0
    sh.shadow_catcher(sc, GROUND_Z, 30)
    n = stage.ICON_N
    for k in range(2):                       # two hearts half a loop apart: seamless rise and fade
        mat = steam_material(f"IconSteam{k}")
        mat.node_tree.animation_data_clear()
        cu = heart_curve(f"IconSteam{k}", 0.7)
        ob = bpy.data.objects.new(f"IconSteam{k}", cu)
        sc.collection.objects.link(ob)
        cu.materials.append(mat)
        fade = mat.node_tree.nodes["Fade"].outputs[0]
        for f in range(0, n + 1):
            u = ((f / n) + k * 0.5) % 1.0
            ob.location = (0.0, 0.0, SURF_Z + 0.4 + 1.6 * u)
            s = 0.5 + 0.6 * u
            ob.scale = (s, s, s)
            fade.default_value = math.sin(math.pi * u) * 0.8
            ob.keyframe_insert("location", frame=f)
            ob.keyframe_insert("scale", frame=f)
            fade.keyframe_insert("default_value", frame=f)
    elev = R(26)
    sc.frame_set(1)
    stage.frame_icon(cam, parts, pad=1.25)
    d = cam.location.y
    cam.location = (cam.location.x, d * math.cos(elev), cam.location.z - d * math.sin(elev) + 0.6)
    cam.rotation_euler = (R(90) - elev, 0, 0)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
