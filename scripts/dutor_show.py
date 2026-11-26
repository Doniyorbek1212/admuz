"""UZARO v2 show: dutor (tier 2, 120 f = 5 s).

A carved long-necked two-string lute floats up into frame and settles, tilted; its strings are plucked one after the
other and visibly vibrate (blurred shape-key oscillation), and with every pluck a glowing note rises from the sound
holes and fades; then it drifts up and away. Built here: staved pear bowl, inlaid soundboard with a rosette of holes,
tied frets, a pegbox with two pegs; an original design.
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

ID = "dutor"
TOTAL = 120
TILT = R(-24)                        # neck leans up-right
BODY_L, BODY_W = 1.25, 0.72          # pear bowl length and width
NECK_L, NECK_W = 3.2, 0.11
PLUCKS = ((34, 0), (46, 1), (58, 0), (66, 1), (78, 0), (86, 1))   # (frame, string)
IN, OUT = (1, 30), (100, 120)
SHOW_SCALE = 1.4
WOOD_D, WOOD_L = (0.22, 0.08, 0.035), (0.55, 0.3, 0.13)
GOLD, TURQ = (1.0, 0.75, 0.32), (0.25, 0.85, 0.9)
NUT_Z = BODY_L * 0.5 + NECK_L
BRIDGE_Z = -BODY_L * 0.18
TAIL_Z = -BODY_L * 0.5
STRINGS_X = (-0.022, 0.022)


def pear(z):
    """Half-width of the body outline at height z (body centred on 0, neck at +Z)."""
    u = (z + BODY_L / 2) / BODY_L
    if u <= 0 or u >= 1:
        return 0.0
    return BODY_W / 2 * (math.sin(math.pi * u ** 0.75) ** 0.8) * (1 - 0.25 * u)


def bowl_material():
    """Staved mulberry: dark and light ribs alternating around the bowl, a thin bone line between them."""
    m = stage.pbr("Bowl", WOOD_D, roughness=0.28, coat=0.7)
    nt = m.node_tree
    N, L = nt.nodes.new, nt.links.new
    tc, sep = N("ShaderNodeTexCoord"), N("ShaderNodeSeparateXYZ")
    L(tc.outputs["Object"], sep.inputs[0])
    ang = N("ShaderNodeMath")
    ang.operation = "ARCTAN2"
    L(sep.outputs["X"], ang.inputs[0])
    L(sep.outputs["Y"], ang.inputs[1])
    rib = N("ShaderNodeMath")
    rib.operation = "MULTIPLY"
    rib.inputs[1].default_value = 9 / math.pi
    L(ang.outputs[0], rib.inputs[0])
    fr = N("ShaderNodeMath")
    fr.operation = "FRACT"
    L(rib.outputs[0], fr.inputs[0])
    alt = N("ShaderNodeMath")
    alt.operation = "PINGPONG"
    alt.inputs[1].default_value = 1.0
    L(rib.outputs[0], alt.inputs[0])
    step = N("ShaderNodeMath")
    step.operation = "GREATER_THAN"
    step.inputs[1].default_value = 0.5
    L(alt.outputs[0], step.inputs[0])
    grain = N("ShaderNodeTexWave")
    grain.bands_direction = "Z"
    grain.inputs["Scale"].default_value, grain.inputs["Distortion"].default_value = 6.0, 6.0
    L(tc.outputs["Object"], grain.inputs["Vector"])
    col = N("ShaderNodeMix")
    col.data_type = "RGBA"
    col.inputs["A"].default_value, col.inputs["B"].default_value = (*WOOD_D, 1), (*WOOD_L, 1)
    L(step.outputs[0], col.inputs["Factor"])
    g = N("ShaderNodeMix")
    g.data_type, g.blend_type = "RGBA", "MULTIPLY"
    g.inputs["Factor"].default_value = 0.25
    L(col.outputs["Result"], g.inputs["A"])
    L(grain.outputs["Color"], g.inputs["B"])
    line = N("ShaderNodeMath")                         # bone line where two staves meet
    line.operation = "LESS_THAN"
    line.inputs[1].default_value = 0.04
    L(fr.outputs[0], line.inputs[0])
    fin = N("ShaderNodeMix")
    fin.data_type = "RGBA"
    fin.inputs["B"].default_value = (0.92, 0.88, 0.78, 1)
    L(line.outputs[0], fin.inputs["Factor"])
    L(g.outputs["Result"], fin.inputs["A"])
    L(fin.outputs["Result"], stage.bsdf(m).inputs["Base Color"])
    return m


def board_material():
    """Pale apricot soundboard with a bone inlay border and a ring of tiny sound holes (dark dots)."""
    m = stage.pbr("Board", (0.72, 0.5, 0.28), roughness=0.35, coat=0.6)
    nt = m.node_tree
    N, L = nt.nodes.new, nt.links.new
    tc, sep = N("ShaderNodeTexCoord"), N("ShaderNodeSeparateXYZ")
    L(tc.outputs["Object"], sep.inputs[0])

    def op(o, a, b=None):
        n = N("ShaderNodeMath")
        n.operation = o
        for i, x in enumerate((a, b)):
            if x is None:
                continue
            if isinstance(x, (int, float)):
                n.inputs[i].default_value = x
            else:
                L(x, n.inputs[i])
        return n.outputs[0]

    x, z = sep.outputs["X"], op("SUBTRACT", sep.outputs["Z"], BODY_L * 0.08)
    r = op("SQRT", op("ADD", op("MULTIPLY", x, x), op("MULTIPLY", z, z)))
    a = op("ARCTAN2", x, z)
    cell = op("SUBTRACT", op("FRACT", op("MULTIPLY", a, 12 / math.pi)), 0.5)       # 24 holes around
    hole = op("LESS_THAN", op("ADD", op("MULTIPLY", op("MULTIPLY", cell, cell), 0.012), op("MULTIPLY", op("SUBTRACT", r, 0.13), op("SUBTRACT", r, 0.13))), 0.00022)
    inner = op("LESS_THAN", op("ABSOLUTE", op("SUBTRACT", r, 0.065)), 0.006)
    dark = op("MAXIMUM", hole, op("LESS_THAN", r, 0.025))
    col = N("ShaderNodeMix")
    col.data_type = "RGBA"
    col.inputs["A"].default_value, col.inputs["B"].default_value = (0.72, 0.5, 0.28, 1), (0.04, 0.02, 0.01, 1)
    L(dark, col.inputs["Factor"])
    bone = N("ShaderNodeMix")
    bone.data_type = "RGBA"
    bone.inputs["B"].default_value = (0.92, 0.88, 0.78, 1)
    L(inner, bone.inputs["Factor"])
    L(col.outputs["Result"], bone.inputs["A"])
    L(bone.outputs["Result"], stage.bsdf(m).inputs["Base Color"])
    return m


def bowl_mesh():
    """Back half of a pear lathe (y >= 0 is behind the board), plus the board as a flat cap at y = 0."""
    prof, n = [], 24
    for i in range(n + 1):
        z = -BODY_L / 2 + BODY_L * i / n
        prof.append((max(pear(z), 0.0), z))
    me = stage.lathe("Bowl", prof, 64)
    me.transform(Matrix.Diagonal((1.0, 0.62, 1.0, 1.0)))   # bowl depth is less than its width
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], plane_co=(0, 0, 0), plane_no=(0, 1, 0), clear_inner=True)
    bm.to_mesh(me)
    bm.free()
    board = bpy.data.meshes.new("Board")
    bmb = bmesh.new()
    rim = [bmb.verts.new((pear(z) * s, 0.0, z)) for s in (1, -1) for z in ([p[1] for p in prof] if s == 1 else [p[1] for p in reversed(prof)])
           if pear(z) > 1e-4]
    bmb.faces.new(rim)
    bmesh.ops.triangulate(bmb, faces=bmb.faces[:])
    bmb.to_mesh(board)
    bmb.free()
    return me, board


def string_mesh(name, x):
    """Thin straight string from tail to nut, 40 segments, with a 'Bow' shape key bulging between bridge and nut."""
    n = 40
    zs = [TAIL_Z + (NUT_Z - TAIL_Z) * i / n for i in range(n + 1)]
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    rings = []
    for z in zs:
        rings.append([bm.verts.new((x + 0.006 * math.cos(2 * math.pi * k / 6), -0.07 + 0.006 * math.sin(2 * math.pi * k / 6), z)) for k in range(6)])
    for a, b in zip(rings, rings[1:]):
        for k in range(6):
            bm.faces.new((a[k], a[(k + 1) % 6], b[(k + 1) % 6], b[k]))
    bm.to_mesh(me)
    bm.free()
    return me


def build(sc):
    root = bpy.data.objects.new("Dutor", None)
    sc.collection.objects.link(root)
    bowl_m, board_m = bowl_material(), board_material()
    neck_m = stage.pbr("Neck", WOOD_D, roughness=0.3, coat=0.6)
    gold = stage.pbr("Inlay", GOLD, metallic=1.0, roughness=0.25)
    gut = stage.pbr("Fret", (0.75, 0.65, 0.45), roughness=0.5)
    string_m = stage.pbr("String", (0.85, 0.82, 0.75), metallic=0.6, roughness=0.3)
    bowl, board = bowl_mesh()
    parts = [stage.link(sc, "Bowl", bowl, bowl_m, parent=root), stage.link(sc, "Board", board, board_m, parent=root)]
    neck = stage.box_mesh("Neck", NECK_W, NECK_W * 0.9, NECK_L)
    parts.append(stage.link(sc, "Neck", neck, neck_m, parent=root, loc=(0.0, 0.04, BODY_L * 0.5 + NECK_L / 2 - 0.12)))
    head = stage.box_mesh("Head", NECK_W * 1.5, NECK_W * 1.1, 0.42)
    parts.append(stage.link(sc, "Head", head, neck_m, parent=root, loc=(0.0, 0.05, NUT_Z + 0.2)))
    finial = stage.lathe("Finial", [(0.0, 0.0), (0.06, 0.02), (0.08, 0.08), (0.04, 0.16), (0.0, 0.2)], 24)
    parts.append(stage.link(sc, "Finial", finial, gold, parent=root, loc=(0.0, 0.05, NUT_Z + 0.41)))
    for k, side in enumerate((-1, 1)):
        peg = stage.lathe(f"Peg{k}", [(0.0, 0.0), (0.02, 0.0), (0.018, 0.16), (0.05, 0.18), (0.055, 0.26), (0.0, 0.28)], 16)
        ob = stage.link(sc, f"Peg{k}", peg, neck_m, parent=root, loc=(side * NECK_W * 0.6, 0.05, NUT_Z + 0.12 + 0.14 * k))
        ob.rotation_euler = (0.0, side * R(90), 0.0)
        parts.append(ob)
    for i in range(13):                                 # tied frets, closer together toward the body
        z = NUT_Z - NECK_L * (1 - 2 ** (-i / 9.0)) * 1.4
        if z < BODY_L * 0.5:
            break
        ring = stage.lathe(f"Fret{i}", [(0.068, -0.006), (0.075, -0.006), (0.075, 0.006), (0.068, 0.006)], 16)
        ring.transform(Matrix.Diagonal((1.0, 0.9, 1.0, 1.0)))
        parts.append(stage.link(sc, f"Fret{i}", ring, gut, parent=root, loc=(0.0, 0.04, z)))
    bridge = stage.box_mesh("Bridge", 0.14, 0.04, 0.03)
    parts.append(stage.link(sc, "Bridge", bridge, gold, parent=root, loc=(0.0, -0.045, BRIDGE_Z)))
    inlay = stage.lathe("Rosette", [(0.12, -0.002), (0.135, -0.002), (0.135, 0.002), (0.12, 0.002)], 48)
    ros = stage.link(sc, "Rosette", inlay, gold, parent=root, loc=(0.0, -0.004, BODY_L * 0.08))
    ros.rotation_euler = (R(90), 0, 0)
    parts.append(ros)
    strings = []
    for k, x in enumerate(STRINGS_X):
        ob = stage.link(sc, f"String{k}", string_mesh(f"String{k}", x), string_m, parent=root)
        ob.shape_key_add(name="Basis")
        bow = ob.shape_key_add(name="Bow")
        for v, kv in zip(ob.data.vertices, bow.data):
            z = v.co.z
            if BRIDGE_Z < z < NUT_Z:
                u = (z - BRIDGE_Z) / (NUT_Z - BRIDGE_Z)
                kv.co = v.co + Vector((0.05 * math.sin(math.pi * u), 0.0, 0.0))
        bow.slider_min = -1.0
        strings.append(ob)
        parts.append(ob)
    return root, parts, strings


def vibrate(strings):
    """Each pluck: the string swings ±1 every frame (motion blur turns it into a blurred envelope) and decays."""
    for k, ob in enumerate(strings):
        kb = ob.data.shape_keys.key_blocks["Bow"]
        for f in range(1, TOTAL + 1):
            amp = 0.0
            for f0, s in PLUCKS:
                if s == k and f >= f0:
                    amp = max(amp, math.exp(-(f - f0) / 9.0))
            kb.value = amp * (1 if f % 2 else -1) * 0.8
            kb.keyframe_insert("value", frame=f)


def float_path(root):
    for f in range(1, TOTAL + 1):
        u_in = env(f, *IN)
        u_out = env(f, *OUT)
        bob = 0.08 * math.sin(f * 0.11)
        root.location = (-2.5 * (1 - u_in) + 3.2 * u_out ** 1.5 + 0.9, 0.0, -8.0 * (1 - u_in) ** 2 + 8.5 * u_out ** 1.6 - 2.4 + bob)
        pluck_kick = sum(math.exp(-max(0, f - f0) / 5.0) * (f >= f0) for f0, _ in PLUCKS) * R(0.4)
        root.rotation_euler = (R(4) * math.sin(f * 0.07), TILT + R(10) * (1 - u_in) + pluck_kick, R(-6) * (1 - u_in) + R(5) * math.sin(f * 0.05))
        root.keyframe_insert("location", frame=f)
        root.keyframe_insert("rotation_euler", frame=f)


def note_mesh(name, beamed):
    """Flat eighth note (or two beamed eighths) in the XZ plane, facing the lens."""
    bm = bmesh.new()

    def head(cx):
        ring = [bm.verts.new((cx + 0.1 * math.cos(t) * math.cos(0.5) - 0.07 * math.sin(t) * math.sin(0.5), 0.0,
                              0.1 * math.cos(t) * math.sin(0.5) + 0.07 * math.sin(t) * math.cos(0.5))) for t in [2 * math.pi * i / 20 for i in range(20)]]
        bm.faces.new(ring)

    def quad(x0, z0, x1, z1, w):
        bm.faces.new([bm.verts.new(p) for p in ((x0, 0, z0), (x0 + w, 0, z0), (x1 + w, 0, z1), (x1, 0, z1))])

    head(0.0)
    quad(0.075, 0.02, 0.075, 0.5, 0.025)
    if beamed:
        head(0.34)
        quad(0.415, 0.02, 0.415, 0.5, 0.025)
        quad(0.075, 0.44, 0.415, 0.5, 0.06)
    else:
        quad(0.075, 0.5, 0.2, 0.32, 0.03)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return me


def notes(sc, root):
    """With each pluck a glowing note rises from the sound holes, sways, grows and fades."""
    rng = stage.seeded(7)
    for i, (f0, s) in enumerate(PLUCKS):
        rgb = GOLD if i % 2 == 0 else TURQ
        mat = fx.fade_material(f"Note{i}", rgb, 6.0)
        nt = mat.node_tree                                  # replace particle age with a keyed Fade value
        fade = nt.nodes.new("ShaderNodeValue")
        fade.name = "Fade"
        pw = next(n for n in nt.nodes if n.bl_idname == "ShaderNodeMath" and n.operation == "POWER")
        nt.links.new(fade.outputs[0], pw.inputs[0])
        ob = stage.link(sc, f"Note{i}", note_mesh(f"Note{i}", i % 3 == 1), mat, shadow=False)
        sc.frame_set(f0)
        start = root.matrix_world @ Vector((0.0, -0.3, BODY_L * 0.08))
        drift = Vector((rng.uniform(-1.2, 1.6), 0.0, 0.0))
        for f in range(f0 - 1, min(TOTAL, f0 + 34) + 1):
            u = (f - f0) / 34
            ob.location = start + drift * u + Vector((0.25 * math.sin(u * 7 + i), 0.0, 3.2 * u))
            s = 0.4 + 1.6 * env(f, f0, f0 + 10)
            ob.scale = (s, s, s)
            ob.rotation_euler = (0.0, R(12) * math.sin(u * 5 + i), 0.0)
            fade.outputs[0].default_value = 0.0 if f < f0 else env(f, f0, f0 + 4) * (1 - env(f, f0 + 18, f0 + 34))
            for p in ("location", "scale", "rotation_euler"):
                ob.keyframe_insert(p, frame=f)
            fade.outputs[0].keyframe_insert("default_value", frame=f)
        sp = fx.fade_material(f"NoteSpark{i}", rgb, 10.0)
        fx.particle_burst(sc, f"NoteSpark{i}", fx.point_mesh(f"NoteSparkSrc{i}", 0.12), sp, 24, (f0, f0 + 3), 18, 0.018, 0.9, rand=0.8,
                          align=(0, 0, 0.8), damping=0.08, location=tuple(start))


def build_show(sc, opts):
    root, parts, strings = build(sc)
    root.scale = (SHOW_SCALE,) * 3                 # a long thin lute: at 1.0 it read small in the tall frame
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.85, hdri="interior.exr", follow=root, lights=0.85, fog=(2.0, 6), streak=10.0)
    float_path(root)
    vibrate(strings)
    notes(sc, root)
    sc.frame_set(1)
    sh.screen_extent(sc, cam, parts, (IN[1], 60, 90))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Dutor at rest, tilted, strings shimmering and a note rising on a loop."""
    root, parts, strings = build(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=0.85, hdri="interior.exr", follow=root, lights=0.85, fog=(2.0, 6), streak=10.0)
    root.rotation_euler = (0.0, TILT, 0.0)
    n = stage.ICON_N
    for k, ob in enumerate(strings):
        kb = ob.data.shape_keys.key_blocks["Bow"]
        for f in range(0, n + 1):
            kb.value = (0.35 + 0.25 * math.sin(2 * math.pi * f / n + k * math.pi)) * (1 if f % 2 else -1)
            kb.keyframe_insert("value", frame=f)
    sc.frame_set(1)
    stage.frame_icon(cam, parts, pad=1.05)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
