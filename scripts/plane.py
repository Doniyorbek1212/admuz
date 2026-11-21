"""UZARO gift: plane. blender -b --factory-startup -P plane.py -- <main|icon> [test frames]

Main: enters bottom-left far away, climbs diagonally to the top right while coming closer (grows),
two white contrails from the engines. Path is keyed in screen space (u, v in -1..1, depth d) so the
framing is exact; the nose always points along the velocity.
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402

R = math.radians
NAME = "plane"
SIZE = 8.5
UP_HINT = Vector((0.0, -0.45, 1.0)).normalized()  # top of the plane leans toward the camera
# (frame, u, v, depth from camera); offscreen at both ends incl. half the plane's size
PATH = [(4, -1.85, -1.05, 46), (10, -1.55, -0.9, 44), (40, -0.75, -0.42, 37), (75, -0.05, 0.02, 31),
        (110, 0.6, 0.42, 26), (141, 1.95, 1.25, 21), (147, 2.35, 1.5, 20)]
NOSE_DEPTH_FACTOR = 0.35  # nose aims mostly sideways (side 3/4 view) instead of straight at the camera
TRAIL_FADE_START = 118    # contrail shrinks from its old end to nothing by the last rendered frame
BAKE = (5, 146)          # baked a few frames past the render range for motion blur
ENGINE_OFFSETS = [Vector((0.55, s * 1.15, -0.42)) for s in (-1, 1)]  # model space after normalize
TRAIL_FRAMES = 40        # visible contrail length in frames of flight
TRAIL_RADIUS = 0.13
NAVY = (0.006, 0.008, 0.045)


def catmull(keys, f):
    """Catmull-Rom through (frame, *values) keys, evaluated at frame f."""
    i = max(1, min(len(keys) - 3, next((k for k in range(len(keys) - 1) if keys[k + 1][0] >= f), 1)))
    p0, p1, p2, p3 = (Vector(k[1:]) for k in keys[i - 1:i + 3])
    t = (f - keys[i][0]) / (keys[i + 1][0] - keys[i][0])
    return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                  + (-p0 + 3 * p1 - 3 * p2 + p3) * t ** 3)


def world_pos(f):
    u, v, d = catmull(PATH, f)
    return Vector((u * d * gc.HALF_W / gc.CAM_DIST, d - gc.CAM_DIST, v * d * gc.HALF_H / gc.CAM_DIST))


def orientation(f):
    vel = world_pos(f + 0.5) - world_pos(f - 0.5)
    vel.y *= NOSE_DEPTH_FACTOR
    fwd = vel.normalized()
    side = UP_HINT.cross(fwd).normalized()   # model +Y (left wing)
    up = fwd.cross(side)
    return Matrix((fwd, side, up)).transposed().to_quaternion()


def animate_main(root):
    root.rotation_mode = "QUATERNION"
    prev = None
    for f in range(BAKE[0], BAKE[1] + 1):
        root.location = world_pos(f)
        q = orientation(f)
        if prev is not None and prev.dot(q) < 0:
            q.negate()  # keep quaternion keys on one hemisphere: no flips between keys
        prev = q
        root.rotation_quaternion = q
        root.keyframe_insert("location", frame=f)
        root.keyframe_insert("rotation_quaternion", frame=f)


def trail_material():
    m = bpy.data.materials.new("Contrail")
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (0.9, 0.9, 0.92, 1)
    b.inputs["Emission Color"].default_value = (1, 1, 1, 1)
    b.inputs["Emission Strength"].default_value = 0.15  # mostly lit: shaded edges read on light backgrounds
    b.inputs["Roughness"].default_value = 1.0
    lw = nt.nodes.new("ShaderNodeLayerWeight")
    lw.inputs["Blend"].default_value = 0.4
    inv = nt.nodes.new("ShaderNodeMath")
    inv.operation, inv.use_clamp = "MULTIPLY_ADD", True
    inv.inputs[1].default_value, inv.inputs[2].default_value = -0.85, 0.85  # soft, see-through edges
    nt.links.new(lw.outputs["Facing"], inv.inputs[0])
    nt.links.new(inv.outputs[0], b.inputs["Alpha"])
    m.surface_render_method = "BLENDED"
    return m


def taper_curve():
    cu = bpy.data.curves.new("ContrailTaper", "CURVE")
    sp = cu.splines.new("BEZIER")
    pts = [(0.0, 0.0), (0.3, 1.0), (0.9, 0.75), (1.0, 0.35)]  # old end ... engine
    sp.bezier_points.add(len(pts) - 1)
    for bp, (x, y) in zip(sp.bezier_points, pts):
        bp.co = (x, y, 0)
        bp.handle_left_type = bp.handle_right_type = "AUTO"
    ob = bpy.data.objects.new("ContrailTaper", cu)
    bpy.context.scene.collection.objects.link(ob)
    ob.hide_render = True
    return ob


def contrails(sc):
    mat, taper = trail_material(), taper_curve()
    frames = list(range(BAKE[0], gc.ACT_END + 1))
    n = len(frames) - 1
    for k, off in enumerate(ENGINE_OFFSETS):
        model_off = off  # offsets are in root space (model is centred and scaled inside the root)
        cu = bpy.data.curves.new(f"Contrail{k}", "CURVE")
        cu.dimensions = "3D"
        cu.bevel_mode, cu.bevel_depth, cu.bevel_resolution = "ROUND", TRAIL_RADIUS, 3
        cu.taper_object, cu.use_map_taper = taper, True
        cu.bevel_factor_mapping_start = cu.bevel_factor_mapping_end = "SEGMENTS"
        sp = cu.splines.new("POLY")
        sp.points.add(n)
        for p, f in zip(sp.points, frames):
            m = Matrix.Translation(world_pos(f)) @ orientation(f).to_matrix().to_4x4()
            p.co = (*(m @ model_off), 1.0)
        cu.materials.append(mat)
        ob = bpy.data.objects.new(f"Contrail{k}", cu)
        sc.collection.objects.link(ob)
        for f in range(BAKE[0], BAKE[1] + 1):
            idx = min(f, gc.ACT_END) - BAKE[0]
            cu.bevel_factor_end = max(idx / n, 1e-3)
            fade = min(1.0, max(0.0, (gc.ACT_END - f) / (gc.ACT_END - TRAIL_FADE_START)))
            cu.bevel_factor_start = min(cu.bevel_factor_end, max(0.0, (idx - TRAIL_FRAMES * fade) / n))
            cu.keyframe_insert("bevel_factor_end", frame=f)
            cu.keyframe_insert("bevel_factor_start", frame=f)
        for fc in cu.animation_data.action.fcurves:
            for kp in fc.keyframe_points:
                kp.interpolation = "LINEAR"


def animate_icon(root):
    root.rotation_mode = "XYZ"
    gc.keyframes(root, "rotation_euler", [
        (1, (R(-8), R(-10), R(-35))), (31, (R(8), R(-10), R(-35))), (61, (R(-8), R(-10), R(-35)))])
    gc.keyframes(root, "location", [(1, (0, 0, -0.1)), (31, (0, 0, 0.1)), (61, (0, 0, -0.1))])


def build(mode):
    sc = gc.reset_scene("Plane")
    objs = gc.import_glb(os.path.join(gc.MODELS, "a320-200_with_cockpit_ver_viii.glb"))
    root, _ = gc.normalize(objs, SIZE, name="Plane")
    gc.repaint(bpy.data.materials["fuselarge"], os.path.join(gc.TEXTURES, "plane_fuselage.png"), coat=0.5)
    gc.flat_color(bpy.data.materials["tail"], NAVY, roughness=0.3, coat=0.5)  # logo decal removed
    gc.setup_render(sc, "", samples=48, shutter=0.5)
    gc.setup_world(sc, strength=1.0, hdri="sunrise.exr")
    cam = gc.setup_camera(sc)
    gc.setup_lights(sc, follow=root)
    gc.setup_glow(sc, threshold=1.3, size=6)
    if mode == "icon":
        gc.icon_camera(sc, cam, half_extent=SIZE * 0.55)
        animate_icon(root)
    else:
        animate_main(root)
        contrails(sc)
    return sc


if __name__ == "__main__":
    gc.run_cli(build, NAME)
