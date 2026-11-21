"""UZARO gift: crowned lion. blender -b --factory-startup -P lion.py -- <main|icon> [test frames]

Main: rises from below to the centre (10-42), roars at 2 s = frame 60 (rears up, shakes, mane-pulse
scale), gold sparks around it, bursts of sparks on the roar and at the end, then a bright flash in
which the lion vanishes (118-136). Everything is gone before frame 141.
"""
import math
import os
import sys

import bpy
import numpy as np
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402

R = math.radians
NAME = "lion"
SIZE = 8.5
YAW = R(35)                   # head turned toward the camera-right (model faces -Y at yaw 0)
GOLD = (1.0, 0.62, 0.18)
CROWN_WIDTH_OF_HEAD = 0.8
FLASH_PEAK = 123
SPARK = dict(size=0.035, color=GOLD, strength=14.0)


def head_top(objs):
    """Front-top point of the lion and the head width there (root space, lion faces -Y)."""
    pts = []
    dg = bpy.context.evaluated_depsgraph_get()
    for o in objs:
        if o.type != "MESH":
            continue
        me = o.evaluated_get(dg).data
        co = np.empty(len(me.vertices) * 3, dtype=np.float32)
        me.vertices.foreach_get("co", co)
        co = co.reshape(-1, 3)
        mw = np.array(o.matrix_world)
        pts.append(co @ mw[:3, :3].T + mw[:3, 3])
    p = np.concatenate(pts)
    ymin, ymax = p[:, 1].min(), p[:, 1].max()
    front = p[p[:, 1] < ymin + 0.25 * (ymax - ymin)]
    top = front[front[:, 2].argmax()]
    band = front[front[:, 2] > top[2] - 0.35]
    width = band[:, 0].max() - band[:, 0].min()
    return Vector((0.0, float(band[:, 1].mean()), float(top[2]))), float(width)


def add_crown(lion_root, lion_objs):
    top, head_w = head_top(lion_objs)
    objs = gc.import_glb(os.path.join(gc.MODELS, "golden_crown.glb"))
    crown_root, _ = gc.normalize(objs, head_w * CROWN_WIDTH_OF_HEAD, name="Crown")
    lo, hi, size = gc.bbox_of(objs)
    crown_root.parent = lion_root
    crown_root.location = (top.x, top.y, top.z + size.z * 0.5 - size.z * 0.18)  # sits into the mane
    crown_root.rotation_euler = (R(-8), R(6), 0)  # slight jaunty tilt
    print("CROWN head_top", tuple(round(v, 2) for v in top), "head_w", round(head_w, 2))
    return objs


def flash_object(sc, center):
    m = bpy.data.materials.new("Flash")
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (0, 0, 0, 1)
    b.inputs["Emission Color"].default_value = (1.0, 0.85, 0.55, 1)
    lw = nt.nodes.new("ShaderNodeLayerWeight")
    lw.inputs["Blend"].default_value = 0.6
    soft = nt.nodes.new("ShaderNodeMath")
    soft.operation, soft.use_clamp = "SUBTRACT", True
    soft.inputs[0].default_value = 1.0
    nt.links.new(lw.outputs["Facing"], soft.inputs[1])     # 1 at the centre, 0 at the rim
    amt = nt.nodes.new("ShaderNodeMath")
    amt.operation = "MULTIPLY"
    nt.links.new(soft.outputs[0], amt.inputs[0])
    nt.links.new(amt.outputs[0], b.inputs["Alpha"])
    m.surface_render_method = "BLENDED"
    ob = bpy.data.objects.new("Flash", gc.ico_mesh("Flash", 1.0, 3))
    ob.data.materials.append(m)
    sc.collection.objects.link(ob)
    ob.location = center
    ob.visible_shadow = False
    # small, very hot core: the compositor glow turns it into the flash (a big sphere reads as a grey disc)
    for f, s in ((FLASH_PEAK - 6, 0.01), (FLASH_PEAK, 0.45), (FLASH_PEAK + 7, 0.2), (FLASH_PEAK + 13, 0.01)):
        ob.scale = (s,) * 3
        ob.keyframe_insert("scale", frame=f)
    for f, strength, alpha in ((FLASH_PEAK - 6, 0.0, 0.0), (FLASH_PEAK - 2, 150.0, 1.0), (FLASH_PEAK, 250.0, 1.0),
                               (FLASH_PEAK + 7, 60.0, 1.0), (FLASH_PEAK + 13, 0.0, 0.0)):
        b.inputs["Emission Strength"].default_value = strength
        amt.inputs[1].default_value = alpha
        b.inputs["Emission Strength"].keyframe_insert("default_value", frame=f)
        amt.inputs[1].keyframe_insert("default_value", frame=f)


def animate_main(root, rest_z):
    z = rest_z
    gc.keyframes(root, "location", [
        (10, (0, 0, z - 12.0)), (36, (0, 0, z + 0.35)), (44, (0, 0, z)),
        (58, (0, 0, z - 0.08)), (62, (0, -0.25, z + 0.12)), (84, (0, 0, z)),
    ])
    shake = [(64, 3.5), (67, -3.0), (70, 2.5), (73, -2.0), (76, 1.2), (79, -0.6)]
    rot = [(10, (0, 0, YAW)), (44, (0, 0, YAW)), (58, (R(2), 0, YAW)), (62, (R(-7), 0, YAW))]
    rot += [(f, (R(-6), R(a * 0.4), YAW + R(a))) for f, a in shake]
    rot += [(84, (0, 0, YAW)), (FLASH_PEAK - 4, (R(-2), 0, YAW))]
    gc.keyframes(root, "rotation_euler", rot)
    s = 1.0
    gc.keyframes(root, "scale", [
        (10, (0.9,) * 3), (40, (s,) * 3), (58, (s, s, s * 0.97)), (62, (s * 1.07,) * 3), (72, (s * 1.03,) * 3),
        (84, (s,) * 3), (100, (s * 1.015,) * 3), (FLASH_PEAK - 5, (s * 1.08,) * 3), (FLASH_PEAK, (0.001,) * 3),
    ])


def sparks_main(sc, root):
    gc.sparks(sc, root, "Ambient", 260, (18, 104), 26, radius=3.4, speed=0.25, random_speed=0.5, **SPARK)
    gc.sparks(sc, root, "Roar", 180, (61, 65), 22, radius=2.6, speed=2.2, random_speed=0.8, **SPARK)
    gc.sparks(sc, root, "Vanish", 260, (FLASH_PEAK - 2, FLASH_PEAK + 1), 14, radius=1.5, speed=4.0,
              random_speed=0.8, **SPARK)


def build(mode):
    sc = gc.reset_scene("Lion")
    lion_objs = gc.import_glb(os.path.join(gc.MODELS, "male_lion.glb"))
    root, _ = gc.normalize(lion_objs, SIZE, name="Lion")
    crown_objs = add_crown(root, lion_objs)
    root.rotation_euler = (0, 0, YAW)
    lo, hi, _ = gc.bbox_of(lion_objs + crown_objs)
    center_z = (lo.z + hi.z) / 2
    gc.setup_render(sc, "", samples=48, shutter=0.5)
    gc.setup_world(sc, strength=0.8, hdri="sunset.exr")
    cam = gc.setup_camera(sc)
    gc.setup_lights(sc, follow=root)
    gc.setup_glow(sc, threshold=1.2, size=8)
    if mode == "icon":
        gc.icon_camera(sc, cam, half_extent=max(hi.x - lo.x, hi.z - lo.z) * 0.6)
        root.location.z = -center_z
        gc.keyframes(root, "rotation_euler", [(1, (0, 0, YAW - R(10))), (31, (0, 0, YAW + R(10))),
                                              (61, (0, 0, YAW - R(10)))])
    else:
        rest_z = gc.SAFE_CENTER_Z - center_z
        animate_main(root, rest_z)
        sparks_main(sc, root)
        flash_object(sc, (0.0, -1.5, gc.SAFE_CENTER_Z))
    return sc


gc.run_cli(build, NAME)
