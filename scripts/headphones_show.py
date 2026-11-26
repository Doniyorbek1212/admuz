"""UZARO v2 show: headphones (tier 2, 120 f = 5 s). Original UZARO over-ear headphones, built here from scratch.

Design (ours): a glossy pearl-white headband with a gold inlay along its crown and a black leather pad, gold yokes,
round cups with smoked-glass faces, a neon ring that runs from turquoise to magenta around each face and a gold "U"
in the centre, black leather cushions.
Show: they drop in spinning, the neon rings draw themselves on, then they thump to a 120 bpm bass beat: on every
beat the cups kick, the rings flash, sound-wave rings spread from the cups, a circular equaliser behind them jumps and
glowing notes drift out; at the end they spin away downward.
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
import guitar_show as gs  # noqa: E402
import show_common as sh  # noqa: E402
import stage  # noqa: E402
from stage import R  # noqa: E402

ID = "headphones"
TOTAL = 120
LAND, GLOW, BEAT0, BEAT, LAST_BEAT, LEAVE = 24, 26, 36, 12, 96, 104
BAND_R = 1.6
CUP_X, CUP_Z = 1.62, -0.95
CUP_R = 0.82
SCALE = 1.5                                     # modelled about 3.5 wide; this fills the frame
YAW = R(-34)                                    # turned so the right cup's neon face looks at the lens
PEARL, GOLD, LEATHER = (0.92, 0.9, 0.88), (1.0, 0.74, 0.34), (0.018, 0.016, 0.016)
NEON = [(0.1, 0.95, 0.9), (1.0, 0.2, 0.75)]
EQ_N, EQ_R = 56, 2.7


# ------------------------------------------------------------------ geometry
def sweep(name, a0, a1, radius, width, thick, segs=64, round_=0.35):
    """Band along the arc (x, z) = radius*(cos a, sin a) from a0 to a1 (radians); cross-section a rounded rectangle
    `thick` radially by `width` along Y."""
    prof = []
    for k in range(16):                             # superellipse section
        t = 2 * math.pi * k / 16
        c, s = math.cos(t), math.sin(t)
        e = 2 * round_
        prof.append((thick / 2 * math.copysign(abs(c) ** e, c), width / 2 * math.copysign(abs(s) ** e, s)))
    bm = bmesh.new()
    rings = []
    for i in range(segs + 1):
        a = a0 + (a1 - a0) * i / segs
        n = Vector((math.cos(a), 0.0, math.sin(a)))
        rings.append([bm.verts.new(n * (radius + u) + Vector((0.0, v, 0.0))) for u, v in prof])
    for r0, r1 in zip(rings, rings[1:]):
        for k in range(len(prof)):
            j = (k + 1) % len(prof)
            bm.faces.new((r0[k], r0[j], r1[j], r1[k]))
    bm.faces.new(rings[0])
    bm.faces.new(list(reversed(rings[-1])))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    return me


def torus(name, major, minor, segs=64, sides=16):
    me = bpy.data.meshes.new(name)
    verts, faces = [], []
    for i in range(segs):
        a = 2 * math.pi * i / segs
        for j in range(sides):
            b = 2 * math.pi * j / sides
            r = major + minor * math.cos(b)
            verts.append((r * math.cos(a), r * math.sin(a), minor * math.sin(b)))
    for i in range(segs):
        for j in range(sides):
            i2, j2 = (i + 1) % segs, (j + 1) % sides
            faces.append((i * sides + j, i2 * sides + j, i2 * sides + j2, i * sides + j2))
    me.from_pydata(verts, [], faces)
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    return me


def along_x(me, side):
    """Lathe/torus meshes are built about Z; turn them to face outward along +X (side 1) or -X (side -1)."""
    me.transform(Matrix.Rotation(R(90 * side), 4, "Y"))
    return me


# ------------------------------------------------------------------ materials
def neon_material(name):
    """Turquoise to magenta around the ring (angle about the cup axis); strength keyed on node 'Glow'."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    tc, sep = N("ShaderNodeTexCoord"), N("ShaderNodeSeparateXYZ")
    L(tc.outputs["Object"], sep.inputs[0])
    ang = N("ShaderNodeMath")
    ang.operation = "ARCTAN2"
    L(sep.outputs["Z"], ang.inputs[0])
    L(sep.outputs["Y"], ang.inputs[1])
    u = N("ShaderNodeMapRange")
    u.inputs["From Min"].default_value, u.inputs["From Max"].default_value = -math.pi, math.pi
    L(ang.outputs[0], u.inputs["Value"])
    ramp = N("ShaderNodeValToRGB")
    el = ramp.color_ramp.elements
    el[0].color, el[1].color = (*NEON[0], 1), (*NEON[0], 1)
    mid = el.new(0.5)
    mid.color = (*NEON[1], 1)
    L(u.outputs["Result"], ramp.inputs["Fac"])
    # draw-on: only the part of the ring with u < Reveal glows
    rev = N("ShaderNodeValue")
    rev.name = "Reveal"
    lt = N("ShaderNodeMath")
    lt.operation = "LESS_THAN"
    L(u.outputs["Result"], lt.inputs[0])
    L(rev.outputs[0], lt.inputs[1])
    glow = N("ShaderNodeValue")
    glow.name = "Glow"
    st = N("ShaderNodeMath")
    st.operation = "MULTIPLY"
    L(lt.outputs[0], st.inputs[0])
    L(glow.outputs[0], st.inputs[1])
    em = N("ShaderNodeEmission")
    L(ramp.outputs["Color"], em.inputs["Color"])
    L(st.outputs[0], em.inputs["Strength"])
    out = N("ShaderNodeOutputMaterial")
    L(em.outputs[0], out.inputs["Surface"])
    return m


def leather():
    m = stage.pbr("Leather", LEATHER, roughness=0.55)
    nt = m.node_tree
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value, noise.inputs["Detail"].default_value = 90.0, 8.0
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.15
    nt.links.new(noise.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs[0], stage.bsdf(m).inputs["Normal"])
    return m


def mats():
    return {"pearl": stage.pbr("PearlWhite", PEARL, roughness=0.22, coat=1.0),
            "gold": stage.pbr("Gold", GOLD, metallic=1.0, roughness=0.16),
            "leather": leather(),
            "glass": stage.pbr("Smoke", (0.01, 0.012, 0.02), metallic=0.2, roughness=0.06, coat=1.0)}


# ------------------------------------------------------------------ build
def build(sc):
    """Root (moves) -> Spin (turns) -> parts; per cup a 'Kick' empty that the beat scales. Returns dict of handles."""
    root = bpy.data.objects.new("PhonesRoot", None)
    spin = bpy.data.objects.new("PhonesSpin", None)
    for o in (root, spin):
        sc.collection.objects.link(o)
    spin.parent = root
    M = mats()
    meshes, neons = [], []

    def add(name, me, mat, parent):
        ob = stage.link(sc, name, me, mat, parent=parent)
        meshes.append(ob)
        return ob

    a0, a1 = R(14), R(166)
    add("Band", sweep("Band", a0, a1, BAND_R, 0.52, 0.14), M["pearl"], spin)
    add("Inlay", sweep("Inlay", R(40), R(140), BAND_R + 0.07, 0.12, 0.025), M["gold"], spin)
    add("Pad", sweep("Pad", R(36), R(144), BAND_R - 0.13, 0.38, 0.13), M["leather"], spin)
    kicks = []
    for side in (-1, 1):
        x = side * CUP_X
        top = Vector((side * BAND_R * math.cos(a0), 0.0, BAND_R * math.sin(a0)))
        bar = stage.lathe(f"Slider{side}", [(0.0, 0.0), (0.05, 0.0), (0.05, 1.0), (0.0, 1.0)], 16)
        length = top.z - (CUP_Z + CUP_R + 0.12)
        bar.transform(Matrix.Diagonal((1.0, 1.0, length, 1.0)))
        bar.transform(Matrix.Translation((x, 0.0, CUP_Z + CUP_R + 0.12)))
        add(f"Slider{side}", bar, M["gold"], spin)
        yoke = torus(f"Yoke{side}", CUP_R + 0.12, 0.045, 48, 10)
        yoke.transform(Matrix.Rotation(R(90), 4, "Y"))            # ring in the YZ plane around the cup
        bmy = bmesh.new()
        bmy.from_mesh(yoke)
        bmesh.ops.delete(bmy, geom=[v for v in bmy.verts if v.co.z < -0.05], context="VERTS")   # keep the top half
        bmy.to_mesh(yoke)
        bmy.free()
        yoke.transform(Matrix.Translation((x, 0.0, CUP_Z)))
        add(f"Yoke{side}", yoke, M["gold"], spin)
        kick = bpy.data.objects.new(f"Kick{side}", None)
        sc.collection.objects.link(kick)
        kick.parent, kick.location = spin, (x, 0.0, CUP_Z)
        kicks.append(kick)
        shell = along_x(stage.lathe(f"Shell{side}", [(0.0, -0.22), (CUP_R * 0.86, -0.22), (CUP_R, -0.12), (CUP_R, 0.12),
                                                     (CUP_R * 0.92, 0.22), (0.0, 0.22)], 64), side)
        add(f"Shell{side}", shell, M["pearl"], kick)
        face = along_x(stage.lathe(f"Face{side}", [(0.0, 0.0), (CUP_R * 0.8, 0.0), (CUP_R * 0.74, 0.03), (0.0, 0.035)], 64), side)
        face.transform(Matrix.Translation((side * 0.22, 0.0, 0.0)))
        add(f"Face{side}", face, M["glass"], kick)
        ring = along_x(torus(f"Neon{side}", CUP_R * 0.68, 0.032), side)
        ring.transform(Matrix.Translation((side * 0.26, 0.0, 0.0)))
        nm = neon_material(f"NeonMat{side}")
        ob = stage.link(sc, f"Neon{side}", ring, nm, parent=kick, shadow=False)
        meshes.append(ob)
        neons.append(nm)
        u = bpy.data.curves.new(f"U{side}", "FONT")
        u.body, u.size, u.align_x, u.align_y, u.extrude, u.bevel_depth = "U", 0.62, "CENTER", "CENTER", 0.03, 0.008
        uo = bpy.data.objects.new(f"U{side}", u)
        uo.data.materials.append(M["gold"])
        sc.collection.objects.link(uo)
        uo.parent = kick
        uo.rotation_euler = (R(90), 0.0, R(90 * side))
        uo.location = (side * 0.26, 0.0, 0.0)
        meshes.append(uo)
        cush = along_x(torus(f"Cushion{side}", CUP_R * 0.7, 0.2), side)
        cush.transform(Matrix.Translation((-side * 0.3, 0.0, 0.0)))
        add(f"Cushion{side}", cush, M["leather"], kick)
    return {"root": root, "spin": spin, "kicks": kicks, "neons": neons, "meshes": meshes}


# ------------------------------------------------------------------ animation
def beats():
    return list(range(BEAT0, LAST_BEAT + 1, BEAT))


def animate(h):
    root, spin = h["root"], h["spin"]
    root.scale = (SCALE,) * 3
    for f, loc in ((1, (0.0, 0.0, 10.0)), (LAND, (0.0, 0.0, 0.2)), (LAND + 5, (0.0, 0.0, 0.0)), (LEAVE, (0.0, 0.0, 0.1)),
                   (TOTAL, (0.0, -1.5, -12.0))):
        root.location = loc
        root.keyframe_insert("location", frame=f)
    for f, deg in ((1, 720.0 - 34.0), (LAND, -34.0), (LEAVE, -34.0), (TOTAL, -34.0 - 540.0)):
        spin.rotation_euler = (R(8), 0.0, R(deg))
        spin.keyframe_insert("rotation_euler", frame=f)
    for k, f in enumerate(beats()):                  # the whole set nods on each beat, the cups kick outward
        for kick in h["kicks"]:
            for df, s in ((-1, 1.0), (0, 1.09), (3, 0.98), (7, 1.0)):
                kick.scale = (s,) * 3
                kick.keyframe_insert("scale", frame=f + df)
        for df, tilt in ((-1, 8.0), (1, 4.5), (6, 8.0)):
            spin.rotation_euler = (R(tilt), 0.0, R(-34.0 + (3.0 if k % 2 else -3.0) * (df == 1)))
            spin.keyframe_insert("rotation_euler", frame=f + df)
    for nm in h["neons"]:
        nodes = nm.node_tree.nodes
        stage.key_socket(nodes["Reveal"].outputs[0], [(1, 0.0), (GLOW, 0.0), (GLOW + 9, 1.01)])
        glow = [(1, 0.0), (GLOW, 4.0)]
        for f in beats():
            glow += [(f - 1, 3.5), (f, 11.0), (f + 5, 4.0)]
        stage.key_socket(nodes["Glow"].outputs[0], glow + [(LEAVE, 4.0), (TOTAL, 2.0)])


def waves(sc, h):
    """Sound-wave rings spreading out of each cup on the beats."""
    for side, kick in zip((-1, 1), h["kicks"]):
        for k, f in enumerate(beats()[::2]):
            m = stage.emit(f"WaveMat{side}{k}", NEON[k % 2], 0.0)
            em = m.node_tree.nodes["Emission"].inputs["Strength"]
            stage.key_socket(em, [(f - 1, 0.0), (f, 4.0), (f + 16, 0.0)])
            ob = stage.link(sc, f"Wave{side}{k}", along_x(torus(f"WaveMesh{side}{k}", 1.0, 0.012, 64, 6), side), m,
                            parent=kick, shadow=False)
            for df, s, x in ((-1, 0.0, 0.3), (0, 0.6, 0.3), (16, 2.4, 1.6)):
                ob.scale = (s,) * 3
                ob.location = (side * x, 0.0, 0.0)
                ob.keyframe_insert("scale", frame=f + df)
                ob.keyframe_insert("location", frame=f + df)
            for df, hide in ((-2, True), (0, False), (17, True)):       # an unlit torus would read as a dark line
                ob.hide_render = hide
                ob.keyframe_insert("hide_render", frame=f + df)


def equaliser(sc, h):
    """A ring of glowing bars behind the headphones that jump with the beat (and a slower melody shimmer)."""
    rnd = random.Random(5)
    eq = bpy.data.objects.new("EQ", None)
    sc.collection.objects.link(eq)
    eq.parent, eq.location = h["root"], (0.0, 1.6, -0.2)
    mats = [stage.emit(f"EQMat{c}", rgb, 3.0) for c, rgb in enumerate(NEON + [GOLD])]
    for i in range(EQ_N):
        a = 2 * math.pi * i / EQ_N
        me = stage.box_mesh(f"Bar{i}", 0.07, 0.04, 1.0)
        me.transform(Matrix.Translation((0.0, 0.0, 0.5)))
        ob = stage.link(sc, f"Bar{i}", me, mats[i % 3 if i % 7 else 2], parent=eq, shadow=False)
        ob.location = (EQ_R * math.cos(a), 0.0, EQ_R * math.sin(a))
        ob.rotation_euler = (0.0, R(90) - a, 0.0)
        phase = rnd.uniform(0, 2 * math.pi)
        for f in range(1, TOTAL + 1, 2):
            on = stage.smooth(min(1.0, max(0.0, (f - GLOW) / 10))) * (1 - stage.smooth(min(1.0, max(0.0, (f - LEAVE) / 10))))
            kick = max(math.exp(-((f - b) % BEAT) / 3.0) if f >= b else 0.0 for b in beats())
            mel = 0.5 + 0.5 * math.sin(2 * math.pi * f / 18 + phase + 3 * a)
            h_ = on * (0.12 + 0.35 * mel + 0.7 * kick * (0.6 + 0.4 * math.cos(2 * a)))
            ob.scale = (1.0, 1.0, h_) if on > 0.01 else (0.0, 0.0, 0.0)
            ob.keyframe_insert("scale", frame=f)
    return eq


def notes(sc, h):
    for k, f in enumerate(beats()[1::2]):
        for side, kick in zip((-1, 1), h["kicks"]):
            em = bpy.data.objects.new(f"NoteAnchor{side}{k}", None)
            sc.collection.objects.link(em)
            em.parent, em.location = h["root"], (side * 1.9, -0.4, -0.6)
            gs.notes(sc, f"Note{side}{k}", f, 3, em, seed=10 * k + side)


def build_show(sc, opts):
    h = build(sc)
    animate(h)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.55, hdri="night.exr", lights=0.9, fog=(1.4, 7), streak=6.0)
    gs.rim(sc)
    waves(sc, h)
    equaliser(sc, h)
    notes(sc, h)
    sh.screen_extent(sc, cam, h["meshes"], (1, 12, LAND, 60, LEAVE, TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Two beats per loop: the cups kick, the neon flashes, the equaliser jumps; frame n+1 equals frame 1."""
    n = stage.ICON_N
    h = build(sc)
    h["spin"].rotation_euler = (R(8), 0.0, R(-34))
    for kick in h["kicks"]:
        for f in (1, 1 + n // 2):
            for df, s in ((0, 1.08), (3, 0.98), (7, 1.0), (n // 2 - 1, 1.0)):
                kick.scale = (s,) * 3
                kick.keyframe_insert("scale", frame=f + df)
    for nm in h["neons"]:
        nodes = nm.node_tree.nodes
        nodes["Reveal"].outputs[0].default_value = 1.01
        stage.key_socket(nodes["Glow"].outputs[0], [(1, 11.0), (6, 4.0), (1 + n // 2, 11.0), (6 + n // 2, 4.0), (n + 1, 11.0)])
    cam = stage.setup_icon(sc, opts["samples"], world=0.55, hdri="night.exr", lights=0.9, fog=(1.4, 7), streak=6.0)
    gs.rim(sc)
    sc.frame_set(1)
    stage.frame_icon(cam, h["meshes"], pad=1.12)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
