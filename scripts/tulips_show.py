"""UZARO v2 show: tulips (tier 1, 96 f = 4 s).

Five red tulips grow up out of the bottom edge one after another; each bud swells and opens, the heads sway in a
breeze, dew drops glint on the petals, a few petals blow off and drift away, and the bunch sinks back out of frame.
Everything is built here: tube stems with growing bevel, blade leaves, cupped petal patches with translucent red.
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
from stage import R, env, interp  # noqa: E402

ID = "tulips"
TOTAL = 96
BASE_Z = -8.6                     # stems start below the frame
SINK = (80, 96)
# (x, depth y, height of the head, lean, start frame)
TULIPS = [(-0.15, 0.0, 1.9, 0.0, 3), (-1.5, 0.6, 0.6, -0.12, 10), (1.35, 0.4, 0.95, 0.1, 16), (-0.75, -0.8, -0.6, -0.05, 22),
          (0.7, -0.6, -0.15, 0.06, 28)]
GROW, OPEN = 26, 22               # frames to grow, frames to open
BLOW = ((0, 2, 58), (2, 4, 63), (4, 1, 68))    # (tulip, petal, frame it lets go)
RED = (0.62, 0.02, 0.03)


def petal_material():
    """Translucent red, darker at the base, warmer at the tip; light comes through it."""
    m = stage.pbr("Petal", RED, roughness=0.35)
    nt = m.node_tree
    N, L = nt.nodes.new, nt.links.new
    b = stage.bsdf(m)
    uv, sep, ramp = N("ShaderNodeUVMap"), N("ShaderNodeSeparateXYZ"), N("ShaderNodeValToRGB")
    L(uv.outputs[0], sep.inputs[0])
    e = ramp.color_ramp.elements
    e[0].position, e[0].color = 0.0, (0.06, 0.03, 0.01, 1)
    e[1].position, e[1].color = 1.0, (0.85, 0.08, 0.04, 1)
    e.new(0.14).color = (0.9, 0.6, 0.05, 1)                 # yellow heart at the base
    e.new(0.24).color = (*RED, 1)
    L(sep.outputs["Y"], ramp.inputs["Fac"])
    L(ramp.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Subsurface Weight"].default_value = 0.6
    b.inputs["Subsurface Radius"].default_value = (0.6, 0.08, 0.05)
    b.inputs["Sheen Weight"].default_value = 0.3
    b.inputs["Coat Weight"].default_value = 0.2
    vein = N("ShaderNodeTexWave")
    vein.wave_type, vein.bands_direction = "BANDS", "X"
    vein.inputs["Scale"].default_value, vein.inputs["Distortion"].default_value = 9.0, 2.0
    L(uv.outputs[0], vein.inputs["Vector"])
    bump = N("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.15
    L(vein.outputs["Fac"], bump.inputs["Height"])
    L(bump.outputs[0], b.inputs["Normal"])
    return m


def petal_mesh(name, length, width, cup):
    """Spoon-shaped patch along +Z from its base at the origin, hollow facing +Y (inward), UV v along the length."""
    nu, nv = 10, 14
    verts, uvs = [], []
    for j in range(nv + 1):
        v = j / nv
        w = width * math.sin(math.pi * min(1.0, 0.12 + 0.95 * v) ** 0.9) * (1 - 0.35 * v ** 3)
        for i in range(nu + 1):
            u = i / nu * 2 - 1
            x = u * w
            y = -cup * (1 - u * u) * math.sin(math.pi * v) * 0.6 + 0.12 * length * math.sin(math.pi * v * 0.8)
            z = v * length
            verts.append((x, y, z))
            uvs.append(((u + 1) / 2, v))
    faces = [(j * (nu + 1) + i, j * (nu + 1) + i + 1, (j + 1) * (nu + 1) + i + 1, (j + 1) * (nu + 1) + i) for j in range(nv) for i in range(nu)]
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    lay = me.uv_layers.new()
    for p in me.polygons:
        for li, vi in zip(p.loop_indices, p.vertices):
            lay.data[li].uv = uvs[vi]
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    return me


def leaf_mesh(name, length, width):
    """Long lance blade, folded along its midrib, curling out at the tip."""
    nu, nv = 6, 18
    verts = []
    for j in range(nv + 1):
        v = j / nv
        w = width * math.sin(math.pi * min(1.0, 0.06 + v)) ** 0.7
        for i in range(nu + 1):
            u = i / nu * 2 - 1
            verts.append((u * w, -0.25 * abs(u) * w + 0.6 * length * v * v * 0.35, v * length))
    faces = [(j * (nu + 1) + i, j * (nu + 1) + i + 1, (j + 1) * (nu + 1) + i + 1, (j + 1) * (nu + 1) + i) for j in range(nv) for i in range(nu)]
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    return me


def stem_points(top, lean):
    base = Vector((top.x - lean * 3.0, top.y, BASE_Z))
    mid = base.lerp(top, 0.6) + Vector((lean * 0.9, 0.0, 0.0))
    return [base, mid, top]


def stem_curve(name, pts):
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "3D"
    sp = cu.splines.new("BEZIER")
    sp.bezier_points.add(len(pts) - 1)
    for bp, p in zip(sp.bezier_points, pts):
        bp.co = p
        bp.handle_left_type = bp.handle_right_type = "AUTO"
    cu.bevel_depth, cu.bevel_resolution = 0.075, 3
    cu.use_fill_caps = True
    return cu


def tip_at(pts, t):
    """Point on the stem at fraction t (catmull through the same points: close enough to the auto Bezier)."""
    return Vector(stage.catmull([tuple(p) for p in pts], t))


def tulip(sc, k, x, y, h, lean, f0, petal_mat, stem_mat, rng):
    top = Vector((x, y, h))
    pts = stem_points(top, lean)
    cu = stem_curve(f"Stem{k}", pts)
    cu.materials.append(stem_mat)
    pivot = bpy.data.objects.new(f"Sway{k}", None)              # whole tulip sways about the hidden base
    sc.collection.objects.link(pivot)
    pivot.location = pts[0]
    stem = bpy.data.objects.new(f"Stem{k}", cu)
    sc.collection.objects.link(stem)
    stem.parent = pivot
    stem.location = -pts[0]
    head = bpy.data.objects.new(f"Head{k}", None)
    sc.collection.objects.link(head)
    head.parent = pivot
    parts, petals = [stem], []
    for f in range(1, TOTAL + 1):
        g = env(f, f0, f0 + GROW) * (1 - env(f, *SINK))
        cu.bevel_factor_end = max(0.001, g)
        cu.keyframe_insert("bevel_factor_end", frame=f)
        head.location = tip_at(pts, max(g, 0.001)) - pts[0]
        head.keyframe_insert("location", frame=f)
        s = env(f, f0 + GROW * 0.5, f0 + GROW) * (1 - env(f, SINK[0], SINK[0] + 8))
        head.scale = (s, s, s)
        head.keyframe_insert("scale", frame=f)
        sway = 1.0 * env(f, f0, f0 + GROW + 10)
        pivot.rotation_euler = (R(1.0) * sway * math.sin(f * 0.11 + k), R(1.6) * sway * math.sin(f * 0.09 + 1.3 * k), 0.0)
        pivot.keyframe_insert("rotation_euler", frame=f)
    d = (pts[2] - pts[1]).normalized()
    head.rotation_euler = (math.atan2(-d.y, d.z), math.atan2(d.x, d.z), 0.0)
    for i in range(6):
        outer = i % 2 == 0
        me = petal_mesh(f"Petal{k}_{i}", 0.95 if outer else 0.88, 0.42 if outer else 0.36, 0.22)
        ob = stage.link(sc, f"Petal{k}_{i}", me, petal_mat, parent=head)
        ob.rotation_mode = "XYZ"                                   # tilt about its own base first, then turn into place
        ang = 2 * math.pi * i / 6 + (0.0 if outer else 0.15)
        ob.location = (0.03 * math.sin(ang), -0.03 * math.cos(ang), 0.0)
        o0 = f0 + GROW - 2 + (0 if outer else 4)
        for f, tilt in ((o0 - 1, R(-10)), (o0 + OPEN, R(28 if outer else 18)), (SINK[0], R(36 if outer else 24))):
            ob.rotation_euler = (tilt, 0.0, ang + math.pi)
            ob.keyframe_insert("rotation_euler", frame=f)
        petals.append(ob)
        parts.append(ob)
    for side in (-1, 1):
        lf = stage.link(sc, f"Leaf{k}{side}", leaf_mesh(f"Leaf{k}{side}", 3.2 + rng.uniform(-0.4, 0.4), 0.42), stem_mat, parent=pivot)
        lf.location = tip_at(pts, 0.28) - pts[0]
        lf.rotation_euler = (R(-8), R(18) * side, R(90) * (side + 1) + rng.uniform(-0.4, 0.4))
        for f, s in ((f0 + 4, 0.0), (f0 + GROW, 1.0), (SINK[0], 1.0), (SINK[1], 0.0)):
            lf.scale = (s, s, s)
            lf.keyframe_insert("scale", frame=f)
        parts.append(lf)
    return head, petals, parts


def blow_away(petal, f_go, k):
    """Let one petal go: unparent at f_go and drift up-right on the breeze, tumbling, out of frame."""
    bpy.context.view_layer.update()
    sc = bpy.context.scene
    sc.frame_set(f_go)
    mw = petal.matrix_world.copy()
    copy = petal.copy()
    copy.animation_data_clear()
    sc.collection.objects.link(copy)
    copy.parent = None
    copy.matrix_world = mw
    loc0, rot0 = mw.to_translation(), mw.to_euler()
    for f in range(1, TOTAL + 1):
        u = max(0, f - f_go)
        copy.location = loc0 + Vector((0.09 * u + 0.002 * u * u, 0.02 * u, 0.06 * u + 0.3 * math.sin(u * 0.15 + k)))
        copy.rotation_euler = (rot0.x + 0.09 * u, rot0.y + 0.05 * u * math.sin(k), rot0.z + 0.07 * u)
        copy.hide_render = f < f_go
        for path in ("location", "rotation_euler", "hide_render"):
            copy.keyframe_insert(path, frame=f)
    for f in range(1, TOTAL + 1):
        petal.hide_render = f >= f_go
        petal.keyframe_insert("hide_render", frame=f)
    return copy


def dew(sc, heads):
    """A few glass drops on the outer petals, each with a glint that flares once."""
    water = stage.pbr("Dew", (1.0, 1.0, 1.0), roughness=0.0, transmission=1.0, ior=1.33)
    rng = stage.seeded(4)
    glint = stage.emit("Glint", (1.0, 0.95, 0.85), 0.0)
    for k, (head, petals) in enumerate(heads):
        for n in range(3):
            p = petals[2 * rng.randrange(3)]
            d = stage.link(sc, f"Dew{k}{n}", gc.ico_mesh(f"Dew{k}{n}", 0.035 + 0.02 * rng.random(), 3), water, parent=p,
                           loc=(rng.uniform(-0.15, 0.15), -0.05, rng.uniform(0.35, 0.75)))
            d.data.polygons.foreach_set("use_smooth", [True] * len(d.data.polygons))
    sock = glint.node_tree.nodes["Emission"].inputs["Strength"]
    stage.key_socket(sock, [(44, 0.0), (48, 60.0), (52, 0.0), (64, 0.0), (68, 60.0), (72, 0.0)])
    for k, (head, petals) in enumerate(heads[:3]):
        g = stage.link(sc, f"Glint{k}", gc.ico_mesh(f"Glint{k}", 0.02, 2), glint, parent=petals[0], loc=(0.05, -0.08, 0.6), shadow=False)
        g.cycles.use_motion_blur = False


def build_show(sc, opts):
    rng = stage.seeded(11)
    petal_mat = petal_material()
    stem_mat = stage.pbr("Stem", (0.1, 0.3, 0.06), roughness=0.45)
    stage.bsdf(stem_mat).inputs["Subsurface Weight"].default_value = 0.3
    heads, parts = [], []
    for k, (x, y, h, lean, f0) in enumerate(TULIPS):
        head, petals, p = tulip(sc, k, x, y, h, lean, f0, petal_mat, stem_mat, rng)
        heads.append((head, petals))
        parts += p
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.9, hdri="sunrise.exr", lights=0.8, fog=(2.0, 6), streak=12.0)
    for k, i, f in BLOW:
        blow_away(heads[k][1][i], f, k)
    dew(sc, heads)
    pollen = fx.fade_material("Pollen", (1.0, 0.85, 0.4), 6.0, power=1.5)
    fx.particle_burst(sc, "Pollen", fx.point_mesh("PollenSrc", 1.6), pollen, 80, (32, 76), 24, 0.02, 0.15, rand=0.3,
                      align=(0.25, 0.0, 0.2), damping=0.05, location=(0.0, 0.0, 0.6))
    sc.frame_set(1)
    sh.screen_extent(sc, cam, [p for p in parts if p.type == "MESH"], (40, 56, 76))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Three open tulips swaying on a loop."""
    global TULIPS, SINK
    TULIPS = [(0.0, 0.0, 0.9, 0.0, -60), (-0.9, 0.5, 0.2, -0.1, -60), (0.85, 0.4, 0.35, 0.1, -60)]
    SINK = (10_000, 10_001)
    rng = stage.seeded(11)
    petal_mat = petal_material()
    stem_mat = stage.pbr("Stem", (0.1, 0.3, 0.06), roughness=0.45)
    cam = stage.setup_icon(sc, opts["samples"], world=0.9, hdri="sunrise.exr", lights=0.8, fog=(2.0, 6), streak=12.0)
    parts, pivots = [], []
    for k, (x, y, h, lean, f0) in enumerate(TULIPS):
        _, _, p = tulip(sc, k, x, y, h, lean, f0, petal_mat, stem_mat, rng)
        parts += p
    n = stage.ICON_N
    for k in range(len(TULIPS)):
        piv = sc.objects[f"Sway{k}"]
        piv.animation_data_clear()
        for f in range(0, n + 1):
            w = 2 * math.pi * f / n
            piv.rotation_euler = (R(1.2) * math.sin(w + k), R(1.8) * math.sin(w + 1.3 * k), 0.0)
            piv.keyframe_insert("rotation_euler", frame=f)
    sc.frame_set(1)
    heads = [o for o in parts if o.name.startswith("Petal")]
    stage.frame_icon(cam, heads, pad=1.6)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
