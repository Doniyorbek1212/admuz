"""UZARO v2 show: guitar (tier 2, 120 f = 5 s). An original UZARO electric guitar, built here from scratch.

Design (ours, not a copy of any maker's model): an offset double-cutaway body with a long swept bass horn, an indigo
to violet candy finish over a gold-and-turquoise ikat flame (the atlas silk weave), gold hardware, ebony fretboard with
eight-point girih star inlays, and a forked "U" headstock with the UZARO wordmark.
Show: it spins in from below, the star inlays light up one after another from the body to the head, a golden pick
strums twice (the strings shake, a ring of light and a spray of notes burst out, the second strum bigger with sparks
and a camera kick), then it turns once on the spot and flies out to the top right.
"""
import math
import os
import random
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R  # noqa: E402

ID = "guitar"
TOTAL = 120
ARRIVE, LIGHT, STRUM1, STRUM2, TURN, LEAVE = 28, 30, 46, 70, 86, 102
SCALE = 1.45                                   # the guitar is modelled ~7 units long; this fills the frame
HOLD_Z = -2.5
THICK = 0.32                                   # body thickness (Y)
TOP_Y = -THICK / 2                             # front face of the body (camera side is -Y)
NUT_Z, BRIDGE_Z = 4.2, -0.85
SCALE_L = NUT_Z - BRIDGE_Z
FRETS = 22
INLAY_FRETS = (3, 5, 7, 9, 12, 15, 17, 19, 21)
GOLD = (1.0, 0.74, 0.34)
INDIGO, VIOLET = (0.03, 0.02, 0.16), (0.32, 0.04, 0.42)
IKAT = [(1.0, 0.7, 0.25), (0.1, 0.75, 0.7)]
NOTE_COLOURS = [(1.0, 0.78, 0.35), (1.0, 0.35, 0.75), (0.3, 0.85, 1.0)]
BODY = [(0.0, -1.55), (0.78, -1.46), (1.2, -1.02), (1.24, -0.38), (0.98, 0.08), (1.06, 0.52), (0.98, 0.98),
        (0.74, 1.14), (0.55, 0.86), (0.3, 0.64), (-0.3, 0.64), (-0.52, 0.98), (-0.74, 1.44), (-1.0, 1.32),
        (-1.1, 0.82), (-1.0, 0.22), (-1.27, -0.4), (-1.22, -1.06), (-0.8, -1.47)]
HEAD = [(-0.2, 4.15), (-0.34, 4.45), (-0.4, 5.05), (-0.3, 5.5), (-0.14, 5.46), (-0.08, 5.02), (0.0, 4.92),
        (0.08, 5.02), (0.14, 5.46), (0.3, 5.5), (0.4, 5.05), (0.34, 4.45), (0.2, 4.15)]


# ------------------------------------------------------------------ geometry
def spline(points, n=10):
    """Closed Catmull-Rom through the control points."""
    out = []
    for i in range(len(points)):
        p = [Vector(points[(i + k - 1) % len(points)]) for k in range(4)]
        for s in range(n):
            out.append(Vector(stage.catmull(p, (1 + s / n) / 3)))      # the p1..p2 span of the four
    return out


def slab(name, outline, y0, y1, bevel=0.03):
    """Outline in XZ extruded from y0 to y1, edges rounded by a bevel modifier."""
    bm = bmesh.new()
    top = [bm.verts.new((p.x, y0, p.y)) for p in outline]
    bot = [bm.verts.new((p.x, y1, p.y)) for p in outline]
    bm.faces.new(top)
    bm.faces.new(list(reversed(bot)))
    n = len(outline)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((top[i], top[j], bot[j], bot[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    if bevel:
        bv = ob.modifiers.new("Round", "BEVEL")
        bv.width, bv.segments, bv.limit_method = bevel, 3, "ANGLE"
        bv.harden_normals = True
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    return ob


def box(name, x, y, z, loc):
    me = stage.box_mesh(name, x, y, z)
    me.transform(Matrix.Translation(loc))
    return me


def star_outline(r, inner=0.62, points=8, rot=0.0):
    return [Vector(((r if k % 2 == 0 else r * inner) * math.cos(rot + math.pi * k / points),
                    (r if k % 2 == 0 else r * inner) * math.sin(rot + math.pi * k / points))) for k in range(2 * points)]


def cyl_y(name, r, y0, y1, segs=24):
    me = stage.lathe(name, [(0.0, y0), (r, y0), (r, y1), (0.0, y1)], segs)
    me.transform(Matrix.Rotation(R(-90), 4, "X"))           # lathe axis Z -> +Y (into the body)
    return me


def note_mesh(name):
    """An eighth note in the XZ plane: tilted oval head, stem and a curved flag, 0.05 thick."""
    head = [Vector((0.16 * math.cos(a) * math.cos(R(25)) - 0.11 * math.sin(a) * math.sin(R(25)),
                    0.16 * math.cos(a) * math.sin(R(25)) + 0.11 * math.sin(a) * math.cos(R(25))))
            for a in [2 * math.pi * k / 20 for k in range(20)]]
    stem = [Vector(p) for p in ((0.11, 0.04), (0.15, 0.04), (0.15, 0.62), (0.11, 0.62))]
    flag = [Vector(p) for p in ((0.15, 0.62), (0.3, 0.46), (0.36, 0.28), (0.3, 0.12), (0.34, 0.3), (0.26, 0.46), (0.15, 0.5))]
    bm = bmesh.new()
    for poly in (head, stem, flag):
        a = [bm.verts.new((p.x, -0.025, p.y)) for p in poly]
        b = [bm.verts.new((p.x, 0.025, p.y)) for p in poly]
        bm.faces.new(a)
        bm.faces.new(list(reversed(b)))
        for i in range(len(poly)):
            j = (i + 1) % len(poly)
            bm.faces.new((a[i], a[j], b[j], b[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    me.transform(Matrix.Translation((-0.12, 0.0, -0.25)))
    return me


# ------------------------------------------------------------------ materials
def candy_material():
    """Indigo edges to violet centre (a burst), metal flake under a deep clear coat, ikat flames floating in it."""
    m = stage.pbr("Candy", VIOLET, metallic=0.35, roughness=0.32, coat=1.0)
    b = stage.bsdf(m)
    b.inputs["Coat Roughness"].default_value = 0.03
    nt = m.node_tree
    N, L = nt.nodes.new, nt.links.new
    tc = N("ShaderNodeTexCoord")
    sep = N("ShaderNodeSeparateXYZ")
    L(tc.outputs["Object"], sep.inputs[0])
    rad = N("ShaderNodeVectorMath")
    rad.operation = "LENGTH"
    L(tc.outputs["Object"], rad.inputs[0])
    burst = N("ShaderNodeMapRange")
    burst.inputs["From Min"].default_value, burst.inputs["From Max"].default_value = 0.4, 1.4
    L(rad.outputs["Value"], burst.inputs["Value"])
    base = N("ShaderNodeMixRGB")
    L(burst.outputs["Result"], base.inputs["Fac"])
    base.inputs["Color1"].default_value, base.inputs["Color2"].default_value = (*VIOLET, 1), (*INDIGO, 1)
    # ikat: vertical bands, their edges torn by noise (the resist-dye bleed), two colours alternating
    noise = N("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value, noise.inputs["Detail"].default_value = 3.0, 6.0
    L(tc.outputs["Object"], noise.inputs["Vector"])
    warp = N("ShaderNodeMath")
    warp.operation = "MULTIPLY_ADD"
    L(noise.outputs["Fac"], warp.inputs[0])
    warp.inputs[1].default_value = 0.55
    L(sep.outputs["X"], warp.inputs[2])
    bands = N("ShaderNodeMath")
    bands.operation = "SINE"
    scale = N("ShaderNodeMath")
    scale.operation = "MULTIPLY"
    scale.inputs[1].default_value = 15.0
    L(warp.outputs[0], scale.inputs[0])
    L(scale.outputs[0], bands.inputs[0])
    flame = N("ShaderNodeMapRange")
    flame.inputs["From Min"].default_value, flame.inputs["From Max"].default_value = 0.55, 0.8
    L(bands.outputs[0], flame.inputs["Value"])
    pick = N("ShaderNodeMath")
    pick.operation = "SINE"
    sc2 = N("ShaderNodeMath")
    sc2.operation = "MULTIPLY"
    sc2.inputs[1].default_value = 7.5
    L(warp.outputs[0], sc2.inputs[0])
    L(sc2.outputs[0], pick.inputs[0])
    tint = N("ShaderNodeMixRGB")
    L(pick.outputs[0], tint.inputs["Fac"])
    tint.inputs["Color1"].default_value, tint.inputs["Color2"].default_value = (*IKAT[1], 1), (*IKAT[0], 1)
    amount = N("ShaderNodeMath")
    amount.operation = "MULTIPLY"
    amount.inputs[1].default_value = 0.55
    L(flame.outputs["Result"], amount.inputs[0])
    mix = N("ShaderNodeMixRGB")
    L(amount.outputs[0], mix.inputs["Fac"])
    L(base.outputs["Color"], mix.inputs["Color1"])
    L(tint.outputs["Color"], mix.inputs["Color2"])
    L(mix.outputs["Color"], b.inputs["Base Color"])
    met = N("ShaderNodeMath")
    met.operation = "MULTIPLY_ADD"
    L(amount.outputs[0], met.inputs[0])
    met.inputs[1].default_value, met.inputs[2].default_value = 0.5, 0.35
    L(met.outputs[0], b.inputs["Metallic"])
    return m


def wood_material(name, rgb, dark):
    m = stage.pbr(name, rgb, roughness=0.45, coat=0.6)
    b = stage.bsdf(m)
    nt = m.node_tree
    wave = nt.nodes.new("ShaderNodeTexWave")
    wave.inputs["Scale"].default_value, wave.inputs["Distortion"].default_value = 3.0, 6.0
    wave.bands_direction = "Z"
    mix = nt.nodes.new("ShaderNodeMixRGB")
    nt.links.new(wave.outputs["Fac"], mix.inputs["Fac"])
    mix.inputs["Color1"].default_value, mix.inputs["Color2"].default_value = (*rgb, 1), (*dark, 1)
    nt.links.new(mix.outputs["Color"], b.inputs["Base Color"])
    return m


def mats():
    return {
        "candy": candy_material(),
        "back": stage.pbr("Back", INDIGO, metallic=0.4, roughness=0.3, coat=1.0),
        "maple": wood_material("Maple", (0.62, 0.36, 0.16), (0.42, 0.22, 0.08)),
        "ebony": stage.pbr("Ebony", (0.015, 0.012, 0.01), roughness=0.35, coat=0.3),
        "gold": stage.pbr("Gold", GOLD, metallic=1.0, roughness=0.18),
        "steel": stage.pbr("Steel", (0.85, 0.85, 0.88), metallic=1.0, roughness=0.16),
        "pickup": stage.pbr("Pickup", (0.01, 0.01, 0.012), roughness=0.25, coat=0.8),
        "pearl": stage.pbr("Pearl", (0.92, 0.95, 1.0), roughness=0.15, coat=1.0, emission=(0.75, 0.9, 1.0), strength=0.0),
    }


# ------------------------------------------------------------------ build
def build_guitar(sc):
    """All parts parented to a spinner empty; returns (root, spinner, strings, inlay material, pick, meshes)."""
    root = bpy.data.objects.new("GuitarRoot", None)
    spin = bpy.data.objects.new("GuitarSpin", None)
    for o in (root, spin):
        sc.collection.objects.link(o)
    spin.parent = root
    M = mats()
    parts = []

    def add(ob, mat):
        sc.collection.objects.link(ob)
        ob.data.materials.append(mat)
        ob.parent = spin
        parts.append(ob)
        return ob

    body = add(slab("Body", spline(BODY), TOP_Y, -TOP_Y, bevel=0.06), M["candy"])
    body.data.materials.append(M["back"])
    for p in body.data.polygons:                    # back and sides indigo, the top keeps the candy flame
        if p.normal.y > -0.5:
            p.material_index = 1
    add(slab("Neck", [Vector(p) for p in ((-0.28, 0.3), (0.28, 0.3), (0.22, NUT_Z), (-0.22, NUT_Z))], TOP_Y - 0.02, TOP_Y + 0.2, 0.02), M["maple"])
    board = add(slab("Board", [Vector(p) for p in ((-0.29, 0.45), (0.29, 0.45), (0.22, NUT_Z), (-0.22, NUT_Z))], TOP_Y - 0.1, TOP_Y - 0.02, 0.008), M["ebony"])
    head = add(slab("Head", spline(HEAD, 6), TOP_Y - 0.06, TOP_Y + 0.06, 0.02), M["candy"])
    head.data.materials.append(M["back"])
    for p in head.data.polygons:
        if p.normal.y > -0.5:
            p.material_index = 1
    fy = TOP_Y - 0.1
    bm = bmesh.new()
    for n in range(FRETS + 1):
        z = NUT_Z - SCALE_L * (1 - 2 ** (-n / 12))
        w = 0.22 + (0.29 - 0.22) * (NUT_Z - z) / (NUT_Z - 0.45)
        bm.from_mesh(box("Fret", 2 * w, 0.02 if n else 0.05, 0.016 if n else 0.04, (0.0, fy - (0.01 if n else 0.025), z)))
    me = bpy.data.meshes.new("Frets")
    bm.to_mesh(me)
    bm.free()
    add(bpy.data.objects.new("Frets", me), M["gold"])
    inlays = []
    for n in INLAY_FRETS:
        z0 = NUT_Z - SCALE_L * (1 - 2 ** (-(n - 1) / 12))
        z1 = NUT_Z - SCALE_L * (1 - 2 ** (-n / 12))
        r = 0.08 if n != 12 else 0.11
        st = slab(f"Inlay{n}", [Vector((p.x, p.y + (z0 + z1) / 2)) for p in star_outline(r, rot=math.pi / 8)], fy - 0.004, fy + 0.01, 0)
        mi = M["pearl"].copy()
        inlays.append((add(st, mi), (z0 + z1) / 2))
    for i, z in enumerate((-0.4, 0.18)):            # two humbuckers with gold pole pieces
        add(bpy.data.objects.new(f"Pickup{i}", box(f"Pickup{i}", 0.62, 0.08, 0.24, (0.0, TOP_Y - 0.04, z))), M["pickup"])
        me = bpy.data.meshes.new(f"Poles{i}")
        poles = []
        for k in range(6):
            pm = cyl_y(f"Pole{i}{k}", 0.025, 0.0, 0.03)
            pm.transform(Matrix.Translation((-0.22 + 0.088 * k, TOP_Y - 0.1, z)))
            poles.append(pm)
        bm = bmesh.new()
        for pm in poles:
            bm.from_mesh(pm)
        bm.to_mesh(me)
        bm.free()
        add(bpy.data.objects.new(f"Poles{i}", me), M["gold"])
    add(bpy.data.objects.new("Bridge", box("Bridge", 0.7, 0.1, 0.16, (0.0, TOP_Y - 0.05, BRIDGE_Z))), M["gold"])
    add(bpy.data.objects.new("Tail", box("Tail", 0.6, 0.08, 0.1, (0.0, TOP_Y - 0.04, BRIDGE_Z - 0.32))), M["gold"])
    for k, (x, z) in enumerate(((0.62, -0.78), (0.84, -0.46), (0.55, -1.12))):
        kn = stage.lathe(f"Knob{k}", [(0.0, 0.0), (0.12, 0.0), (0.11, 0.1), (0.08, 0.13), (0.0, 0.14)], 24)
        kn.transform(Matrix.Rotation(R(90), 4, "X"))
        kn.transform(Matrix.Translation((x, TOP_Y, z)))
        add(bpy.data.objects.new(f"Knob{k}", kn), M["gold"])
    rose = slab("Rosette", [Vector((p.x - 0.62, p.y - 0.98)) for p in star_outline(0.2, 0.5)], TOP_Y - 0.006, TOP_Y + 0.01, 0)
    add(rose, M["gold"])
    for k in range(3):                              # tuners on the outer sides of the two prongs
        for side in (-1, 1):
            t = stage.lathe(f"Tuner{k}{side}", [(0.0, 0.0), (0.05, 0.0), (0.05, 0.1), (0.1, 0.12), (0.1, 0.2), (0.0, 0.21)], 16)
            t.transform(Matrix.Rotation(R(90 * side), 4, "Y"))
            t.transform(Matrix.Translation((side * 0.36, 0.0, 4.55 + 0.33 * k)))
            add(bpy.data.objects.new(f"Tuner{k}{side}", t), M["gold"])
    logo = bpy.data.curves.new("Logo", "FONT")
    logo.body, logo.size, logo.align_x, logo.extrude = "UZARO", 0.16, "CENTER", 0.01
    lo = bpy.data.objects.new("Logo", logo)
    lo.rotation_euler = (R(90), 0.0, R(90))
    lo.location = (0.0, TOP_Y - 0.07, 4.62)
    add(lo, M["gold"])
    strings = []
    for k in range(6):
        xn, xb = -0.17 + 0.068 * k, -0.24 + 0.096 * k
        a, b = Vector((xb, TOP_Y - 0.14, BRIDGE_Z)), Vector((xn, fy - 0.03, NUT_Z))
        strings.append(add(string_object(f"String{k}", a, b, 0.008 + 0.003 * (5 - k)), M["steel"]))
    pick = add(slab("Pick", spline([(0.0, -0.2), (0.17, 0.08), (0.12, 0.2), (-0.12, 0.2), (-0.17, 0.08)], 6), -0.012, 0.012, 0.006), M["gold"])
    pick.location = (-0.6, TOP_Y - 0.3, -0.1)
    meshes = [o for o in parts if o.type in ("MESH", "FONT") and o is not pick]
    return root, spin, strings, inlays, pick, meshes


def string_object(name, a, b, r, segs=40):
    """A thin tube from a to b with a 'Pluck' shape key: a half sine of sideways (X) displacement along its length."""
    d = b - a
    me = stage.lathe(name, [(0.0, 0.0)] + [(r, t / segs) for t in range(segs + 1)] + [(0.0, 1.0)], 8)
    me.transform(Matrix.Diagonal((1.0, 1.0, d.length, 1.0)))
    ob = bpy.data.objects.new(name, me)
    ob.matrix_world = Matrix.Translation(a) @ d.to_track_quat("Z", "Y").to_matrix().to_4x4()
    ob.shape_key_add(name="Basis")
    sk = ob.shape_key_add(name="Pluck")
    for v in sk.data:
        t = max(0.0, min(1.0, v.co.z / d.length))
        v.co.x += 0.045 * math.sin(math.pi * t)
    sk.slider_min = -1.0
    return ob


# ------------------------------------------------------------------ animation
def vibrate(strings, f0, strength=1.0):
    """Each string rings: the pluck shape swings +-1 at about 3 frames a cycle, decaying over ~20 frames."""
    for k, ob in enumerate(strings):
        kb = ob.data.shape_keys.key_blocks["Pluck"]
        start = f0 + k * 0.6                        # the pick crosses the strings in order
        kb.value = 0.0
        kb.keyframe_insert("value", frame=start - 1)
        for i in range(24):
            amp = strength * math.exp(-i / 8.0)
            kb.value = amp * (1 if i % 2 == 0 else -1)
            kb.keyframe_insert("value", frame=start + i * 1.5)
        kb.value = 0.0
        kb.keyframe_insert("value", frame=start + 37)


def animate(root, spin, pick):
    root.scale = (SCALE,) * 3
    path = [(1, (-6.0, 0.0, -13.0)), (ARRIVE, (0.0, 0.0, HOLD_Z)), (LEAVE, (0.3, 0.0, HOLD_Z + 0.4)), (TOTAL, (8.0, 0.0, 13.0))]
    for f, p in path:
        root.location = p
        root.keyframe_insert("location", frame=f)
    for f, deg in ((1, 40.0), (ARRIVE, -22.0), (LEAVE, -22.0), (TOTAL, -55.0)):
        root.rotation_euler = (0.0, R(deg), 0.0)
        root.keyframe_insert("rotation_euler", frame=f)
    for f, deg in ((1, -540.0), (ARRIVE, 0.0), (TURN, 0.0), (LEAVE - 2, 360.0), (TOTAL, 630.0)):
        spin.rotation_euler = (0.0, 0.0, R(deg))
        spin.keyframe_insert("rotation_euler", frame=f)
    for fc in root.animation_data.action.fcurves:   # ease in and out of every key
        for kp in fc.keyframe_points:
            kp.interpolation = "BEZIER"
    # a slow float while it is held on screen
    for f in range(ARRIVE + 4, LEAVE - 4, 6):
        root.location = (0.0, 0.0, HOLD_Z + 0.1 * math.sin(2 * math.pi * (f - ARRIVE) / 36))
        root.keyframe_insert("location", frame=f)
    # the pick swipes down across the strings on each strum, waiting out of the way between
    for f, x, show in ((1, -0.6, 0.0), (STRUM1 - 6, -0.6, 1.0), (STRUM1 + 2, 0.55, 1.0), (STRUM2 - 6, -0.6, 1.0),
                       (STRUM2 + 2, 0.6, 1.0), (STRUM2 + 8, 0.9, 0.0)):
        pick.location = (x, TOP_Y - 0.3, -0.1 + 0.1 * x)
        pick.scale = (show,) * 3
        pick.keyframe_insert("location", frame=f)
        pick.keyframe_insert("scale", frame=f)


def light_inlays(inlays, start, step=1.2):
    """Star inlays glow in turn from the body end to the headstock, then settle to a soft shimmer."""
    order = sorted(inlays, key=lambda t: t[1])
    for i, (ob, _) in enumerate(order):
        em = stage.bsdf(ob.data.materials[0]).inputs["Emission Strength"]
        f = start + i * step
        stage.key_socket(em, [(1, 0.0), (f, 0.0), (f + 3, 14.0), (f + 10, 2.5), (STRUM1, 2.5), (STRUM1 + 2, 9.0),
                              (STRUM1 + 12, 2.5), (STRUM2, 2.5), (STRUM2 + 2, 12.0), (STRUM2 + 16, 2.5)])


def notes(sc, name, f0, count, parent, seed=3):
    """Glowing eighth notes sprayed out of the body by a strum: keyed objects (particle instances turn edge-on),
    each popping up, drifting out and up with a little sway, shrinking away."""
    rnd = random.Random(seed)
    mats = [stage.emit(f"{name}Mat{c}", rgb, 3.5) for c, rgb in enumerate(NOTE_COLOURS)]
    for i in range(count):
        ob = stage.link(sc, f"{name}{i}", note_mesh(f"{name}Mesh{i}"), mats[i % 3], parent=parent, shadow=False)
        a = rnd.uniform(-0.15, 1.15) * math.pi
        d = rnd.uniform(1.8, 3.4)
        start = Vector((0.0, TOP_Y - 0.3, -0.3))
        end = start + Vector((d * math.cos(a), -rnd.uniform(0.2, 0.8), d * math.sin(a) + rnd.uniform(0.3, 1.2)))
        s, life, t0 = rnd.uniform(0.55, 0.95), rnd.randint(22, 32), f0 + rnd.uniform(0.0, 5.0)
        tilt = rnd.uniform(-25.0, 25.0)
        for k, (u, sc_) in enumerate(((0.0, 0.0), (0.18, 1.0), (0.75, 1.0), (1.0, 0.0))):
            f = t0 + u * life
            ob.location = start.lerp(end, 1 - (1 - u) ** 2)
            ob.scale = (s * sc_,) * 3
            ob.rotation_euler = (0.0, R(tilt + 18 * math.sin(3 * u + i)), 0.0)
            for path in ("location", "scale", "rotation_euler"):
                ob.keyframe_insert(path, frame=f)
        ob.hide_render = True
        ob.keyframe_insert("hide_render", frame=t0 - 1)
        ob.hide_render = False
        ob.keyframe_insert("hide_render", frame=t0)


def ring(sc, name, f0, r_end, strength, spin):
    ob = fx.shock_ring(sc, name, (0.0, 0.0, 0.0), (f0, f0 + 16), r_end, (1.0, 0.55, 0.85), strength, width=0.05)
    ob.parent = spin
    ob.location = (0.0, TOP_Y - 0.2, -0.3)
    ob.rotation_euler = (R(90), 0.0, 0.0)
    return ob


def build_show(sc, opts):
    root, spin, strings, inlays, pick, meshes = build_guitar(sc)
    animate(root, spin, pick)
    vibrate(strings, STRUM1, 0.8)
    vibrate(strings, STRUM2, 1.0)
    light_inlays(inlays, LIGHT)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.55, hdri="night.exr", lights=0.9, fog=(1.4, 7), streak=6.0)
    rim(sc)
    notes(sc, "NoteA", STRUM1, 12, root, 3)
    notes(sc, "NoteB", STRUM2, 20, root, 7)
    ring(sc, "Ring1", STRUM1, 3.0, 2.5, spin)
    ring(sc, "Ring2", STRUM2, 4.2, 3.5, spin)
    gold = fx.fade_material("Spark", GOLD, 14.0)
    sp = fx.particle_burst(sc, "Sparks", fx.point_mesh("SparkSrc", 0.4), gold, 220, (STRUM2, STRUM2 + 4), 22, 0.025, 4.5,
                           rand=1.0, damping=0.25, gravity=0.4)
    sp.parent, sp.location = spin, (0.0, TOP_Y - 0.3, -0.3)
    sh.camera_shake(cam, STRUM2, 10, amp=0.06, rot_deg=0.6)
    sh.screen_extent(sc, cam, meshes, (1, 14, ARRIVE, STRUM2, TURN + 8, LEAVE + 8, TOTAL))
    stage.bake_all(sc)


def rim(sc):
    """Magenta and cyan stage rims behind the guitar."""
    for name, rgb, loc in (("RimM", (1.0, 0.2, 0.7), (-4.0, 5.0, 2.0)), ("RimC", (0.2, 0.8, 1.0), (4.0, 5.0, -1.0))):
        ld = bpy.data.lights.new(name, "AREA")
        ld.energy, ld.color, ld.size = 900.0, rgb, 3.0
        ob = bpy.data.objects.new(name, ld)
        sc.collection.objects.link(ob)
        ob.location = loc
        ob.rotation_euler = (Vector((0, 0, 0)) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()


def build_icon(sc, opts):
    """Tilted guitar rocking gently, star inlays pulsing in a wave, strings shimmering: closes on frame 1."""
    root, spin, strings, inlays, pick, meshes = build_guitar(sc)
    pick.hide_render = True
    n = stage.ICON_N
    root.rotation_euler = (0.0, R(-30), 0.0)
    stage.key_path(spin, range(1, n + 2), lambda f: (0.0, 0.0, R(22) * math.sin(2 * math.pi * (f - 1) / n)), path="rotation_euler")
    order = sorted(inlays, key=lambda t: t[1])
    for i, (ob, _) in enumerate(order):
        em = stage.bsdf(ob.data.materials[0]).inputs["Emission Strength"]
        stage.key_socket(em, [(f, 2.0 + 8.0 * max(0.0, math.sin(2 * math.pi * ((f - 1) / n - i / len(order)))) ** 3)
                              for f in range(1, n + 2)])
    for k, ob in enumerate(strings):
        kb = ob.data.shape_keys.key_blocks["Pluck"]
        for f in range(1, n + 2):
            kb.value = 0.12 * math.sin(math.pi * (f - 1) * 2 / 3 * 3 + k)
            kb.keyframe_insert("value", frame=f)
    cam = stage.setup_icon(sc, opts["samples"], world=0.55, hdri="night.exr", lights=0.9, fog=(1.4, 7), streak=6.0)
    rim(sc)
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.08)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
