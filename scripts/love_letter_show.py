"""UZARO v2 show: love_letter (tier 1, 96 f = 4 s).

An envelope flutters down like a falling leaf and settles; the wax seal cracks in two, the flap swings open, the
letter slides out and unfolds, hearts burst out and fly past. The back of the envelope faces the camera.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, smooth  # noqa: E402

ID = "love_letter"
TOTAL = 96
W, H = 5.0, 3.4
LAND_F, CRACK_F, FLAP = 30, 38, (42, 56)
RISE, UNFOLD, BURST_F = (52, 68), (66, 78), 68
HEARTS = 26
REST_Z = -2.0
SEAL_Z = H / 2 - H * 0.56   # on the flap tip
SEAL_PROFILE = [(0, 0.06), (0.36, 0.06), (0.46, 0.0), (0.42, -0.07), (0, -0.07)]


def poly(name, verts):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], [list(range(len(verts)))])
    return me


def paper(name, rgb):
    """Fibre bump so the paper never looks like a flat plastic plane."""
    m = stage.pbr(name, rgb, roughness=0.78)
    nt = m.node_tree
    tex, bump = nt.nodes.new("ShaderNodeTexNoise"), nt.nodes.new("ShaderNodeBump")
    tex.inputs["Scale"].default_value, tex.inputs["Detail"].default_value = 60.0, 8.0
    bump.inputs["Strength"].default_value = 0.12
    nt.links.new(tex.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], stage.bsdf(m).inputs["Normal"])
    return m


def ink_paper():
    """Paper with handwriting-like rows: stripes along Z broken up along X by noise, inside margins."""
    m = paper("LetterPaper", (0.96, 0.95, 0.9))
    nt = m.node_tree
    N, L = nt.nodes.new, nt.links.new
    tc, sep = N("ShaderNodeTexCoord"), N("ShaderNodeSeparateXYZ")
    L(tc.outputs["Object"], sep.inputs[0])
    row, sin = N("ShaderNodeMath"), N("ShaderNodeMath")
    row.operation, row.inputs[1].default_value = "MULTIPLY", 16.0
    sin.operation = "SINE"
    L(sep.outputs["Z"], row.inputs[0])
    L(row.outputs[0], sin.inputs[0])
    band = N("ShaderNodeMapRange")
    band.inputs["From Min"].default_value, band.inputs["From Max"].default_value = 0.72, 0.9
    L(sin.outputs[0], band.inputs["Value"])
    noise = N("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value, noise.inputs["Detail"].default_value = 26.0, 6.0
    L(tc.outputs["Object"], noise.inputs["Vector"])
    gate = N("ShaderNodeMapRange")
    gate.inputs["From Min"].default_value, gate.inputs["From Max"].default_value = 0.44, 0.52
    L(noise.outputs["Fac"], gate.inputs["Value"])
    ab = N("ShaderNodeMath")
    ab.operation = "ABSOLUTE"
    L(sep.outputs["X"], ab.inputs[0])
    margin = N("ShaderNodeMapRange")
    margin.inputs["From Min"].default_value, margin.inputs["From Max"].default_value = 1.75, 1.85
    margin.inputs["To Min"].default_value, margin.inputs["To Max"].default_value = 1.0, 0.0
    L(ab.outputs[0], margin.inputs["Value"])
    a, b = N("ShaderNodeMath"), N("ShaderNodeMath")
    a.operation = b.operation = "MULTIPLY"
    L(band.outputs[0], a.inputs[0])
    L(gate.outputs[0], a.inputs[1])
    L(a.outputs[0], b.inputs[0])
    L(margin.outputs[0], b.inputs[1])
    mix = N("ShaderNodeMix")
    mix.data_type = "RGBA"
    L(b.outputs[0], mix.inputs[0])
    mix.inputs[6].default_value = (0.96, 0.95, 0.9, 1)
    mix.inputs[7].default_value = (0.1, 0.03, 0.06, 1)
    L(mix.outputs[2], stage.bsdf(m).inputs["Base Color"])
    return m


def half_seal(sc, name, side, mat):
    """One half of the wax disc (bisected lathe): the crack runs across it at a slant."""
    me = stage.lathe(name, SEAL_PROFILE, 48)
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], plane_co=(0, 0, 0),
                           plane_no=(side, 0.25 * side, 0.0), clear_outer=False, clear_inner=True)
    bmesh.ops.holes_fill(bm, edges=[e for e in bm.edges if e.is_boundary])
    bm.to_mesh(me)
    bm.free()
    return stage.link(sc, name, me, mat)


def envelope(sc):
    root = bpy.data.objects.new("Envelope", None)
    sc.collection.objects.link(root)
    cream, lining = paper("Cream", (0.82, 0.72, 0.56)), paper("Lining", (0.42, 0.015, 0.03))
    w, h = W / 2, H / 2
    stage.link(sc, "Plate", poly("Plate", [(-w, 0.05, -h), (w, 0.05, -h), (w, 0.05, h), (-w, 0.05, h)]), lining, parent=root)
    stage.link(sc, "Outer", poly("Outer", [(-w, 0.06, -h), (w, 0.06, -h), (w, 0.06, h), (-w, 0.06, h)]), cream, parent=root)
    stage.link(sc, "SideL", poly("SideL", [(-w, -0.05, -h), (-w, -0.05, h), (0.2, -0.05, -0.05)]), cream, parent=root)
    stage.link(sc, "SideR", poly("SideR", [(w, -0.05, h), (w, -0.05, -h), (-0.2, -0.05, -0.05)]), cream, parent=root)
    stage.link(sc, "Bottom", poly("Bottom", [(-w, -0.07, -h), (w, -0.07, -h), (0, -0.07, 0.25)]), cream, parent=root)
    flap = stage.link(sc, "Flap", poly("Flap", [(-w, 0, 0), (w, 0, 0), (0, 0, -h * 1.12 * 2 / 2)]), cream, parent=root, loc=(0, -0.09, h))
    return root, flap


def animate_envelope(root):
    frames = range(1, TOTAL + 1)

    def loc(f):
        t = smooth((f - 1) / (LAND_F - 1))
        swing = (1 - t) * 2.1 * math.sin(f / 4.2)
        drop = smooth((f - RISE[0]) / (RISE[1] - RISE[0]))
        return (swing, 0.0, 12.0 + (REST_Z - 12.0) * t - 1.0 * drop)

    def rot(f):
        k = 1 - smooth((f - 1) / (LAND_F - 1))
        return (R(38) * k * math.cos(f / 5.0), k * R(34) * math.cos(f / 4.2), k * R(16) * math.sin(f / 7.0))
    stage.key_path(root, frames, loc)
    stage.key_path(root, frames, rot, path="rotation_euler")


def seal(sc, root):
    wax = stage.pbr("Wax", (0.5, 0.008, 0.012), roughness=0.22, coat=0.6)
    for side, name in ((1, "SealA"), (-1, "SealB")):
        ob = half_seal(sc, name, side, wax)
        ob.parent = root
        rest = Vector((0, -0.16, SEAL_Z))

        def loc(f, side=side, rest=rest):
            t = max(0.0, f - CRACK_F) / sh.FPS
            return rest + Vector((side * (0.03 * smooth((f - CRACK_F + 2) / 2) + 2.4 * t), -2.0 * t, 3.0 * t - 11.0 * t * t))

        def rot(f, side=side):
            t = max(0.0, f - CRACK_F) / sh.FPS
            return (R(90) + side * 9.0 * t, side * 7.0 * t, 0.0)
        frames = [1, CRACK_F - 2, CRACK_F] + list(range(CRACK_F + 1, TOTAL + 1, 2))
        stage.key_path(ob, frames, loc)
        stage.key_path(ob, frames, rot, path="rotation_euler")
    emboss = stage.link(sc, "Emboss", stage.heart_mesh("Emboss", 0.22, 0.09), wax, parent=root, loc=(0, -0.22, SEAL_Z))
    stage.key_path(emboss, (CRACK_F - 1, CRACK_F), lambda f: (1.0,) * 3 if f < CRACK_F else (0.001,) * 3, path="scale")


def letter(sc, root):
    mat = ink_paper()
    w, h = 2.05, 1.45
    quad = [(-w, 0, 0), (w, 0, 0), (w, 0, h), (-w, 0, h)]
    low = stage.link(sc, "LetterLow", poly("LetterLow", quad), mat, parent=root)
    top = stage.link(sc, "LetterTop", poly("LetterTop", quad), mat, parent=low, loc=(0, -0.012, h))
    frames = [1] + list(range(RISE[0] - 1, RISE[1] + 2))
    stage.key_path(low, frames, lambda f: (0, 0.0, -1.45 + 3.2 * smooth((f - RISE[0]) / (RISE[1] - RISE[0]))))

    def fold(f):
        late = max(0, f - UNFOLD[1])
        return (R(180) * (1 - smooth((f - UNFOLD[0]) / (UNFOLD[1] - UNFOLD[0]))) - R(5) * math.sin(late / 2.0) * math.exp(-late / 5.0), 0, 0)
    stage.key_path(top, [1] + list(range(UNFOLD[0] - 1, UNFOLD[1] + 10)), fold, path="rotation_euler")


def hearts(sc, centre):
    rnd = stage.seeded(4)
    colours = [(0.75, 0.01, 0.03), (0.85, 0.05, 0.2), (0.85, 0.5, 0.08), (0.72, 0.012, 0.09)]
    mats = [stage.pbr(f"H{i}", c, metallic=0.25, roughness=0.18, coat=1.0, emission=c, strength=0.4) for i, c in enumerate(colours)]
    for i in range(HEARTS):
        ob = stage.link(sc, f"Heart{i}", stage.heart_mesh(f"HeartShape{i}", 1.0, 0.5, 8, 40), rnd.choice(mats))
        a = rnd.uniform(0, 2 * math.pi)
        sp = rnd.uniform(4.0, 11.0)
        v = Vector((math.cos(a) * sp * 0.6, -rnd.uniform(1.0, 7.0), abs(math.sin(a)) * sp + rnd.uniform(1, 4)))
        size, t0 = rnd.uniform(0.16, 0.5), BURST_F + rnd.uniform(0, 8)
        spin = Vector((rnd.uniform(-5, 5), rnd.uniform(-5, 5), rnd.uniform(-5, 5)))

        def loc(f, v=v, t0=t0):
            t = max(0.0, f - t0) / sh.FPS
            return centre + v * t + Vector((0, 0, -2.2 * t * t))

        def scale(f, size=size, t0=t0):
            return (max(size * smooth((f - t0) / 4), 0.0005),) * 3

        def rot(f, spin=spin, t0=t0):
            return tuple(spin * (max(0.0, f - t0) / sh.FPS))
        frames = range(BURST_F - 1, TOTAL + 1, 2)
        stage.key_path(ob, frames, loc)
        stage.key_path(ob, frames, scale, path="scale")
        stage.key_path(ob, frames, rot, path="rotation_euler")


def build_show(sc, opts):
    stage.setup(sc, TOTAL, opts["samples"], world=0.9, hdri="courtyard.exr", lights=0.5, fog=(1.5, 7), streak=3.0)
    root, flap = envelope(sc)
    animate_envelope(root)
    seal(sc, root)
    stage.key_path(flap, [1] + list(range(FLAP[0] - 1, FLAP[1] + 2)),
                   lambda f: (R(-178) * smooth((f - FLAP[0]) / (FLAP[1] - FLAP[0])), 0, 0), path="rotation_euler")
    letter(sc, root)
    centre = Vector((0, -0.5, REST_Z + 0.4))
    hearts(sc, centre)
    crack = fx.fade_material("CrackSpark", (1.0, 0.55, 0.3), 18.0)
    fx.particle_burst(sc, "Crack", gc.ico_mesh("CrackE", 0.25, 2), crack, 60, (CRACK_F, CRACK_F + 2), 12, 0.02, 3.0, rand=1.0,
                      gravity=0.2, location=(0, -0.2, REST_Z + SEAL_Z))
    glow = fx.fade_material("BurstGlow", (1.0, 0.45, 0.45), 16.0)
    fx.particle_burst(sc, "Burst", gc.ico_mesh("BurstE", 0.5, 2), glow, 180, (BURST_F, BURST_F + 8), 22, 0.02, 4.0, rand=1.2,
                      gravity=0.1, location=tuple(centre))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Sealed envelope rocking; two hearts orbit once per loop."""
    cam = stage.setup_icon(sc, opts["samples"], world=0.9, hdri="courtyard.exr", lights=0.5, fog=(1.5, 7), streak=3.0)
    n = stage.ICON_N
    root, _ = envelope(sc)
    wax = stage.pbr("Wax", (0.5, 0.008, 0.012), roughness=0.22, coat=0.6)
    d = stage.link(sc, "Seal", stage.lathe("Disc", SEAL_PROFILE, 48), wax, parent=root, loc=(0, -0.16, SEAL_Z))
    d.rotation_euler = (R(90), 0, 0)
    stage.link(sc, "Emboss", stage.heart_mesh("Emboss", 0.22, 0.09), wax, parent=root, loc=(0, -0.22, SEAL_Z))
    stage.key_path(root, range(0, n + 1), lambda f: (R(3) * math.sin(2 * math.pi * f / n), R(-5) * math.sin(2 * math.pi * f / n + 1.0), 0),
                   path="rotation_euler")
    m = stage.pbr("IconHeart", (0.75, 0.01, 0.03), metallic=0.25, roughness=0.18, coat=1.0, emission=(0.75, 0.01, 0.03), strength=0.4)
    for k in range(2):
        h = stage.link(sc, f"IH{k}", stage.heart_mesh(f"IH{k}", 0.48, 0.5, 8, 40), m)
        stage.key_path(h, range(0, n + 1), lambda f, k=k: (2.7 * math.cos(2 * math.pi * f / n + k * math.pi), -1.3,
                                                           2.2 + 0.2 * math.sin(4 * math.pi * f / n)))
    cam.location = (0, -gc.CAM_DIST, 0.7)
    cam.data.lens = gc.CAM_DIST * 18.0 / 3.4


stage.run(ID, build_show, build_icon)
