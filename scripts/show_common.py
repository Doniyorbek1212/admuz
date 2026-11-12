"""Shared setup for the UZARO full-screen gift shows (contract v2).

540x960 portrait, 24 fps, transparent film, Cycles + OptiX, motion blur, AgX with a warm grade,
shadow catcher for a soft contact shadow, PNG RGBA sequence into gift_renders/source/<id>/frames.
Reuses gift_common for import/normalize/world/lights/glow.
"""
import math
import os

import bpy

import gift_common as gc

FPS = 24
RES = (540, 960)
ICON_FPS = 15
UZARO = gc.UZARO
OUT = os.path.join(UZARO, "gift_renders")


def src_dir(gift_id, *parts):
    d = os.path.join(OUT, "source", gift_id, *parts)
    os.makedirs(d, exist_ok=True)
    return d


def setup_cycles(sc, frames, samples=64, res=RES, shutter=0.5):
    sc.render.engine = "CYCLES"
    cy = sc.cycles
    prefs = bpy.context.preferences.addons["cycles"].preferences
    try:
        prefs.compute_device_type = "OPTIX"
        prefs.get_devices()
        for d in prefs.devices:
            d.use = d.type == "OPTIX"
        cy.device = "GPU"
    except TypeError:
        cy.device = "CPU"
    cy.samples = samples
    cy.use_adaptive_sampling = True
    cy.use_denoising = True
    cy.denoiser = "OPTIX" if cy.device == "GPU" else "OPENIMAGEDENOISE"
    cy.max_bounces, cy.transparent_max_bounces = 8, 16
    rd = sc.render
    rd.fps, rd.fps_base = FPS, 1.0
    sc.frame_start, sc.frame_end = frames
    rd.resolution_x, rd.resolution_y, rd.resolution_percentage = res[0], res[1], 100
    rd.film_transparent = True
    rd.dither_intensity = 0.0
    rd.use_motion_blur, rd.motion_blur_shutter = True, shutter
    sc.view_settings.view_transform = "AgX"
    sc.view_settings.look = "AgX - Medium High Contrast"
    img = rd.image_settings
    img.file_format, img.color_mode, img.color_depth, img.compression = "PNG", "RGBA", "8", 15


def shadow_catcher(sc, z, size=40.0):
    me = bpy.data.meshes.new("ShadowCatcher")
    h = size / 2
    me.from_pydata([(-h, -h, 0), (h, -h, 0), (h, h, 0), (-h, h, 0)], [], [(0, 1, 2, 3)])
    ob = bpy.data.objects.new("ShadowCatcher", me)
    sc.collection.objects.link(ob)
    ob.location.z = z
    ob.is_shadow_catcher = True
    return ob


def setup_comp(sc, fog_threshold=1.5, fog_size=7, streak_threshold=6.0, floor=0.02):
    """Render -> star glints on the hottest speculars -> fog glow -> warm grade, then alpha rebuilt as
    max(render alpha, glow brightness) so glow survives on transparent film. Colour is never clamped."""
    sc.use_nodes = True
    nt = sc.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    N, L = nt.nodes.new, nt.links.new
    rl = N("CompositorNodeRLayers")
    streak = N("CompositorNodeGlare")
    streak.glare_type, streak.quality, streak.threshold = "STREAKS", "HIGH", streak_threshold
    streak.streaks, streak.fade, streak.mix = 4, 0.9, -0.3
    fog = N("CompositorNodeGlare")
    fog.glare_type, fog.quality, fog.threshold, fog.size = "FOG_GLOW", "HIGH", fog_threshold, fog_size
    grade = N("CompositorNodeColorBalance")
    grade.correction_method = "LIFT_GAMMA_GAIN"
    grade.gain, grade.gamma = (1.06, 1.0, 0.9), (1.02, 1.0, 0.97)
    sub = N("CompositorNodeMixRGB")
    sub.blend_type, sub.use_clamp = "SUBTRACT", True
    sub.inputs[2].default_value = (floor, floor, floor, 0.0)
    sep = N("CompositorNodeSeparateColor")
    mx = [N("CompositorNodeMath") for _ in range(3)]
    for m in mx:
        m.operation, m.use_clamp = "MAXIMUM", True
    set_a = N("CompositorNodeSetAlpha")
    set_a.mode = "REPLACE_ALPHA"
    comp = N("CompositorNodeComposite")
    L(rl.outputs["Image"], streak.inputs["Image"])
    L(streak.outputs["Image"], fog.inputs["Image"])
    L(fog.outputs["Image"], grade.inputs["Image"])
    L(fog.outputs["Image"], sub.inputs[1])
    L(sub.outputs[0], sep.inputs[0])
    L(sep.outputs["Red"], mx[0].inputs[0])
    L(sep.outputs["Green"], mx[0].inputs[1])
    L(mx[0].outputs[0], mx[1].inputs[0])
    L(sep.outputs["Blue"], mx[1].inputs[1])
    L(mx[1].outputs[0], mx[2].inputs[0])
    L(rl.outputs["Alpha"], mx[2].inputs[1])
    L(grade.outputs["Image"], set_a.inputs["Image"])
    L(mx[2].outputs[0], set_a.inputs["Alpha"])
    L(set_a.outputs["Image"], comp.inputs["Image"])

def camera_shake(cam, start, length, amp=0.08, rot_deg=0.5, seed=7):
    """Decaying hand-held shake keyed on the camera (location + small roll)."""
    import random
    rnd = random.Random(seed)
    base_loc, base_rot = cam.location.copy(), cam.rotation_euler.copy()
    cam.keyframe_insert("location", frame=start - 1)
    cam.keyframe_insert("rotation_euler", frame=start - 1)
    for i in range(length + 1):
        k = (1 - i / length) ** 2
        cam.location = base_loc + k * amp * type(base_loc)((rnd.uniform(-1, 1), 0, rnd.uniform(-1, 1)))
        cam.rotation_euler = base_rot.copy()
        cam.rotation_euler.y += k * math.radians(rot_deg) * rnd.uniform(-1, 1)
        cam.keyframe_insert("location", frame=start + i)
        cam.keyframe_insert("rotation_euler", frame=start + i)
    cam.location, cam.rotation_euler = base_loc, base_rot
    cam.keyframe_insert("location", frame=start + length + 1)
    cam.keyframe_insert("rotation_euler", frame=start + length + 1)


def render(sc, gift_id, part, test=None):
    out = src_dir(gift_id, f"{part}_test" if test else part)
    if test:
        for f in test:
            sc.frame_set(f)
            sc.render.filepath = os.path.join(out, f"f_{f:04d}.png")
            bpy.ops.render.render(write_still=True)
    else:
        sc.render.filepath = os.path.join(out, "f_")
        bpy.ops.render.render(animation=True)
    print("FRAMES_DIR", out)
    return out


def screen_extent(sc, cam, objs, frames):
    """Print the subject's screen box (0..1, camera view) at the given frames: entry/exit/safe-area check."""
    from bpy_extras.object_utils import world_to_camera_view
    for f in frames:
        sc.frame_set(f)
        dg = bpy.context.evaluated_depsgraph_get()
        co = []
        for ob in objs:
            if ob.type != "MESH" or ob.hide_render:
                continue
            oe = ob.evaluated_get(dg)
            me = oe.to_mesh()
            co += [world_to_camera_view(sc, cam, oe.matrix_world @ v.co) for v in list(me.vertices)[::7]]
            oe.to_mesh_clear()
        print(f"EXTENT f{f}: x {min(c.x for c in co):.3f}..{max(c.x for c in co):.3f}"
              f"  y {min(c.y for c in co):.3f}..{max(c.y for c in co):.3f}")
