"""UZARO v2 show: uzaro (tier 4, 168 f = 7 s). The house gift: the UZARO mark itself, built here in 3D from the logo.

Design (ours, from mobile/assets/logo.png): two figures, one royal blue and one teal, whose bodies curve down and meet
as the letter U; a gold ribbon runs round the bottom of the U, and a white chat bubble with three dots sits between them.
Show: the two figures materialise from opposite sides in blue and teal sparks and swing into place, their heads pop in,
they lean toward each other, the gold ribbon sweeps round the U, the chat bubble pops up between them and its dots
"type"; on the hero beat the mark flares with a gold burst and ring, turns to show its depth, then dissolves into sparks.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R  # noqa: E402

ID = "uzaro"
TOTAL = 168
SCALE = 1.9
ROOT_Z = 0.4
FLY_L, FLY_R, FLY_LEN = 3, 7, 18              # the two figures swing in from the sides
HEAD_L, HEAD_R = 14, 18
LEAN = (26, 40)
BAND = (30, 46)                               # gold ribbon sweeps round the U
BUBBLE = 44                                   # chat bubble pops up
DOTS = (54, 59, 64)
TYPE = (66, 126)                              # dots bounce like typing
HERO = 78
TURN = (88, 136)
OUT = (136, 152)                              # dissolve into sparks
BLUE_LO, BLUE_HI = (0.003, 0.028, 0.24), (0.012, 0.15, 0.62)    # logo sRGB ~#0A328C .. #1E6ED2
TEAL_LO, TEAL_HI = (0.0, 0.07, 0.08), (0.006, 0.3, 0.26)       # logo sRGB ~#006E6E .. #20B2AA
GOLD = (1.0, 0.72, 0.3)
NAVY = (0.01, 0.05, 0.32)
WHITE = (0.92, 0.94, 0.97)

# logo outlines in logo units (x right, z up; 1 unit = 100 px of the 512 px logo, U bottom at z -1.55)
LEFT = [(-0.42, 1.1), (-0.42, 0.25), (-0.27, -0.35), (0.12, -0.8), (0.6, -1.08), (1.0, -1.16), (0.72, -1.42),
        (0.1, -1.56), (-0.5, -1.46), (-1.06, -1.1), (-1.42, -0.5), (-1.52, 0.3), (-1.5, 1.18), (-1.2, 1.42),
        (-0.9, 1.47), (-0.58, 1.4)]
RIGHT = [(0.42, 1.1), (0.58, 1.4), (0.9, 1.47), (1.2, 1.42), (1.5, 1.18), (1.52, 0.5), (1.45, -0.2), (1.2, -0.66),
         (0.8, -0.93), (0.42, -0.9), (0.3, -0.6), (0.42, 0.0)]
RIBBON = [(1.52, -0.05, "V"), (1.46, -0.7), (1.05, -1.2), (0.42, -1.42), (-0.2, -1.36, "V"), (0.42, -1.18), (0.92, -0.98),
          (1.28, -0.6)]
BUBBLE_PTS = [(-0.64, 0.3), (-0.52, 0.46), (0.52, 0.46), (0.64, 0.3), (0.64, -0.4), (0.52, -0.55), (-0.18, -0.55),
              (-0.5, -0.84, "V"), (-0.4, -0.55), (-0.52, -0.55), (-0.64, -0.4)]
HEADS = ((-0.9, 1.84), (0.9, 1.84))
HEAD_R = 0.36
PIVOT_L, PIVOT_R = (-0.6, -1.3), (0.6, -0.9)
TAIL = (-0.5, -0.84)


# ------------------------------------------------------------------ helpers
def ease_back(x, s=1.5):
    x = min(max(x, 0.0), 1.0) - 1.0
    return 1.0 + x * x * ((s + 1.0) * x + s)


def ramp01(f, a, b):
    return stage.smooth(min(max((f - a) / (b - a), 0.0), 1.0))


def slab(sc, name, pts, depth, bevel):
    """A flat shape from a closed smooth outline (auto handles; 'V' marks a sharp point), extruded to depth either side
    with rounded edges, converted to a mesh in the XZ plane facing -Y."""
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions, cu.fill_mode = "2D", "BOTH"
    cu.extrude, cu.bevel_depth, cu.bevel_resolution, cu.resolution_u = depth, bevel, 5, 24
    sp = cu.splines.new("BEZIER")
    sp.bezier_points.add(len(pts) - 1)
    for bp, p in zip(sp.bezier_points, pts):
        bp.co = (p[0], p[1], 0.0)
        bp.handle_left_type = bp.handle_right_type = "VECTOR" if len(p) > 2 else "AUTO"
    sp.use_cyclic_u = True
    sp.use_smooth = True
    tmp = bpy.data.objects.new(f"{name}Tmp", cu)
    sc.collection.objects.link(tmp)
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(tmp.evaluated_get(dg))
    bpy.data.objects.remove(tmp)
    bpy.data.curves.remove(cu)
    me.name = name
    me.transform(Matrix.Rotation(R(90), 4, "X"))
    return me


def ellipsoid(name, r, segs=40):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=segs // 2, radius=1.0)
    bmesh.ops.scale(bm, vec=r, verts=bm.verts)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = True
    return me


def math_node(nt, op, a, b=None):
    n = nt.nodes.new("ShaderNodeMath")
    n.operation = op
    for i, x in enumerate((a, b)):
        if x is None:
            continue
        if isinstance(x, (int, float)):
            n.inputs[i].default_value = x
        else:
            nt.links.new(x, n.inputs[i])
    return n.outputs[0]


# ------------------------------------------------------------------ materials
def gradient_material(name, lo, hi, z0, z1):
    """Glossy lacquer whose colour runs from lo (bottom) to hi (top) like the logo's shading."""
    m = stage.pbr(name, hi, roughness=0.2, coat=1.0)
    nt = m.node_tree
    tc, sep, ramp = nt.nodes.new("ShaderNodeTexCoord"), nt.nodes.new("ShaderNodeSeparateXYZ"), nt.nodes.new("ShaderNodeValToRGB")
    nt.links.new(tc.outputs["Object"], sep.inputs[0])
    t = math_node(nt, "DIVIDE", math_node(nt, "SUBTRACT", sep.outputs["Z"], z0), z1 - z0)
    nt.links.new(t, ramp.inputs["Fac"])
    els = ramp.color_ramp.elements
    els[0].color, els[1].color = (*lo, 1), (*hi, 1)
    nt.links.new(ramp.outputs["Color"], stage.bsdf(m).inputs["Base Color"])
    return m


def reveal(mat, out_keys, wipe_keys=None, edge=GOLD):
    """Materialise / dissolve: the surface shows where object-space noise is below a keyed threshold (and, with
    wipe_keys, where x is past a keyed line), with a glowing seam on the boundary."""
    nt = mat.node_tree
    N, L = nt.nodes.new, nt.links.new
    out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL" and n.is_active_output)
    shader = out.inputs["Surface"].links[0].from_socket
    tc, noise = N("ShaderNodeTexCoord"), N("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value, noise.inputs["Detail"].default_value = 2.2, 6.0
    L(tc.outputs["Object"], noise.inputs["Vector"])
    thr = N("ShaderNodeValue")
    stage.key_socket(thr.outputs[0], out_keys)
    n = noise.outputs["Fac"]
    vis = math_node(nt, "LESS_THAN", n, thr.outputs[0])
    seam = math_node(nt, "GREATER_THAN", n, math_node(nt, "SUBTRACT", thr.outputs[0], 0.03))
    if wipe_keys:
        sep, w = N("ShaderNodeSeparateXYZ"), N("ShaderNodeValue")
        L(tc.outputs["Object"], sep.inputs[0])
        stage.key_socket(w.outputs[0], wipe_keys)
        vis = math_node(nt, "MULTIPLY", vis, math_node(nt, "GREATER_THAN", sep.outputs["X"], w.outputs[0]))
        seam = math_node(nt, "MAXIMUM", seam, math_node(nt, "LESS_THAN", sep.outputs["X"], math_node(nt, "ADD", w.outputs[0], 0.1)))
    seam = math_node(nt, "MULTIPLY", seam, vis)
    tr, mix, em, add = N("ShaderNodeBsdfTransparent"), N("ShaderNodeMixShader"), N("ShaderNodeEmission"), N("ShaderNodeAddShader")
    L(vis, mix.inputs[0])
    L(tr.outputs[0], mix.inputs[1])
    L(shader, mix.inputs[2])
    em.inputs["Color"].default_value = (*edge, 1)
    L(math_node(nt, "MULTIPLY", seam, 14.0), em.inputs["Strength"])
    L(mix.outputs[0], add.inputs[0])
    L(em.outputs[0], add.inputs[1])
    L(add.outputs[0], out.inputs["Surface"])


# ------------------------------------------------------------------ the mark
def empty(sc, name, parent, loc=(0.0, 0.0, 0.0)):
    e = bpy.data.objects.new(name, None)
    sc.collection.objects.link(e)
    e.parent, e.location = parent, loc
    return e


def build(sc):
    root = empty(sc, "UzaroRoot", None, (0.0, 0.0, ROOT_Z))
    mats = {
        "blue": gradient_material("Blue", BLUE_LO, BLUE_HI, -1.5, 1.5),
        "teal": gradient_material("Teal", TEAL_LO, TEAL_HI, -1.0, 1.5),
        "blue_head": gradient_material("BlueHead", (0.006, 0.07, 0.42), (0.02, 0.2, 0.7), -0.4, 0.4),
        "teal_head": gradient_material("TealHead", (0.005, 0.24, 0.21), (0.02, 0.42, 0.36), -0.4, 0.4),
        "gold": stage.pbr("Gold", GOLD, metallic=1.0, roughness=0.18),
        "white": stage.pbr("Bubble", WHITE, roughness=0.15, coat=1.0),
        "navy": stage.pbr("Dot", NAVY, roughness=0.2, coat=1.0),
    }
    parts = {}
    for side, pts, pivot, mat, hmat, (hx, hz), y in (("L", LEFT, PIVOT_L, "blue", "blue_head", HEADS[0], 0.0),
                                                       ("R", RIGHT, PIVOT_R, "teal", "teal_head", HEADS[1], 0.03)):
        e = empty(sc, f"Half{side}", root, (pivot[0], y, pivot[1]))
        body = stage.link(sc, f"Body{side}", slab(sc, f"BodyMesh{side}", pts, 0.16, 0.05), mats[mat], parent=e,
                          loc=(-pivot[0], 0.0, -pivot[1]))
        he = empty(sc, f"HeadE{side}", e, (hx - pivot[0], 0.0, hz - pivot[1]))
        head = stage.link(sc, f"Head{side}", ellipsoid(f"HeadMesh{side}", (HEAD_R, 0.2, HEAD_R)), mats[hmat], parent=he)
        parts[side] = (e, he, body, head)
    ribbon = stage.link(sc, "Ribbon", slab(sc, "RibbonMesh", RIBBON, 0.05, 0.03), mats["gold"], parent=root,
                        loc=(0.0, -0.2, 0.0))
    be = empty(sc, "BubbleE", root, (TAIL[0], -0.3, TAIL[1]))
    bubble = stage.link(sc, "Bubble", slab(sc, "BubbleMesh", BUBBLE_PTS, 0.07, 0.04), mats["white"], parent=be,
                        loc=(-TAIL[0], 0.0, -TAIL[1]))
    dots = []
    for i, x in enumerate((-0.32, 0.0, 0.32)):
        de = empty(sc, f"DotE{i}", be, (x - TAIL[0], -0.12, -0.04 - TAIL[1]))
        stage.link(sc, f"Dot{i}", ellipsoid(f"DotMesh{i}", (0.11, 0.05, 0.11), 24), mats["navy"], parent=de)
        dots.append(de)
    meshes = [o for o in sc.objects if o.type == "MESH"]
    return root, parts, ribbon, be, dots, mats, meshes


# ------------------------------------------------------------------ animation
def dot_bounce(f, i, a, period):
    return 0.11 * max(0.0, math.sin(2 * math.pi * (f - a) / period - i * 2 * math.pi / 3)) ** 2


def animate(root, parts, be, dots):
    for f in range(1, TOTAL + 1):
        for side, start, sgn, head_at in (("L", FLY_L, -1, HEAD_L), ("R", FLY_R, 1, HEAD_R)):
            e, he, _, _ = parts[side]
            k = ease_back((f - start) / FLY_LEN, 1.2)
            px, pz = PIVOT_L if side == "L" else PIVOT_R
            e.location = (px + sgn * 2.8 * (1 - k), e.location.y, pz + 1.1 * (1 - k))
            lean = R(5) * math.sin(math.pi * ramp01(f, *LEAN)) - R(55) * (1 - k)   # + tips the top toward the middle
            e.rotation_euler = (0.0, -sgn * lean, 0.0)
            e.keyframe_insert("location", frame=f)
            e.keyframe_insert("rotation_euler", frame=f)
            s = max(ease_back((f - head_at) / 10.0, 2.2), 0.0)
            he.scale = (s, s, s)
            he.keyframe_insert("scale", frame=f)
        s = max(ease_back((f - BUBBLE) / 12.0, 2.0), 0.0)
        be.scale = (s, s, s)
        be.rotation_euler = (0.0, R(-14) * (1 - min(s, 1.0)), 0.0)
        be.keyframe_insert("scale", frame=f)
        be.keyframe_insert("rotation_euler", frame=f)
        for i, de in enumerate(dots):
            s = max(ease_back((f - DOTS[i]) / 7.0, 2.5), 0.0)
            de.scale = (s, s, s)
            bounce = dot_bounce(f, i, TYPE[0], 18.0) * ramp01(f, TYPE[0], TYPE[0] + 6) * (1 - ramp01(f, TYPE[1] - 6, TYPE[1]))
            de.location.z = -0.04 - TAIL[1] + bounce
            de.keyframe_insert("scale", frame=f)
            de.keyframe_insert("location", frame=f)
        pulse = 0.07 * math.sin(math.pi * min(max((f - HERO + 3) / 12.0, 0.0), 1.0))
        sc_ = SCALE * (1 + pulse)
        root.scale = (sc_, sc_, sc_)
        turn = R(28) * math.sin(2 * math.pi * (f - TURN[0]) / (TURN[1] - TURN[0])) * ramp01(f, TURN[0], TURN[0] + 6) \
            * (1 - ramp01(f, TURN[1] - 6, TURN[1]))
        root.rotation_euler = (R(4) * math.sin(f / 13.0), 0.0, turn)
        root.location.z = ROOT_Z + 0.06 * math.sin(2 * math.pi * f / 56.0)
        for path in ("scale", "rotation_euler", "location"):
            root.keyframe_insert(path, frame=f)


def materialise(mats):
    out = [(OUT[0], 1.05), (OUT[1], -0.05)]
    reveal(mats["blue"], [(FLY_L, -0.05), (FLY_L + 16, 1.05)] + out, edge=(0.3, 0.6, 1.0))
    reveal(mats["blue_head"], [(HEAD_L, -0.05), (HEAD_L + 8, 1.05)] + out, edge=(0.3, 0.6, 1.0))
    reveal(mats["teal"], [(FLY_R, -0.05), (FLY_R + 16, 1.05)] + out, edge=(0.3, 1.0, 0.85))
    reveal(mats["teal_head"], [(HEAD_R, -0.05), (HEAD_R + 8, 1.05)] + out, edge=(0.3, 1.0, 0.85))
    reveal(mats["gold"], [(1, 1.05)] + out, wipe_keys=[(BAND[0], 1.62), (BAND[1], -0.3)], edge=(1.0, 0.85, 0.5))
    for k in ("white", "navy"):
        reveal(mats[k], [(1, 1.05)] + out, edge=GOLD)


def sparkle(sc, root, parts, ribbon):
    blue = fx.fade_material("SparkBlue", (0.35, 0.6, 1.0), 9.0)
    teal = fx.fade_material("SparkTeal", (0.3, 1.0, 0.85), 9.0)
    gold = fx.fade_material("SparkGold", (1.0, 0.82, 0.5), 10.0)
    z = ROOT_Z
    for name, mat, x, start in (("InL", blue, -1.9, FLY_L), ("InR", teal, 1.9, FLY_R)):
        em = fx.particle_burst(sc, name, fx.point_mesh(f"{name}Src", 1.2), mat, 220, (start + 4, start + 18), 18, 0.03, 0.9,
                               rand=1.0, align=(0.0, 0.0, 0.5), damping=0.35, gravity=-0.04, location=(x, -0.3, z))
        em.scale = (1.0, 0.4, 1.6)
    band = fx.particle_burst(sc, "Band", ribbon.data.copy(), gold, 240, BAND, 16, 0.025, 0.5, rand=0.8,
                             align=(0.0, 0.0, 0.6), damping=0.4, gravity=-0.05)
    band.parent = root
    band.location = ribbon.location
    hero = fx.particle_burst(sc, "Hero", fx.point_mesh("HeroSrc", 1.6), gold, 420, (HERO, HERO + 6), 22, 0.035, 3.2,
                             rand=1.0, align=(0.0, 0.0, 0.4), damping=0.3, gravity=-0.1, location=(0.0, -0.4, z))
    hero.scale = (1.3, 0.3, 1.5)
    fx.shock_ring(sc, "Ring", (0.0, -0.2, z - 1.55 * SCALE - 0.1), (HERO, HERO + 22), 5.0, GOLD, 3.0, width=0.06)
    glint = fx.particle_burst(sc, "Glint", fx.point_mesh("GlintSrc", 3.4), gold, 160, (HERO + 8, OUT[0]), 22, 0.02, 0.2,
                              rand=0.6, align=(0.0, 0.0, 0.25), damping=0.5, gravity=0.0, location=(0.0, -0.5, z))
    glint.scale = (1.0, 0.2, 1.2)
    for side, mat in (("L", blue), ("R", teal)):
        _, _, body, _ = parts[side]
        em = fx.particle_burst(sc, f"Out{side}", body.data.copy(), mat, 420, (OUT[0], OUT[1] - 4), 16, 0.03, 0.8,
                               rand=1.0, align=(0.0, 0.0, 0.7), damping=0.3, gravity=-0.08)
        em.parent = body
    out_g = fx.particle_burst(sc, "OutGold", ribbon.data.copy(), gold, 200, (OUT[0], OUT[1] - 4), 16, 0.03, 0.8,
                              rand=1.0, align=(0.0, 0.0, 0.7), damping=0.3, gravity=-0.08)
    out_g.parent = ribbon


def build_show(sc, opts):
    root, parts, ribbon, be, dots, mats, meshes = build(sc)
    animate(root, parts, be, dots)
    materialise(mats)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.9, hdri="sunrise.exr", lights=0.9, fog=(2.0, 6), streak=10.0)
    sc.cycles.transparent_max_bounces = 32
    sh.shadow_catcher(sc, ROOT_Z - 1.6 * SCALE - 0.5, 40)
    sparkle(sc, root, parts, ribbon)
    sh.screen_extent(sc, cam, meshes, (1, 12, 30, HERO, TURN[0] + 12, 124, OUT[1], TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """The mark at rest, dots typing once per loop and a slow sway to show its depth."""
    n = stage.ICON_N
    root, parts, ribbon, be, dots, mats, meshes = build(sc)
    root.scale = (SCALE,) * 3
    frames = range(1, n + 2)
    for f in frames:
        root.rotation_euler = (0.0, 0.0, R(10) * math.sin(2 * math.pi * (f - 1) / n))
        root.keyframe_insert("rotation_euler", frame=f)
        for i, de in enumerate(dots):
            de.location.z = -0.04 - TAIL[1] + dot_bounce(f, i, 1, n)
            de.keyframe_insert("location", frame=f)
    cam = stage.setup_icon(sc, opts["samples"], world=0.9, hdri="sunrise.exr", lights=0.9, fog=(2.0, 6), streak=8.0)
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.26)                          # 1.08 covered 57.6 % of the icon (limit 50 %)
    sh.shadow_catcher(sc, gc.world_bbox(meshes)[0].z - 0.3, 30)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
