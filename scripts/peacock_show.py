"""UZARO v2 show: peacock (tier 2, 120 f = 5 s). An original UZARO peacock, built here from scratch.

Design (ours): a stylised peacock in iridescent royal blue that turns to teal at the edges, bronze barred wings, a gold
crest of seven plumes, gold legs and a thin gold collar with a turquoise drop (a nod to Uzbek jewellery). Its train is
63 feathers in three rows; each feather is a real outlined mesh with wispy barbs and a ringed eye (navy core, royal
blue, teal, bronze, green) drawn by the shader.
Show: it appears in a swirl of gold sparks with the train folded behind it, lifts its head and fans the train open
from the centre out, rattles it (the shiver real peacocks do), its eyes light up in a wave from the middle outward
while it sways to show off, then it folds and dissolves into sparkles.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Quaternion, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R  # noqa: E402

ID = "peacock"
TOTAL = 120
APPEAR, OPEN, SHIVER, GLOW, CLOSE, GONE = 2, 24, 54, 58, 98, 114
SCALE = 1.1
YAW = R(22)                                     # turned so the head and beak read in profile
ROOT_Z = -0.55
FOOT_Z = -1.3
PIVOT = Vector((0.0, 0.3, -0.45))               # where the train is set into the body
ROWS = [  # (count, length, eye width, spread deg, cup deg, pivot y offset)
    (27, 3.0, 0.32, 84.0, 14.0, 0.06),
    (21, 2.2, 0.28, 80.0, 9.0, 0.0),
    (15, 1.4, 0.24, 76.0, 5.0, -0.06),
]
BLUE, TEAL, GREEN = (0.008, 0.06, 0.36), (0.0, 0.5, 0.55), (0.04, 0.42, 0.12)
GOLD, BRONZE, NAVY = (1.0, 0.72, 0.3), (0.62, 0.38, 0.12), (0.02, 0.02, 0.16)


# ------------------------------------------------------------------ helpers
def ease_back(x, s=1.4):
    """0..1 with a small overshoot past 1 (the fan snaps open)."""
    x = min(max(x, 0.0), 1.0) - 1.0
    return 1.0 + x * x * ((s + 1.0) * x + s)


def tube(name, pts, radii, n=40, segs=20):
    """A round tube along a Catmull-Rom curve through pts, radius interpolated from radii (one per point)."""
    bm = bmesh.new()
    rings = []
    for i in range(n + 1):
        t = i / n
        p = Vector(stage.catmull(pts, t))
        q = Vector(stage.catmull(pts, min(t + 1e-3, 1.0))) - Vector(stage.catmull(pts, max(t - 1e-3, 0.0)))
        tan = q.normalized()
        side = tan.cross(Vector((0.0, 1.0, 0.0)))
        if side.length < 1e-4:
            side = tan.cross(Vector((1.0, 0.0, 0.0)))
        side.normalize()
        up = side.cross(tan)
        k = t * (len(radii) - 1)
        j = min(int(k), len(radii) - 2)
        r = radii[j] + (radii[j + 1] - radii[j]) * (k - j)
        rings.append([bm.verts.new(p + r * (math.cos(a) * side + math.sin(a) * up))
                      for a in (2 * math.pi * s / segs for s in range(segs))])
    for a, b in zip(rings, rings[1:]):
        for s in range(segs):
            bm.faces.new((a[s], a[(s + 1) % segs], b[(s + 1) % segs], b[s]))
    bm.faces.new(rings[0][::-1])
    bm.faces.new(rings[-1])
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = True
    return me


def ellipsoid(name, r, segs=32):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=segs // 2, radius=1.0)
    bmesh.ops.scale(bm, vec=r, verts=bm.verts)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = True
    return me


def feather_mesh(name, length, eye_w, n=48):
    """Flat feather along +Z, face toward -Y. UVMap: x across normalised to the local half width (edge at 0 and 1),
    y along the length. 'Eye' map: the eye's own coordinates, unit circle = the eye's outer green ring."""
    eye_z, eye_h = length * 0.86, eye_w * 1.35
    me = bpy.data.meshes.new(name)
    verts, faces, uv, uve = [], [], [], []
    cols = 5
    for i in range(n + 1):
        v = i / n
        z = v * length
        grow = 0.08 + 0.92 * stage.smooth(min(max((v - 0.25) / 0.55, 0.0), 1.0))
        tip = math.sqrt(max(0.0, 1.0 - ((v - 0.86) / 0.14) ** 2)) if v > 0.86 else 1.0
        hw = max(eye_w * 0.62 * grow * tip, 0.004)
        for c in range(cols):
            a = c / (cols - 1)
            x = (a * 2 - 1) * hw
            verts.append((x, -0.02 * (1 - (a * 2 - 1) ** 2) * grow, z))     # a slight curve across the vane
            uv.append((a, v))
            uve.append((x / (eye_w * 0.5), (z - eye_z) / (eye_h * 0.5)))
    for i in range(n):
        for c in range(cols - 1):
            k = i * cols + c
            faces.append((k, k + 1, k + 1 + cols, k + cols))
    me.from_pydata(verts, [], faces)
    for nm, data in (("UVMap", uv), ("Eye", uve)):
        lay = me.uv_layers.new(name=nm)
        for poly in me.polygons:
            for li in poly.loop_indices:
                lay.data[li].uv = data[me.loops[li].vertex_index]
    for p in me.polygons:
        p.use_smooth = True
    return me


# ------------------------------------------------------------------ materials
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


def iridescent(mat, colors, strength):
    """Viewing angle picks colours (facing -> grazing) as a soft emission on top: the thin-film shift of the plumage."""
    nt = mat.node_tree
    b = stage.bsdf(mat)
    lw, ramp = nt.nodes.new("ShaderNodeLayerWeight"), nt.nodes.new("ShaderNodeValToRGB")
    lw.inputs["Blend"].default_value = 0.4
    els = ramp.color_ramp.elements
    els[0].position, els[0].color = 0.0, (*colors[0], 1)
    els[1].position, els[1].color = 1.0, (*colors[-1], 1)
    for i, c in enumerate(colors[1:-1], 1):
        els.new(i / (len(colors) - 1)).color = (*c, 1)
    nt.links.new(lw.outputs["Facing"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], b.inputs["Emission Color"])
    b.inputs["Emission Strength"].default_value = strength
    return ramp


def plumage_material():
    m = stage.pbr("Plumage", BLUE, roughness=0.28, coat=0.5)
    b = stage.bsdf(m)
    b.inputs["Sheen Weight"].default_value = 0.2
    b.inputs["Sheen Tint"].default_value = (*TEAL, 1)
    nt = m.node_tree
    vor, bump = nt.nodes.new("ShaderNodeTexVoronoi"), nt.nodes.new("ShaderNodeBump")
    vor.inputs["Scale"].default_value = 60.0
    bump.inputs["Strength"].default_value = 0.2
    nt.links.new(vor.outputs["Distance"], bump.inputs["Height"])
    nt.links.new(bump.outputs[0], b.inputs["Normal"])
    iridescent(m, [(0.0, 0.03, 0.2), (0.0, 0.12, 0.45), (0.0, 0.45, 0.4)], 0.18)
    return m


def wing_material():
    """Bronze with darker bars across the folded wing."""
    m = stage.pbr("Wing", BRONZE, roughness=0.45, coat=0.2)
    nt = m.node_tree
    b = stage.bsdf(m)
    wave, ramp = nt.nodes.new("ShaderNodeTexWave"), nt.nodes.new("ShaderNodeValToRGB")
    wave.inputs["Scale"].default_value = 9.0
    wave.inputs["Distortion"].default_value = 1.5
    ramp.color_ramp.elements[0].color = (0.16, 0.08, 0.03, 1)
    ramp.color_ramp.elements[1].color = (*BRONZE, 1)
    ramp.color_ramp.elements[0].position = 0.45
    ramp.color_ramp.elements[1].position = 0.6
    nt.links.new(wave.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], b.inputs["Base Color"])
    return m


def feather_material():
    """Ringed eye from the 'Eye' map, green-gold barbs on the vane, wispy edges cut by alpha; the eye glows by each
    feather's own 'glow' property (keyed per object, so the light can run across the fan as a wave)."""
    m = bpy.data.materials.new("Feather")
    m.use_nodes = True
    nt = m.node_tree
    N, L = nt.nodes.new, nt.links.new
    b = stage.bsdf(m)
    b.inputs["Roughness"].default_value = 0.3
    b.inputs["Metallic"].default_value = 0.25
    b.inputs["Coat Weight"].default_value = 0.3
    b.inputs["Sheen Weight"].default_value = 0.4
    uv, eye = N("ShaderNodeUVMap"), N("ShaderNodeUVMap")
    uv.uv_map, eye.uv_map = "UVMap", "Eye"
    sep = N("ShaderNodeSeparateXYZ")
    L(uv.outputs[0], sep.inputs[0])
    edge = math_node(nt, "ABSOLUTE", math_node(nt, "SUBTRACT", math_node(nt, "MULTIPLY", sep.outputs["X"], 2.0), 1.0))
    vlen = N("ShaderNodeVectorMath")
    vlen.operation = "LENGTH"
    L(eye.outputs[0], vlen.inputs[0])
    d = vlen.outputs["Value"]
    ramp = N("ShaderNodeValToRGB")                   # rings, centre outward
    els = ramp.color_ramp.elements
    stops = [(0.0, NAVY), (0.3, NAVY), (0.34, (0.05, 0.12, 0.75)), (0.48, (0.05, 0.12, 0.75)), (0.52, TEAL),
             (0.64, TEAL), (0.68, (0.72, 0.42, 0.1)), (0.8, (0.72, 0.42, 0.1)), (0.84, GREEN), (1.0, GREEN),
             (1.15, (0.16, 0.3, 0.05))]
    scale = 1.0 / 1.15
    els[0].position, els[0].color = 0.0, (*stops[0][1], 1)
    els[1].position, els[1].color = 1.0, (*stops[-1][1], 1)
    for pos, c in stops[1:-1]:
        els.new(pos * scale).color = (*c, 1)
    dn = math_node(nt, "MULTIPLY", d, scale)
    L(dn, ramp.inputs["Fac"])
    barbs = N("ShaderNodeTexWave")                   # fine strands running out from the shaft
    barbs.wave_type, barbs.bands_direction = "BANDS", "DIAGONAL"
    barbs.inputs["Scale"].default_value = 26.0
    barbs.inputs["Distortion"].default_value = 0.6
    L(uv.outputs[0], barbs.inputs["Vector"])
    vane = math_node(nt, "MINIMUM", math_node(nt, "MAXIMUM", math_node(nt, "MULTIPLY", math_node(nt, "SUBTRACT", d, 1.0), 2.5), 0.0), 1.0)
    strands = math_node(nt, "POWER", barbs.outputs["Fac"], 0.6)
    a_vane = math_node(nt, "SUBTRACT", 1.0, math_node(nt, "MULTIPLY", vane, math_node(nt, "SUBTRACT", 1.0, strands)))
    fringe = math_node(nt, "MULTIPLY", math_node(nt, "SUBTRACT", 1.0, strands),
                       math_node(nt, "MAXIMUM", math_node(nt, "MULTIPLY", math_node(nt, "SUBTRACT", edge, 0.55), 2.3), 0.0))
    alpha = math_node(nt, "MULTIPLY", a_vane, math_node(nt, "MAXIMUM", math_node(nt, "SUBTRACT", 1.0, fringe), 0.0))
    shaft = math_node(nt, "LESS_THAN", edge, 0.06)                     # gold rachis down the middle
    alpha = math_node(nt, "MAXIMUM", alpha, math_node(nt, "MULTIPLY", shaft, math_node(nt, "GREATER_THAN", d, 0.95)))
    L(alpha, b.inputs["Alpha"])
    col = N("ShaderNodeMix")
    col.data_type = "RGBA"
    L(math_node(nt, "MULTIPLY", shaft, math_node(nt, "GREATER_THAN", d, 0.95)), col.inputs["Factor"])
    L(ramp.outputs["Color"], col.inputs[6])
    col.inputs[7].default_value = (*GOLD, 1)
    L(col.outputs[2], b.inputs["Base Color"])
    glow = N("ShaderNodeAttribute")
    glow.attribute_type, glow.attribute_name = "OBJECT", "glow"
    in_eye = math_node(nt, "LESS_THAN", d, 0.82)
    L(ramp.outputs["Color"], b.inputs["Emission Color"])
    L(math_node(nt, "ADD", math_node(nt, "MULTIPLY", glow.outputs["Fac"], in_eye), 0.12), b.inputs["Emission Strength"])
    m.blend_method = "HASHED"
    return m


# ------------------------------------------------------------------ the bird
def bird(sc, root):
    plum, wing, gold = plumage_material(), wing_material(), stage.pbr("Gold", GOLD, metallic=1.0, roughness=0.2)
    white = stage.pbr("Face", (0.95, 0.95, 0.92), roughness=0.5)
    black = stage.pbr("Eye", (0.005, 0.005, 0.005), roughness=0.05, coat=1.0)
    horn = stage.pbr("Beak", (0.78, 0.7, 0.55), roughness=0.35)
    gem = stage.pbr("Turquoise", (0.1, 0.75, 0.72), roughness=0.15, coat=1.0)
    body_e = bpy.data.objects.new("Body", None)
    sc.collection.objects.link(body_e)
    body_e.parent = root
    body = stage.lathe("BodyMesh", [(0.0, -0.7), (0.28, -0.66), (0.46, -0.48), (0.5, -0.22), (0.45, 0.05), (0.33, 0.25),
                                    (0.2, 0.4), (0.15, 0.5), (0.0, 0.54)], 48)
    ob = stage.link(sc, "BodySkin", body, plum, parent=body_e)
    ob.scale = (1.0, 0.92, 1.0)
    for s in (-1, 1):
        w = stage.link(sc, f"Wing{s}", ellipsoid(f"WingMesh{s}", (0.08, 0.34, 0.42)), wing, parent=body_e,
                       loc=(0.38 * s, 0.2, -0.18))
        w.rotation_euler = (R(22), R(-6) * s, R(14) * s)
        stage.link(sc, f"Leg{s}", stage.lathe(f"LegMesh{s}", [(0.0, FOOT_Z + 0.02), (0.035, FOOT_Z + 0.02), (0.03, -0.5),
                                                                (0.0, -0.5)], 12), gold, parent=body_e, loc=(0.17 * s, 0.0, 0.0))
        for k in (-1, 0, 1):                                            # three toes forward
            t = stage.link(sc, f"Toe{s}{k}", stage.lathe(f"ToeMesh{s}{k}", [(0.0, 0.0), (0.025, 0.0), (0.0, 0.2)], 8), gold,
                           parent=body_e, loc=(0.17 * s, -0.02, FOOT_Z + 0.03))
            t.rotation_euler = (R(-90), 0.0, R(28) * k)
    neck_e = bpy.data.objects.new("Neck", None)
    sc.collection.objects.link(neck_e)
    neck_e.parent = body_e
    neck_e.location = (0.0, 0.0, 0.42)
    stage.link(sc, "NeckSkin", tube("NeckMesh", [(0, 0.02, -0.12), (0, 0.0, 0.0), (0, -0.07, 0.42), (0, -0.02, 0.82),
                                                 (0, -0.12, 1.08), (0, -0.14, 1.14)], [0.17, 0.15, 0.11, 0.09, 0.09, 0.085]),
               plum, parent=neck_e)
    head_e = bpy.data.objects.new("Head", None)
    sc.collection.objects.link(head_e)
    head_e.parent = neck_e
    head_e.location = (0.0, -0.1, 1.12)
    stage.link(sc, "HeadSkin", ellipsoid("HeadMesh", (0.12, 0.16, 0.13)), plum, parent=head_e, loc=(0.0, -0.04, 0.03))
    bk = stage.link(sc, "Beak", stage.lathe("BeakMesh", [(0.0, 0.0), (0.045, 0.0), (0.03, 0.08), (0.0, 0.16)], 16), horn,
                    parent=head_e, loc=(0.0, -0.17, 0.0))
    bk.rotation_euler = (R(-100), 0.0, 0.0)
    for s in (-1, 1):
        stage.link(sc, f"Stripe{s}a", ellipsoid(f"StripeA{s}", (0.012, 0.07, 0.016)), white, parent=head_e,
                   loc=(0.105 * s, -0.07, 0.06))
        stage.link(sc, f"Stripe{s}b", ellipsoid(f"StripeB{s}", (0.012, 0.06, 0.018)), white, parent=head_e,
                   loc=(0.1 * s, -0.08, -0.03))
        stage.link(sc, f"EyeBall{s}", ellipsoid(f"EyeMesh{s}", (0.026, 0.026, 0.026), 16), black, parent=head_e,
                   loc=(0.1 * s, -0.09, 0.02))
    crest = bpy.data.objects.new("Crest", None)
    sc.collection.objects.link(crest)
    crest.parent = head_e
    crest.location = (0.0, -0.02, 0.12)
    for i in range(7):
        a = R(-30 + 10 * i)
        st = stage.link(sc, f"Plume{i}", stage.lathe(f"PlumeMesh{i}", [(0.0, 0.0), (0.008, 0.0), (0.005, 0.3), (0.0, 0.3)], 6),
                        gold, parent=crest)
        st.rotation_euler = (R(-12), a, 0.0)
        tip = stage.link(sc, f"PlumeTip{i}", ellipsoid(f"PlumeTipMesh{i}", (0.035, 0.012, 0.045), 12), plum, parent=st,
                         loc=(0.0, 0.0, 0.31))
    collar = stage.link(sc, "Collar", fx.ring_mesh("CollarMesh", 0.165, 0.025, 48), gold, parent=neck_e, loc=(0.0, -0.01, 0.06))
    collar.rotation_euler = (R(-8), 0.0, 0.0)
    stage.link(sc, "Drop", ellipsoid("DropMesh", (0.045, 0.03, 0.06), 16), gem, parent=neck_e, loc=(0.0, -0.18, -0.04))
    return body_e, neck_e, head_e, crest


def train(sc, body_e):
    """The three rows of feathers on one pivot, each its own object with its fan angle and cup stored."""
    tail = bpy.data.objects.new("Tail", None)
    sc.collection.objects.link(tail)
    tail.parent = body_e
    tail.location = PIVOT
    mat = feather_material()
    feathers = []
    for row, (count, length, eye_w, spread, cup, dy) in enumerate(ROWS):
        me = feather_mesh(f"FeatherRow{row}", length, eye_w)
        for i in range(count):
            th = R(-spread + 2 * spread * i / (count - 1))
            ob = stage.link(sc, f"Feather{row}_{i:02d}", me, mat, parent=tail, loc=(0.0, dy + 0.002 * i, 0.0))
            ob.rotation_mode = "QUATERNION"
            ob["glow"] = 0.0
            feathers.append((ob, th, R(cup), row))
    return tail, feathers


def feather_quat(th, cup, p, shiver):
    """p = 0: folded back and down along the ground behind; p = 1: open in the fan, cupped toward the bird."""
    closed = Quaternion((0.0, 1.0, 0.0), th * 0.12) @ Quaternion((1.0, 0.0, 0.0), R(-98))
    opened = Quaternion((0.0, 1.0, 0.0), th + shiver) @ Quaternion((1.0, 0.0, 0.0), -cup)
    if p <= 1.0:
        return closed.slerp(opened, max(p, 0.0))
    over = Quaternion((0.0, 1.0, 0.0), th * (p - 1.0) * 0.6)             # overshoot: the fan spreads a touch wider
    return over @ opened


# ------------------------------------------------------------------ animation
def animate_train(feathers, frames, open_at, close_at=None, glow_at=None, shiver_at=None, period=None):
    for ob, th, cup, row in feathers:
        lag = 9.0 * abs(th) / R(84) + 2.0 * row
        for f in frames:
            p = 1.0 if open_at is None else ease_back((f - open_at - lag) / 16.0)
            if close_at is not None:
                p *= 1.0 - 0.65 * stage.smooth(min(max((f - close_at - (9.0 - lag)) / 12.0, 0.0), 1.0))
            sh_amp = 0.0
            if shiver_at is not None:
                a, b = shiver_at
                sh_amp = R(1.4) * stage.smooth(min(max((f - a) / 6.0, 0.0), 1.0)) * stage.smooth(min(max((b - f) / 6.0, 0.0), 1.0))
            shiver = sh_amp * math.sin(2 * math.pi * f / 3.0 + 7.0 * th + row)
            ob.rotation_quaternion = feather_quat(th, cup, p, shiver)
            ob.keyframe_insert("rotation_quaternion", frame=f)
            if glow_at is not None:
                a, b = glow_at
                wave = math.sin(2 * math.pi * (f - a) / (period or 16.0) - abs(th) * 2.4 - row * 0.5)
                env = stage.smooth(min(max((f - a) / 8.0, 0.0), 1.0)) * stage.smooth(min(max((b - f) / 8.0, 0.0), 1.0))
                ob["glow"] = 0.4 * env + 3.2 * env * max(0.0, wave) ** 2
                ob.keyframe_insert('["glow"]', frame=f)


def animate_bird(root, body_e, neck_e, head_e, crest):
    for f in range(1, TOTAL + 1):
        grow = ease_back((f - APPEAR) / 14.0, 1.7) if f < CLOSE else 1.0
        shrink = 1.0 - stage.smooth(min(max((f - (CLOSE + 4)) / (GONE - CLOSE - 4), 0.0), 1.0))
        s = max(grow * shrink, 0.0) * SCALE
        root.scale = (s, s, s)
        sway = R(11) * math.sin(2 * math.pi * (f - 50) / 48) * stage.smooth(min(max((f - 50) / 10, 0.0), 1.0))
        root.rotation_euler = (0.0, 0.0, YAW + sway)
        root.keyframe_insert("scale", frame=f)
        root.keyframe_insert("rotation_euler", frame=f)
        lift = stage.smooth(min(max((f - OPEN) / 14.0, 0.0), 1.0))
        body_e.rotation_euler = (R(-6) * lift, 0.0, 0.0)              # leans forward a little as the fan rises
        neck_e.rotation_euler = (R(8) * lift + R(2.5) * math.sin(f / 5.0), 0.0, 0.0)
        head_e.rotation_euler = (R(-6) * lift, 0.0, R(10) * math.sin(2 * math.pi * (f - 30) / 40) * lift)
        crest.rotation_euler = (R(4) * math.sin(f / 2.2) * lift, 0.0, 0.0)
        for ob in (body_e, neck_e, head_e, crest):
            ob.keyframe_insert("rotation_euler", frame=f)


def sparkle(sc, root):
    gold = fx.fade_material("Spark", (1.0, 0.82, 0.5), 9.0)
    swirl = fx.particle_burst(sc, "Swirl", fx.point_mesh("SwirlSrc", 1.4), gold, 260, (APPEAR, APPEAR + 10), 20, 0.03, 1.2,
                              rand=1.0, align=(0.0, 0.0, 1.0), damping=0.25, gravity=-0.05, location=(0.0, 0.0, ROOT_Z))
    swirl.scale = (1.0, 0.4, 1.3)
    fan = fx.particle_burst(sc, "FanGlint", fx.point_mesh("FanSrc", 2.6), gold, 220, (OPEN + 14, CLOSE), 22, 0.022, 0.25,
                            rand=0.6, align=(0.0, 0.0, 0.2), damping=0.4, gravity=0.0, location=(0.0, 0.5, ROOT_Z + 1.4))
    fan.scale = (1.2, 0.15, 0.6)
    out = fx.particle_burst(sc, "Dissolve", fx.point_mesh("DissolveSrc", 1.6), gold, 420, (CLOSE + 6, GONE + 2), 22, 0.03,
                            1.1, rand=1.0, align=(0.0, 0.0, 0.9), damping=0.3, gravity=-0.12, location=(0.0, 0.3, ROOT_Z + 1.0))
    out.scale = (1.3, 0.4, 1.0)
    fx.shock_ring(sc, "Ring", (0.0, 0.0, ROOT_Z - 0.2), (APPEAR + 2, APPEAR + 22), 3.6, GOLD, 3.0, width=0.05)


def build(sc):
    root = bpy.data.objects.new("PeacockRoot", None)
    sc.collection.objects.link(root)
    root.location = (0.0, 0.0, ROOT_Z)
    body_e, neck_e, head_e, crest = bird(sc, root)
    _, feathers = train(sc, body_e)
    meshes = [o for o in sc.objects if o.type == "MESH"]
    return root, body_e, neck_e, head_e, crest, feathers, meshes


def build_show(sc, opts):
    root, body_e, neck_e, head_e, crest, feathers, meshes = build(sc)
    animate_bird(root, body_e, neck_e, head_e, crest)
    animate_train(feathers, range(1, TOTAL + 1), OPEN, CLOSE, (GLOW, CLOSE + 4), (SHIVER, SHIVER + 22))
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.9, hdri="sunrise.exr", lights=0.85, fog=(2.0, 6), streak=10.0)
    sc.cycles.transparent_max_bounces = 96
    sh.shadow_catcher(sc, ROOT_Z + FOOT_Z * SCALE, 40)
    sparkle(sc, root)
    sh.screen_extent(sc, cam, meshes, (1, 20, OPEN + 30, 80, CLOSE, TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Fan open, rattling, with the eye wave running round once per loop."""
    n = stage.ICON_N
    root, body_e, neck_e, head_e, crest, feathers, meshes = build(sc)
    root.scale = (SCALE,) * 3
    root.rotation_euler = (0.0, 0.0, R(12))
    body_e.rotation_euler = (R(-6), 0.0, 0.0)
    neck_e.rotation_euler = (R(8), 0.0, 0.0)
    head_e.rotation_euler = (R(-6), 0.0, R(8))
    frames = range(1, n + 2)
    animate_train(feathers, frames, None, glow_at=(-100, 100), shiver_at=(-100, 100), period=n)
    for f in frames:                                                    # crest bobs twice per loop
        crest.rotation_euler = (R(4) * math.sin(4 * math.pi * f / n), 0.0, 0.0)
        crest.keyframe_insert("rotation_euler", frame=f)
    cam = stage.setup_icon(sc, opts["samples"], world=0.9, hdri="sunrise.exr", lights=0.85, fog=(2.0, 6), streak=8.0)
    sc.cycles.transparent_max_bounces = 96
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.06)
    sh.shadow_catcher(sc, gc.world_bbox(meshes)[0].z, 30)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
