"""UZARO v2 show: diamond_ring (tier 3, 144 f = 6 s).

A velvet box rises into frame closed, its lid swings open with a soft bounce, the ring lifts out of the cushion and
turns; dispersion in the diamond throws spectral fire, then a light burst flares from the stone and the ring fades up.
Box is procedural: no file model, no brand.
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

ID = "diamond_ring"
TOTAL = 144
RING_SIZE = 3.4
BOX_W, BOX_D, BOX_H, LID_H = 4.3, 3.7, 1.6, 1.15
GROUND_Z = -3.6
ENTER_END, OPEN_F, OPEN_END = 24, 30, 48
RISE = (46, 74)
BURST_F = 104
RING_Y = 0.15
RING_REST = GROUND_Z + BOX_H - RING_SIZE / 2 - 0.05   # stone just under the cushion surface
RING_UP = 4.6


def rounded_box(name, w, d, h, bevel=0.14, z0=0.0):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=(w, d, h), verts=bm.verts)
    bmesh.ops.translate(bm, vec=(0, 0, z0 + h / 2), verts=bm.verts)
    bmesh.ops.bevel(bm, geom=bm.edges[:], offset=bevel, segments=4, profile=0.5, affect="EDGES")
    bm.to_mesh(me)
    bm.free()
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    return me


def velvet(name, rgb):
    m = stage.pbr(name, rgb, roughness=0.75)
    b = stage.bsdf(m)
    b.inputs["Sheen Weight"].default_value = 0.5
    b.inputs["Sheen Roughness"].default_value = 0.35
    b.inputs["Sheen Tint"].default_value = (1.0, 0.75, 0.8, 1.0)
    nt = m.node_tree
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 120.0
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.25
    nt.links.new(noise.outputs[0], bump.inputs["Height"])
    nt.links.new(bump.outputs[0], b.inputs["Normal"])
    return m


def box(sc):
    """Base with a recessed cushion and a slit; lid on a back hinge with a satin lining."""
    root = bpy.data.objects.new("Box", None)
    sc.collection.objects.link(root)
    red = velvet("Velvet", (0.13, 0.002, 0.012))
    satin = stage.pbr("Satin", (0.92, 0.88, 0.82), roughness=0.3)
    cushion = velvet("Cushion", (0.2, 0.004, 0.02))
    metal = jewel.gold("BoxTrim", 0.2)
    stage.link(sc, "Base", rounded_box("Base", BOX_W, BOX_D, BOX_H), red, parent=root)
    stage.link(sc, "Cushion", rounded_box("CushionM", BOX_W - 0.46, BOX_D - 0.46, 0.34, 0.14), cushion, parent=root, loc=(0, 0, BOX_H - 0.14))
    stage.link(sc, "Trim", rounded_box("TrimM", BOX_W + 0.03, BOX_D + 0.03, 0.05, 0.015), metal, parent=root, loc=(0, 0, BOX_H - 0.04))
    hinge = bpy.data.objects.new("Hinge", None)
    sc.collection.objects.link(hinge)
    hinge.parent = root
    hinge.location = (0, BOX_D / 2 - 0.04, BOX_H)
    hinge.rotation_mode = "XYZ"
    stage.link(sc, "Lid", rounded_box("LidM", BOX_W, BOX_D, LID_H), red, parent=hinge, loc=(0, -BOX_D / 2 + 0.04, 0))
    stage.link(sc, "Lining", rounded_box("LiningM", BOX_W - 0.44, BOX_D - 0.44, 0.03, 0.01), satin, parent=hinge, loc=(0, -BOX_D / 2 + 0.04, -0.012))
    return root, hinge


def load_ring(sc):
    root, model, objs, meshes = stage.load(ID, RING_SIZE)
    gold, dia = jewel.gold("RingGold"), jewel.diamond("Diamond")
    stone = next(m for m in meshes if m.name == "Object_5")   # measured: the only mesh wholly above the band
    for m in meshes:
        m.data.materials.clear()
        m.data.materials.append(dia if m is stone else gold)
    return root, meshes, stone


def animate(box_root, hinge, ring):
    for f in range(1, TOTAL + 1):
        rise = 1 - stage.smooth(min(1.0, (f - 1) / (ENTER_END - 1)))
        box_root.location = (0.0, 0.0, GROUND_Z - 9.0 * rise + 0.1 * math.exp(-max(0, f - ENTER_END) / 3.0) * math.sin(max(0, f - ENTER_END) * 1.3))
        box_root.keyframe_insert("location", frame=f)
        box_root.rotation_euler = (R(9.0), 0.0, R(-24.0 * rise - 7.0))
        box_root.keyframe_insert("rotation_euler", frame=f)
        a = 0.0
        if f >= OPEN_F:
            t = min(1.0, (f - OPEN_F) / (OPEN_END - OPEN_F))
            a = 106.0 * stage.smooth(t) - 6.0 * math.exp(-max(0, f - OPEN_END) / 5.0) * math.sin(max(0, f - OPEN_END) * 0.9)
        hinge.rotation_euler = (R(-a), 0.0, 0.0)
        hinge.keyframe_insert("rotation_euler", frame=f)
        up = env(f, *RISE)
        out = env(f, TOTAL - 18, TOTAL)
        ring.scale = (1.0, 1.0, 1.0)
        ring.location = (0.0, RING_Y, RING_REST + RING_UP * up + 0.06 * math.sin(f / 10.0) * up + box_root.location.z - GROUND_Z + 7.0 * out * out)
        ring.keyframe_insert("location", frame=f)
        ring.rotation_euler = (R(-6.0 * up), 0.0, R(interp([(46, -70.0), (74, -38.0), (BURST_F, 26.0), (TOTAL, 60.0)], f)))
        ring.keyframe_insert("rotation_euler", frame=f)


def burst(sc, ring, stone):
    """Star flash at the stone with rays and spectral motes."""
    at = (0.0, 0.0, RING_SIZE / 2 - 0.32)
    core = stage.link(sc, "BurstCore", gc.ico_mesh("BurstCore", 0.12, 2), stage.emit("BurstCore", (1.0, 0.97, 0.9), 80.0), parent=ring, loc=at, shadow=False)
    stage.key_path(core, (BURST_F - 1, BURST_F + 2, BURST_F + 8), lambda f: {BURST_F - 1: (0.001,) * 3, BURST_F + 2: (1.6,) * 3, BURST_F + 8: (0.001,) * 3}[f], path="scale")
    for name, rgb in (("MoteR", (1.0, 0.16, 0.14)), ("MoteG", (0.25, 1.0, 0.42)), ("MoteB", (0.3, 0.46, 1.0)), ("MoteW", (1.0, 0.95, 0.85))):
        mat = stage.emit(name, rgb, 22.0)
        em = fx.particle_burst(sc, name, gc.ico_mesh(name + "E", 0.1, 2), mat, 90, (BURST_F, BURST_F + 3), 22, 0.016, 3.6, rand=0.9, damping=0.09, gravity=0.0, location=at)
        em.parent = ring
    ld = bpy.data.lights.new("Burst", "POINT")
    ld.shadow_soft_size = 0.5
    ld.use_shadow = False    # with shadows the flash blacked out half the frame on the shadow catcher: a dark rectangle
    stage.link(sc, "BurstLight", ld, parent=ring, loc=at)
    for f, e in ((BURST_F - 1, 0.0), (BURST_F + 2, 5000.0), (BURST_F + 14, 0.0)):
        ld.energy = e
        ld.keyframe_insert("energy", frame=f)
    _ = stone


def build_show(sc, opts):
    ring, meshes, stone = load_ring(sc)
    box_root, hinge = box(sc)
    box_meshes = [o for o in sc.collection.objects if o.type == "MESH" and o.name in ("Base", "Lid")]
    ring.rotation_mode = "XYZ"
    box_root.rotation_mode = "XYZ"
    cam = stage.setup(sc, TOTAL, opts["samples"], world=1.1, hdri="studio.exr", lights=0.7, fog=(1.4, 8), streak=2.2)
    sc.view_settings.view_transform, sc.view_settings.look = "Filmic", "Medium High Contrast"
    jewel.setup_gems(sc)
    sh.shadow_catcher(sc, GROUND_Z, 40)
    animate(box_root, hinge, ring)
    burst(sc, ring, stone)
    sh.screen_extent(sc, cam, meshes + box_meshes, (1, ENTER_END, 74, 110, TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Ring turning once, a slow lift on the loop."""
    ring, meshes, stone = load_ring(sc)
    ring.rotation_mode = "XYZ"
    cam = stage.setup_icon(sc, opts["samples"], world=1.1, hdri="studio.exr", lights=0.9, fog=(1.4, 8), streak=2.0)
    jewel.setup_gems(sc)
    n = stage.ICON_N
    for f in range(0, n + 1):
        w = 2 * math.pi * f / n
        ring.rotation_euler = (R(-8.0), 0.0, w)
        ring.location = (0.0, 0.0, 0.05 * math.sin(w))
        ring.keyframe_insert("rotation_euler", frame=f)
        ring.keyframe_insert("location", frame=f)
    stage.frame_icon(cam, meshes, pad=1.2)
    _ = Vector


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
