"""UZARO v2 show: swans (tier 3, 144 f = 6 s).

Two white swans glide in from either side over a calm patch of water that fades to transparent, meet in the middle and
bow their necks toward each other until they draw a heart; their wings lift half open, a soft rose-gold heart of light
rises between them and the water glints; at the end they dissolve into sparkles. The model has no swimming take: its
standing idle plays underneath with the legs hidden below the waterline (the skin fades out under the surface), the
glide is the root travelling, and the neck bow and wing lift are a hand-keyed neck bend plus the wing-close take played
backwards. Ripple rings are expanding faded discs (no fluid sim).
"""
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import clipshow as cs  # noqa: E402
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
import water  # noqa: E402
from stage import R  # noqa: E402

ID = "swans"
TOTAL = 144
SIZE = 4.8
ELEV = R(16)                                   # camera looks down a little so the water reads as a surface
WATER_Z = -2.4
DRAFT = 0.22                                   # keel this far under the surface
MEET, BOW, WINGS, RISE, GONE = 52, 58, 82, 88, 128
GAP = 0.16                                     # half the distance between the two beaks at the heart
NECK_LOW = ("Neck_1_205", "Neck_2_204", "Neck_3_203", "Neck_4_202")
NECK_HIGH = ("Neck_5_201", "Neck_6_200", "Neck_7_199", "Neck_8_198", "Neck_9_197", "Neck_10_196", "Neck_11_195")
HEAD, KEEL, BEAK = "Head_194", "Keel_2_180", "Beak_182"
ROSE = (1.0, 0.62, 0.55)


def bow_keys(a, b=None, low=12.0, high=-16.0, head=-22.0):
    """The idle neck reaches forward at about 45 degrees: the lower neck is drawn back upright (+X), the upper neck
    curls over and down (-X) and the head points down, so the two necks read as the halves of a heart. Eases in
    from a; out again by b if given."""
    def ramp(deg):
        ks = [(a, "X", 0.0), (a + 18, "X", deg)]
        return ks + ([(b - 16, "X", deg), (b, "X", 0.0)] if b else [])
    keys = {n: ramp(low) for n in NECK_LOW}
    keys.update({n: ramp(high) for n in NECK_HIGH})
    keys[HEAD] = ramp(head)
    return keys


def fade_skin(mat, vis_keys):
    """Skin fades out below the waterline (world z) and everywhere by a keyed visibility, for the closing dissolve."""
    nt = mat.node_tree
    out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL" and n.is_active_output)
    shader = out.inputs["Surface"].links[0].from_socket
    N, L = nt.nodes.new, nt.links.new
    geo, sep, depth = N("ShaderNodeNewGeometry"), N("ShaderNodeSeparateXYZ"), N("ShaderNodeMapRange")
    L(geo.outputs["Position"], sep.inputs[0])
    depth.inputs["From Min"].default_value, depth.inputs["From Max"].default_value = WATER_Z - 0.3, WATER_Z + 0.02
    L(sep.outputs["Z"], depth.inputs["Value"])
    vis = N("ShaderNodeMath")
    vis.operation = "MULTIPLY"
    L(depth.outputs["Result"], vis.inputs[0])
    stage.key_socket(vis.inputs[1], vis_keys)
    tr, mix = N("ShaderNodeBsdfTransparent"), N("ShaderNodeMixShader")
    L(vis.outputs[0], mix.inputs[0])
    L(tr.outputs[0], mix.inputs[1])
    L(shader, mix.inputs[2])
    L(mix.outputs[0], out.inputs["Surface"])


def swan(sc, name, vis_keys):
    sc.frame_set(1)                    # the import's pose depends on the scene frame; size both swans on the same one
    root, arm, meshes = cs.load(ID, SIZE)                              # the file's swan faces -Y already
    root.name, arm.name = f"{name}Root", f"{name}Rig"
    done = set()
    for m in meshes:
        for mat in m.data.materials:
            if mat and mat.use_nodes and mat.name not in done:
                if any(n.type == "BSDF_PRINCIPLED" for n in mat.node_tree.nodes):
                    stage.shiny(mat, sheen=0.5)
                fade_skin(mat, vis_keys)
                done.add(mat.name)
    return root, arm, meshes


def shift_keys(root, axis, d):
    for fc in root.animation_data.action.fcurves:
        if fc.data_path == "location" and fc.array_index == axis:
            for kp in fc.keyframe_points:
                kp.co.y += d
                kp.handle_left.y += d
                kp.handle_right.y += d


def float_on_water(sc, root, arm, frame):
    """Keys z so the keel sits DRAFT under the surface at `frame`, with a slow bob."""
    sc.frame_set(frame)
    keel = (arm.matrix_world @ arm.pose.bones[KEEL].head).z
    shift_keys(root, 2, WATER_Z - DRAFT - keel)
    fc = next(fc for fc in root.animation_data.action.fcurves if fc.data_path == "location" and fc.array_index == 2)
    for kp in fc.keyframe_points:
        bob = 0.03 * math.sin(2 * math.pi * kp.co.x / 48 + root.location.x)
        kp.co.y += bob
        kp.handle_left.y += bob
        kp.handle_right.y += bob


def glide(sc, side, v):
    """One swan from the left (side -1, swimming +X) or the right (side +1)."""
    name = "SwanL" if side < 0 else "SwanR"
    root, arm, meshes = swan(sc, name, [(1, 1.0), (GONE, 1.0), (GONE + 12, 0.0)])
    plan = [cs.Take("Idle_GLTF", 1, (1, 31), repeat=2.2, speed=v),
            cs.Take("Idle_GLTF", MEET - 10, (1, 31), repeat=1.4, blend=14),
            cs.Take("CloseWing_GLTF", WINGS, (12, 31), reverse=True, blend=8)]
    seq = cs.sequence(arm, plan)
    cs.travel(root, TOTAL, R(90) * -side, seq, MEET, (side * 1.4, 0.0))
    sc.frame_set(WINGS + 20)                     # the held end of the wing lift: beaks just apart there
    beak = (arm.matrix_world @ arm.pose.bones[BEAK].tail).x
    shift_keys(root, 0, side * GAP - beak)
    float_on_water(sc, root, arm, RISE)
    return root, arm, meshes


def ripples(sc, centres):
    """Thin rings spreading from each swan as it settles."""
    mat = stage.emit("Ripple", (0.85, 0.92, 1.0), 0.0)
    nt = mat.node_tree
    em = next(n for n in nt.nodes if n.type == "EMISSION")
    for i, (x, f0) in enumerate(centres):
        ob = stage.link(sc, f"Ripple{i}", stage.lathe(f"RippleMesh{i}", [(0.92, 0.0), (1.0, 0.004), (1.08, 0.0)], 64),
                        mat, loc=(x, 0.0, WATER_Z + 0.01), shadow=False)
        for f, s in ((f0, 0.2), (f0 + 40, 2.4)):
            ob.scale = (s, s * 0.6, 1.0)
            ob.keyframe_insert("scale", frame=f)
        ob.hide_render = True
        ob.keyframe_insert("hide_render", frame=f0 - 1)
        ob.hide_render = False
        ob.keyframe_insert("hide_render", frame=f0)
        ob.hide_render = True
        ob.keyframe_insert("hide_render", frame=f0 + 40)
    stage.key_socket(em.inputs["Strength"], [(1, 0.0), (MEET, 0.0), (MEET + 6, 0.9), (MEET + 50, 0.0)])


def heart_light(sc, top_z):
    """A rose-gold heart of light rising out of the space between the two necks."""
    m = fx.fade_material("HeartGlow", ROSE, 3.2, 1.0, 1.0)
    ob = stage.link(sc, "HeartGlow", stage.heart_mesh("HeartGlow", 0.75, 0.3), m, loc=(0.0, 0.2, top_z), shadow=False)
    for f, s, z in ((RISE, 0.0, top_z), (RISE + 10, 1.0, top_z + 0.4), (GONE, 1.15, top_z + 1.2), (GONE + 10, 0.0, top_z + 1.5)):
        ob.scale = (s, s, s)
        ob.location.z = z
        ob.keyframe_insert("scale", frame=f)
        ob.keyframe_insert("location", frame=f)
    return ob


def sparkle(sc, centre_z):
    gold = fx.fade_material("Sparkle", (1.0, 0.85, 0.6), 9.0)
    glint = fx.particle_burst(sc, "Glint", fx.point_mesh("GlintSrc", 1.6), gold, 160, (MEET, GONE), 18, 0.02, 0.05,
                              rand=0.3, location=(0.0, 0.0, WATER_Z + 0.02))
    glint.scale = (1.6, 0.6, 0.02)
    burst = fx.particle_burst(sc, "Dissolve", fx.point_mesh("DissolveSrc", 0.9), gold, 420, (GONE - 2, GONE + 10), 26, 0.03,
                              1.0, rand=1.0, align=(0.0, 0.0, 0.8), damping=0.3, gravity=-0.1, location=(0.0, 0.0, centre_z))
    burst.scale = (1.8, 0.5, 0.9)


def build_show(sc, opts):
    left = glide(sc, -1, 0.08)
    right = glide(sc, 1, 0.08)
    meshes = left[2] + right[2]
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.9, hdri="sunrise.exr", lights=0.85, fog=(2.0, 6), streak=12.0)
    cam.location = (0.0, -gc.CAM_DIST * math.cos(ELEV), gc.CAM_DIST * math.sin(ELEV) - 0.8)
    cam.rotation_euler = (R(90) - ELEV, 0.0, 0.0)
    sc.cycles.transparent_max_bounces = 128
    mat = water.material("Water", 5.5, 3.0, radius_keys=[(1, 0.02), (14, 1.0), (GONE, 1.0), (TOTAL - 2, 0.02)])
    water.patch(sc, "Lake", WATER_Z, TOTAL, mat, span=24.0, wave=0.06, chop=0.4, foam=False)
    sc.frame_set(RISE + 10)
    lo, hi = gc.world_bbox(meshes)
    ripples(sc, [(lo.x + 0.9, MEET - 4), (hi.x - 0.9, MEET - 2)])
    heart_light(sc, hi.z - 0.6)
    sparkle(sc, (lo.z + hi.z) / 2 + 0.3)
    sh.screen_extent(sc, cam, meshes, (1, 30, MEET, RISE + 10, GONE))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """The heart pose, held, bobbing gently; the heart of light pulses once per loop."""
    n = stage.ICON_N
    meshes = []
    for side in (-1, 1):
        name = "SwanL" if side < 0 else "SwanR"
        root, arm, ms = swan(sc, name, [(1, 1.0)])
        cs.sequence(arm, [cs.Take("Idle_GLTF", 0, (1, 31), blend=0, repeat=2)])
        root.rotation_euler = (0.0, 0.0, R(90) * -side)
        sc.frame_set(1)
        beak = (arm.matrix_world @ arm.pose.bones[BEAK].tail)
        keel = (arm.matrix_world @ arm.pose.bones[KEEL].head).z
        root.location.x += side * GAP - beak.x
        root.location.z += WATER_Z - DRAFT - keel
        stage.key_path(root, range(1, n + 2), lambda f, z=root.location.z, s=side: (root.location.x, root.location.y,
                       z + 0.03 * math.sin(2 * math.pi * f / n + s)))
        meshes += ms
    cam = stage.setup_icon(sc, opts["samples"], world=0.9, hdri="sunrise.exr", lights=0.85, fog=(2.0, 6), streak=8.0)
    sc.cycles.transparent_max_bounces = 128
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.12)
    mat = water.material("Water", 3.0, 1.6)
    sea = water.patch(sc, "Lake", WATER_Z, n, mat, span=14.0, res=8, wave=0.04, chop=0.3, foam=False)
    sea.animation_data_clear()
    lo, hi = gc.world_bbox(meshes)
    m = fx.fade_material("HeartGlow", ROSE, 3.2, 1.0, 1.0)
    h = stage.link(sc, "HeartGlow", stage.heart_mesh("HeartGlow", 0.4, 0.3), m, loc=(0.0, 0.2, hi.z - 0.5), shadow=False)
    stage.key_path(h, range(1, n + 2), lambda f: (0.85 + 0.15 * math.sin(2 * math.pi * f / n),) * 3, path="scale")


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
