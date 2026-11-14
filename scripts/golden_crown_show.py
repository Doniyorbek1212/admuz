"""UZARO v2 show: golden_crown (tier 3, 144 f = 6 s).

Crown descends from above through gold god rays, slowing and turning, gems refracting; star glints fire on the gems and
finials as it spins, then it tilts up and rises away. Gems are identified per island of the file's single mesh.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402
import jewel  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, env, interp  # noqa: E402

ID = "golden_crown"
TOTAL = 144
SIZE = 5.2
PATH_Z = [(1, 10.0), (40, 0.5), (118, 0.0), (TOTAL, 11.0)]
SPIN = [(1, -320.0), (40, -60.0), (118, 150.0), (TOTAL, 340.0)]
TILT = [(1, 22.0), (40, 14.0), (70, 12.0), (118, 12.0), (TOTAL, 28.0)]
FINIAL_Z = 1.45 * SIZE / 6
BAND_Z = -1.1 * SIZE / 6
RUBY = (0.8, 0.02, 0.05)
SAPPHIRE = (0.03, 0.12, 0.85)


def split_gems(ob):
    """Band gems are small islands near the band height: give them gem materials, the rest gold. Prints what it found."""
    me = ob.data
    me.materials.clear()
    me.materials.append(jewel.gold("CrownGold"))
    me.materials.append(stage.pbr("Ruby", RUBY, roughness=0.02, transmission=1.0, ior=1.77, coat=1.0))
    me.materials.append(stage.pbr("Sapphire", SAPPHIRE, roughness=0.02, transmission=1.0, ior=1.77, coat=1.0))
    me.materials.append(jewel.diamond("FinialGem"))
    groups = stage.islands(me)
    mw = ob.matrix_world
    picks = {}
    for g in groups:
        pts = [mw @ me.vertices[i].co for i in g]
        zs = [p.z for p in pts]
        xs = [math.hypot(p.x, p.y) for p in pts]
        h, w = max(zs) - min(zs), max(xs) - min(xs)
        if h < 0.5 and w < 0.5:
            picks[id(g)] = (g, sum(zs) / len(zs))
    print("INFO_ISLANDS", len(groups), "small", len(picks), [round(z, 2) for _, z in picks.values()][:40])
    vmat = {}
    for n, (g, z) in enumerate(picks.values()):
        idx = 3 if z > 0.4 else (1 + n % 2)
        for i in g:
            vmat[i] = idx
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.verts.ensure_lookup_table()
    for fc in bm.faces:
        idx = vmat.get(fc.verts[0].index, 0)
        fc.material_index = idx
    bm.to_mesh(me)
    bm.free()
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))


def glints(sc, root):
    """Tiny hot spheres riding the finials and band: when they face the camera the comp star filter fires."""
    mat = stage.emit("Glint", (1.0, 0.93, 0.78), 0.0)
    sock = mat.node_tree.nodes["Emission"].inputs["Strength"]
    stage.key_socket(sock, [(f, 90.0 * max(0.0, math.sin(f * 0.21)) ** 18 + 8.0) for f in range(1, TOTAL + 1)])
    r_top, r_band = 2.6 * SIZE / 6, 2.5 * SIZE / 6
    for i in range(9):
        a = 2 * math.pi * i / 9
        stage.link(sc, f"GlintT{i}", gc.ico_mesh(f"GlintT{i}", 0.018, 1), mat, parent=root, loc=(r_top * math.cos(a), r_top * math.sin(a), FINIAL_Z + 0.1), shadow=False)
        stage.link(sc, f"GlintB{i}", gc.ico_mesh(f"GlintB{i}", 0.014, 1), mat, parent=root, loc=(r_band * math.cos(a + 0.3), r_band * math.sin(a + 0.3), BAND_Z), shadow=False)


def god_rays(sc):
    """Tall soft blades falling from above behind the crown."""
    rnd = stage.seeded(7)
    rays = bpy.data.materials.new("GodRays")
    rays.use_nodes = True
    nt = rays.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    tc, sep, ramp, tr, em, mix, out = N("ShaderNodeTexCoord"), N("ShaderNodeSeparateXYZ"), N("ShaderNodeMapRange"), N("ShaderNodeBsdfTransparent"), N("ShaderNodeEmission"), N("ShaderNodeMixShader"), N("ShaderNodeOutputMaterial")
    L(tc.outputs["Generated"], sep.inputs[0])
    ramp.inputs["From Min"].default_value, ramp.inputs["From Max"].default_value = 0.0, 1.0
    ramp.inputs["To Min"].default_value, ramp.inputs["To Max"].default_value = 0.0, 1.0
    ramp.interpolation_type = "SMOOTHSTEP"
    L(sep.outputs["Z"], ramp.inputs["Value"])
    em.inputs["Color"].default_value = (1.0, 0.76, 0.34, 1.0)
    em.inputs["Strength"].default_value = 1.3
    fac = N("ShaderNodeMath")
    fac.operation = "MULTIPLY"
    L(ramp.outputs[0], fac.inputs[0])
    stage.key_socket(fac.inputs[1], [(30, 0.0), (52, 0.16), (116, 0.16), (130, 0.0)])
    across = N("ShaderNodeSeparateXYZ")     # soft blade edges: 1 on the axis, 0 at both sides
    L(tc.outputs["Generated"], across.inputs[0])
    centred = N("ShaderNodeMath")
    centred.operation = "SINE"
    pi_x = N("ShaderNodeMath")
    pi_x.operation, pi_x.inputs[1].default_value = "MULTIPLY", math.pi
    L(across.outputs["X"], pi_x.inputs[0])
    L(pi_x.outputs[0], centred.inputs[0])
    soft = N("ShaderNodeMath")
    soft.operation = "MULTIPLY"
    L(fac.outputs[0], soft.inputs[0])
    L(centred.outputs[0], soft.inputs[1])
    L(soft.outputs[0], mix.inputs[0])
    L(tr.outputs[0], mix.inputs[1])
    L(em.outputs[0], mix.inputs[2])
    L(mix.outputs[0], out.inputs["Surface"])
    for i in range(12):
        x = -5.0 + 10.0 * (i + rnd.random()) / 12     # evenly spread: pure chance bunched them to one side
        w = rnd.uniform(0.16, 0.42)
        me = bpy.data.meshes.new(f"GodRay{i}")
        me.from_pydata([(-w * 2.4, 0, -4.5), (w * 2.4, 0, -4.5), (w * 0.6, 0, 8.5), (-w * 0.6, 0, 8.5)], [], [(0, 1, 2, 3)])
        ob = stage.link(sc, f"GodRay{i}", me, rays, loc=(x * 0.7, 1.8 + rnd.random(), 0.0), shadow=False)
        ob.rotation_euler = (0, R(-x * 2.0), 0)
        ob.visible_shadow = False


def build_show(sc, opts):
    root, model, objs, meshes = stage.load(ID, SIZE)
    bpy.context.view_layer.update()
    for m in meshes:
        split_gems(m)
    root.rotation_mode = "XYZ"
    cam = stage.setup(sc, TOTAL, opts["samples"], world=1.0, hdri="studio.exr", lights=0.55, fog=(2.4, 7), streak=3.5)
    jewel.setup_gems(sc)
    frames = range(1, TOTAL + 1)
    stage.key_path(root, frames, lambda f: (0.0, 0.0, interp(PATH_Z, f) + 0.08 * math.sin(f / 9.0) * env(f, 40, 56)))
    stage.key_path(root, frames, lambda f: (R(interp(TILT, f)), 0.0, R(interp(SPIN, f))), path="rotation_euler")
    glints(sc, root)
    god_rays(sc)
    mat = stage.emit("GoldDust", (1.0, 0.82, 0.42), 18.0)
    fx.particle_burst(sc, "GoldDust", fx.ring_mesh("DustR", 2.6, 0.1, 40), mat, 460, (6, TOTAL - 8), 30, 0.016, 0.3, rand=1.0,
                      align=(0.0, 0.0, -1.1), damping=0.06, gravity=0.0, location=(0.0, 0.0, 3.4))
    sh.screen_extent(sc, cam, meshes, (1, 40, 90, TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """One full turn in the loop: 9-fold crown, so 40 deg would loop too, but the full turn shows every gem."""
    root, model, objs, meshes = stage.load(ID, SIZE)
    bpy.context.view_layer.update()
    for m in meshes:
        split_gems(m)
    root.rotation_mode = "XYZ"
    cam = stage.setup_icon(sc, opts["samples"], world=1.0, hdri="studio.exr", lights=0.55, fog=(2.4, 7), streak=3.5)
    jewel.setup_gems(sc)
    n = stage.ICON_N
    for f in range(0, n + 1):
        root.rotation_euler = (R(14), 0.0, 2 * math.pi * f / n)
        root.keyframe_insert("rotation_euler", frame=f)
    glints(sc, root)
    stage.frame_icon(cam, meshes, pad=1.15)
    _ = Vector


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
