"""UZARO v2 show: treasure_chest (tier 3, 144 f = 6 s).

The chest slams down from above with a thud, rattles, then the lid bursts open: gold light pours up through volumetric
shafts while a blast (force field on rigid bodies) throws coins and gems out over the front, where they bounce and settle.
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
from stage import R, env  # noqa: E402

ID = "treasure_chest"
TOTAL = 144
SIZE = 6.0
K = 0.92
GROUND_Z = -3.0
YAW = R(-14)
RIM_Z = 0.77                    # top of the walls, model space
HINGE = Vector((0.0, 1.14, 0.62))
LAND_F, OPEN_F, OPEN_END = 22, 50, 62
BLAST = (52, 60)
COINS, GEMS = 90, 22
GOLD = (1.0, 0.72, 0.28)
LID_PARTS = ("lid", "lockhinge")
GEM_RGB = ((0.85, 0.03, 0.08), (0.03, 0.2, 0.9), (0.03, 0.65, 0.2), (0.55, 0.05, 0.8))


def coin_mesh():
    me = stage.lathe("Coin", [(0, 0.022), (0.17, 0.022), (0.19, 0.0), (0.17, -0.022), (0, -0.022)], 18)
    return me


def gem_mesh(name):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=8, radius1=0.2, radius2=0.12, depth=0.1)
    bmesh.ops.create_cone(bm, cap_ends=True, segments=8, radius1=0.2, radius2=0.0, depth=0.24, matrix=Matrix.Translation((0, 0, -0.17)).to_3x3().to_4x4() @ Matrix.Translation((0, 0, -0.17)))
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return me


def load(sc):
    root, model, objs, meshes = stage.load(ID, SIZE, hide=("goldpile", "skull"))
    for o in objs:
        if o.type == "ARMATURE" or o.animation_data:
            o.animation_data_clear()
    for m in meshes:
        for s in m.data.materials:
            stage.shiny(s, coat=0.1)
    root.scale = (K, K, K)
    root.rotation_euler = (0, 0, YAW)
    return root, model, meshes


def rig_lid(sc, root, meshes):
    """Empty at the back hinge carries the lid parts; wall parts stay put."""
    hinge = bpy.data.objects.new("Hinge", None)
    sc.collection.objects.link(hinge)
    hinge.parent = root
    hinge.location = HINGE
    hinge.rotation_mode = "XYZ"
    bpy.context.view_layer.update()
    for m in meshes:
        if m.name.startswith("lid"):
            w = m.matrix_world.copy()
            m.parent = hinge
            m.matrix_parent_inverse = hinge.matrix_world.inverted()
            m.matrix_world = w
    return hinge


def animate(root, hinge):
    start = 13.0
    for f in range(1, TOTAL + 1):
        t = min(1.0, (f - 1) / (LAND_F - 1))
        drop = start * (1 - t * t)
        bounce = 0.0
        if f > LAND_F:
            bounce = 0.42 * abs(math.sin((f - LAND_F) * 0.42)) * math.exp(-(f - LAND_F) / 5.0)
        rattle = 0.0
        if OPEN_F - 12 < f < OPEN_F:
            rattle = (f - OPEN_F + 12) / 12.0 * 0.018 * math.sin(f * 3.1)
        root.location = (rattle, 0.0, GROUND_Z + 0.94 * K + drop + bounce)
        root.keyframe_insert("location", frame=f)
        a = -8.0 * env(f, OPEN_F - 12, OPEN_F - 1) * abs(math.sin(f * 1.6))
        if f >= OPEN_F:     # thrown open past vertical, then falls back and bounces
            t = (f - OPEN_F) / (OPEN_END - OPEN_F)
            a = -118.0 * stage.smooth(t) - 7.0 * math.exp(-max(0.0, f - OPEN_END) / 7.0) * math.sin(max(0.0, f - OPEN_END) * 0.9)
        hinge.rotation_euler = (R(-a), 0, 0)
        hinge.keyframe_insert("rotation_euler", frame=f)


def pile(sc, root):
    """Heap resting inside the rim, held by a kinematic lid plane until the blast."""
    stage.rigid_world(sc, TOTAL, substeps=24)
    rnd = stage.seeded(4)
    floor = stage.link(sc, "Floor", stage.box_mesh("Floor", 60, 60, 0.2), loc=(0, 0, GROUND_Z - 0.1))
    floor.hide_render = True
    stage.rigid(sc, floor, "PASSIVE", shape="BOX", friction=0.5, bounce=0.35)
    box = stage.link(sc, "BoxCollide", stage.box_mesh("BoxCollide", 4.9 * K, 2.45 * K, 1.71 * K), loc=(0, -0.08 * K, GROUND_Z + 0.855 * K))
    box.hide_render = True
    box.rotation_euler = (0, 0, YAW)
    box.parent = None
    stage.rigid(sc, box, "PASSIVE", shape="BOX", friction=0.5, bounce=0.25)
    # the box is passive only once landed; before that the treasure is carried by root and hidden behind the lid
    gold = stage.pbr("CoinGold", GOLD, metallic=1.0, roughness=0.22)
    coin = coin_mesh()
    coin.materials.append(gold)
    pieces = []
    top = GROUND_Z + 1.72 * K
    for i in range(COINS):
        ob = bpy.data.objects.new(f"Coin{i}", coin)
        sc.collection.objects.link(ob)
        pieces.append((ob, 0.6))
    gems = [stage.pbr(f"Gem{i}", c, roughness=0.03, transmission=0.9, ior=2.1, coat=1.0) for i, c in enumerate(GEM_RGB)]
    for i in range(GEMS):
        me = gem_mesh(f"Gem{i}")
        me.materials.append(gems[i % len(gems)])
        ob = bpy.data.objects.new(f"Gem{i}", me)
        sc.collection.objects.link(ob)
        pieces.append((ob, 1.0))
    for i, (ob, mass) in enumerate(pieces):
        ob.location = (rnd.uniform(-1.9, 1.9) * K, rnd.uniform(-0.8, 0.8) * K, top + 0.12 + 0.3 * rnd.random() + 0.12 * (i % 3))
        ob.rotation_euler = (rnd.uniform(0, 6.3), rnd.uniform(0, 6.3), rnd.uniform(0, 6.3))
        rb = stage.rigid(sc, ob, "ACTIVE", mass=mass, shape="CONVEX_HULL", friction=0.45, bounce=0.5)
        rb.kinematic = True
        ob.keyframe_insert("rigid_body.kinematic", frame=BLAST[0] - 1)
        rb.kinematic = False
        ob.keyframe_insert("rigid_body.kinematic", frame=BLAST[0])
        ob.scale = (0.001,) * 3         # hidden under the lid until it opens: no pop-through during the slam
        ob.keyframe_insert("scale", frame=OPEN_F - 3)
        ob.scale = (1.0,) * 3
        ob.keyframe_insert("scale", frame=OPEN_F + 1)
    # upward, slightly forward blast: strength keyed on, off fast
    bpy.ops.object.effector_add(type="FORCE", location=(0, 0.9, top - 0.7))
    blast = bpy.context.active_object
    blast.name = "Blast"
    blast.field.flow, blast.field.noise = 0.0, 2.0
    for f, v in ((BLAST[0] - 1, 0.0), (BLAST[0], 95.0), (BLAST[1] - 2, 60.0), (BLAST[1], 0.0)):
        blast.field.strength = v
        blast.keyframe_insert("field.strength", frame=f)
    return pieces


def gold_light(sc, root):
    """Inside the rim: a hot gold quad, a volumetric cone of shafts, a light on the lid."""
    me = stage.box_mesh("Glow", 2 * 2.3, 2.3, 0.02)
    mat = stage.emit("ChestGlow", (1.0, 0.68, 0.22), 0.0)
    stage.link(sc, "Glow", me, mat, parent=root, loc=(0, -0.08, RIM_Z - 0.03), shadow=False)
    sock = mat.node_tree.nodes["Emission"].inputs["Strength"]
    stage.key_socket(sock, [(OPEN_F - 1, 0.0), (OPEN_F + 4, 40.0), (OPEN_F + 30, 16.0), (TOTAL, 12.0)])
    ld = bpy.data.lights.new("ChestLight", "POINT")
    ld.color, ld.shadow_soft_size = (1.0, 0.72, 0.3), 1.5
    stage.link(sc, "ChestLight", ld, parent=root, loc=(0, -0.2, RIM_Z + 1.0))
    for f, e in ((OPEN_F - 1, 0.0), (OPEN_F + 4, 5200.0), (OPEN_F + 30, 2000.0), (TOTAL, 1500.0)):
        ld.energy = e
        ld.keyframe_insert("energy", frame=f)
    # god rays: additive tall blades with a bottom-up fade, fanned out of the chest
    rnd = stage.seeded(11)
    rays = bpy.data.materials.new("Rays")
    rays.use_nodes = True
    nt = rays.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    tc, sep, ramp, tr, em, mix, out = N("ShaderNodeTexCoord"), N("ShaderNodeSeparateXYZ"), N("ShaderNodeMapRange"), N("ShaderNodeBsdfTransparent"), N("ShaderNodeEmission"), N("ShaderNodeMixShader"), N("ShaderNodeOutputMaterial")
    L(tc.outputs["Generated"], sep.inputs[0])
    ramp.inputs["From Min"].default_value, ramp.inputs["From Max"].default_value = 0.0, 1.0
    ramp.inputs["To Min"].default_value, ramp.inputs["To Max"].default_value = 0.75, 0.0
    L(sep.outputs["Z"], ramp.inputs["Value"])
    em.inputs["Color"].default_value = (1.0, 0.7, 0.25, 1.0)
    em.inputs["Strength"].default_value = 2.2
    L(ramp.outputs[0], mix.inputs[0])
    L(tr.outputs[0], mix.inputs[1])
    L(em.outputs[0], mix.inputs[2])
    L(mix.outputs[0], out.inputs["Surface"])
    blades = []
    for i in range(14):
        x = rnd.uniform(-1.9, 1.9)
        w, h = rnd.uniform(0.12, 0.34), rnd.uniform(3.6, 6.4)
        bme = bpy.data.meshes.new(f"Ray{i}")
        bme.from_pydata([(-w, 0, 0), (w, 0, 0), (w * 2.2, 0, h), (-w * 2.2, 0, h)], [], [(0, 1, 2, 3)])
        ob = stage.link(sc, f"Ray{i}", bme, rays, parent=root, loc=(x, rnd.uniform(-0.3, 0.3), RIM_Z), shadow=False)
        ob.rotation_euler = (0, R(x * 13.0), 0)
        ob.scale = (1, 1, 0.001)
        ob.keyframe_insert("scale", frame=OPEN_F)
        ob.scale = (1, 1, 1)
        ob.keyframe_insert("scale", frame=OPEN_F + 8)
        blades.append(ob)
    return blades


def sparkle(sc):
    mat = stage.emit("Sparkle", (1.0, 0.82, 0.42), 24.0)
    fx.particle_burst(sc, "Sparkle", fx.ring_mesh("SparkR", 1.6, 0.1, 32), mat, 420, (OPEN_F, TOTAL - 10), 26, 0.02, 0.5, rand=1.0,
                      align=(0.0, 0.0, 3.6), damping=0.12, gravity=-0.02, location=(0, 0, GROUND_Z + 1.8 * K))


def build_show(sc, opts):
    root, model, meshes = load(sc)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.7, hdri="courtyard.exr", lights=0.65, fog=(1.5, 7), streak=2.6)
    sc.cycles.film_transparent_glass = False
    sh.shadow_catcher(sc, GROUND_Z, 50)
    hinge = rig_lid(sc, root, meshes)
    animate(root, hinge)
    gold_light(sc, root)
    pile(sc, root)
    sparkle(sc)
    sh.camera_shake(cam, LAND_F, 10, amp=0.11, rot_deg=0.6, seed=3)
    sh.camera_shake(cam, OPEN_F, 7, amp=0.05, rot_deg=0.3, seed=9)
    sh.screen_extent(sc, cam, meshes, (1, LAND_F, 80, TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Open chest glowing, a few coins lifting and falling back on the loop."""
    root, model, meshes = load(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=0.7, hdri="courtyard.exr", lights=0.65, fog=(1.5, 7), streak=2.6)
    hinge = rig_lid(sc, root, meshes)
    hinge.rotation_euler = (R(112), 0, 0)
    root.rotation_euler = (0, 0, R(-16))
    me = stage.box_mesh("Glow", 2 * 2.3, 2.3, 0.02)
    mat = stage.emit("ChestGlow", (1.0, 0.68, 0.22), 26.0)
    glow = stage.link(sc, "Glow", me, mat, parent=root, loc=(0, 0, RIM_Z - 0.05), shadow=False)
    sock = mat.node_tree.nodes["Emission"].inputs["Strength"]
    n = stage.ICON_N
    stage.key_socket(sock, [(f, 26.0 + 6.0 * math.sin(2 * math.pi * f / n)) for f in range(0, n + 1, 3)])
    gold = stage.pbr("CoinGold", GOLD, metallic=1.0, roughness=0.22)
    coin = coin_mesh()
    coin.materials.append(gold)
    rnd = stage.seeded(5)
    for i in range(18):
        ob = bpy.data.objects.new(f"Coin{i}", coin)
        sc.collection.objects.link(ob)
        ob.parent = root
        x, y, phase, h = rnd.uniform(-1.9, 1.9), rnd.uniform(-0.7, 0.7), rnd.random(), rnd.uniform(1.0, 2.8)
        spin = rnd.choice((1, 2, 3))
        for f in range(0, n + 1):
            t = (f / n + phase) % 1.0
            ob.location = (x, y, RIM_Z + h * 4 * t * (1 - t))
            ob.rotation_euler = (2 * math.pi * spin * f / n, 2 * math.pi * f / n, 0)
            ob.keyframe_insert("location", frame=f)
            ob.keyframe_insert("rotation_euler", frame=f)
    sc.frame_set(1)
    stage.frame_icon(cam, meshes + [glow], pad=1.2)
    _ = (Vector, gc)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
