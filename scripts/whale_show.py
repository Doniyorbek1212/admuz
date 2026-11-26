"""UZARO v2 show: whale (tier 3, 144 f = 6 s).

A humpback bursts nose-first out of a patch of sea, twists in the air with its long flippers flung out, falls back on
its side and crashes in a huge splash; mist hangs with a faint rainbow while droplets rain down, and the sea fades out.
Autorig: a spine chain drives the fluke beat and the arch, two bones swing the flippers. Splash is droplets, mist and a
foam ring (particles), not a fluid sim, as in the dolphin show.
"""
import math
import os
import sys

import numpy as np
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import autorig  # noqa: E402
import dolphin_show as dolphin  # noqa: E402
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
import water  # noqa: E402
from stage import R, env, interp  # noqa: E402

ID = "whale"
TOTAL = 144
SIZE = 6.6
WATER_Z = -4.2
ELEV = R(10)
X, Y = (1, 0, 0), (0, 1, 0)
LAUNCH, APEX, CRASH, SUNK = 14, 50, 84, 112
YAW = R(-70)                     # the body topples to the left and a little toward the lens
WAVE = (2.0, 3.5, 6.0, 10.0, 16.0)


def centre(f):
    """Root path: rises out (ease-out), hangs, falls back (ease-in), sinks."""
    x = interp([(LAUNCH, 0.9), (APEX, 0.5), (CRASH, -0.5)], f)
    if f <= APEX:
        u = max(0.0, (f - LAUNCH) / (APEX - LAUNCH))
        z = WATER_Z - 3.6 + 5.8 * (1 - (1 - u) ** 2)
    elif f <= CRASH:
        u = (f - APEX) / (CRASH - APEX)
        z = WATER_Z + 2.2 - 2.4 * u**2
    else:
        z = WATER_Z - 0.2 - 2.8 * env(f, CRASH, SUNK)
    return Vector((x, 0.0, z))


def attitude(f):
    """(pitch, roll, yaw) for YXZ: nose up at launch, twisting about the long axis, toppling onto its side."""
    pitch = interp([(LAUNCH, R(-85)), (40, R(-78)), (APEX, R(-62)), (70, R(-14)), (CRASH, R(14)), (SUNK, R(32))], f)
    roll = interp([(LAUNCH, 0.0), (40, R(30)), (70, R(110)), (CRASH, R(160))], f)
    return pitch, roll, YAW


def spine_points(meshes, ys):
    """Body midline height at each y, from the vertices near the plane of symmetry (flippers excluded)."""
    co = np.concatenate([np.array([v.co[:] for v in m.data.vertices]) for m in meshes])
    mid = co[np.abs(co[:, 0]) < 0.12 * SIZE / 6.6]
    out = []
    for y in ys:
        sl = mid[np.abs(mid[:, 1] - y) < 0.08]
        z = (sl[:, 2].min() + sl[:, 2].max()) / 2 if len(sl) else 0.0
        out.append(Vector((0.0, y, z)))
    return out, co


def flipper_bones(co, side):
    """Root where the flipper meets the flank, tip at its farthest vertex; front half of the body only."""
    front = co[(co[:, 1] < 0.6) & (side * co[:, 0] > 0)]
    tip = front[np.argmax(side * front[:, 0])]
    root_band = front[(side * front[:, 0] > 0.42) & (side * front[:, 0] < 0.55) & (front[:, 2] < 0.0)]
    root = root_band.mean(axis=0) if len(root_band) else np.array([side * 0.45, tip[1] - 0.4, tip[2] + 0.4])
    return Vector(root), Vector(tip)


def submerge(mat):
    """Fade the skin out below the surface (world z), so the sunk body never shows under the alpha-faded water patch."""
    nt = mat.node_tree
    out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL" and n.is_active_output)
    shader = out.inputs["Surface"].links[0].from_socket
    geo, sep, fade = nt.nodes.new("ShaderNodeNewGeometry"), nt.nodes.new("ShaderNodeSeparateXYZ"), nt.nodes.new("ShaderNodeMapRange")
    nt.links.new(geo.outputs["Position"], sep.inputs[0])
    fade.inputs["From Min"].default_value, fade.inputs["From Max"].default_value = WATER_Z - 1.0, WATER_Z + 0.05
    nt.links.new(sep.outputs["Z"], fade.inputs["Value"])
    tr, mix = nt.nodes.new("ShaderNodeBsdfTransparent"), nt.nodes.new("ShaderNodeMixShader")
    nt.links.new(fade.outputs["Result"], mix.inputs[0])
    nt.links.new(tr.outputs[0], mix.inputs[1])
    nt.links.new(shader, mix.inputs[2])
    nt.links.new(mix.outputs[0], out.inputs["Surface"])


def load(sc):
    root, model, objs, meshes = stage.load(ID, SIZE, rot=(0, 0, R(90)))
    autorig.bake_world(meshes)
    done = set()
    for m in meshes:
        m.data.polygons.foreach_set("use_smooth", [True] * len(m.data.polygons))
        for mat in m.data.materials:
            if mat and mat.use_nodes and any(n.type == "BSDF_PRINCIPLED" for n in mat.node_tree.nodes):
                b = stage.bsdf(mat)
                b.inputs["Coat Weight"].default_value = 0.35      # wet skin
                b.inputs["Coat Roughness"].default_value = 0.12
            if mat and mat.use_nodes and mat.name not in done:
                submerge(mat)
                done.add(mat.name)
    L = SIZE
    ys = [-0.36 * L, -0.2 * L, -0.02 * L, 0.16 * L, 0.3 * L, 0.42 * L, 0.5 * L]
    pts, co = spine_points(meshes, ys)
    head_tip = Vector((0.0, -0.5 * L, pts[0].z))
    bones = [("root", None, pts[1], pts[2]), ("head", "root", pts[1], head_tip)]
    bones += autorig.chain("spine", pts[2:], "root")
    limits = {}
    for side, tag in ((-1, "L"), (1, "R")):
        a, b = flipper_bones(co, side)
        bones.append((f"flip{tag}", "root", a, b))
        limits[f"flip{tag}"] = (lambda s: lambda c: np.clip((s * c[:, 0] - 0.36) / 0.12, 0, 1) * (c[:, 1] < 0.6))(side)
    arm = autorig.add_rig(sc, "Whale", bones, meshes, power=5.0, limits=limits)
    arm.parent = root
    root.rotation_mode = "YXZ"
    return root, arm, meshes


def animate(root, arm, meshes):
    pose = autorig.Pose(arm)
    for f in range(1, TOTAL + 1):
        root.location = centre(f)
        root.rotation_euler = attitude(f)
        root.keyframe_insert("location", frame=f)
        root.keyframe_insert("rotation_euler", frame=f)
        power = 1.0 - 0.7 * env(f, 34, APEX)                  # hard strokes driving out, a lazy flex in the air
        arch = interp([(LAUNCH, 0.0), (APEX, -4.0), (72, 5.0), (CRASH, 8.0), (SUNK, 0.0)], f)
        spec = {f"spine{i}": (X, arch + a * power * math.sin(f * 0.42 - i * 0.8)) for i, a in enumerate(WAVE) if f"spine{i}" in arm.pose.bones}
        flap = interp([(LAUNCH, 0.0), (40, 38.0), (58, 24.0), (72, -22.0), (CRASH, 12.0), (SUNK, 0.0)], f) + 6 * math.sin(f * 0.3)
        spec["flipL"], spec["flipR"] = (Y, -flap), (Y, flap)
        pose.key(f, spec)
        hide = f < LAUNCH - 2 or f > SUNK
        for m in meshes:
            m.hide_render = hide
            m.keyframe_insert("hide_render", frame=f)


def big_splash(sc, at, f):
    """Crash: the dolphin's crown, mist and foam ring, then a heavier, taller sheet of spray on top."""
    dolphin.splash(sc, "Crash", at, f, 2.0)
    drop = stage.pbr("SheetDrop", (0.85, 0.93, 1.0), roughness=0.08, coat=1.0, emission=(0.6, 0.76, 0.92), strength=0.7)
    fx.particle_burst(sc, "Sheet", fx.ring_mesh("SheetR", 1.6, 0.05, 48), drop, 1400, (f, f + 5), 30, 0.05, 2.8, rand=1.6,
                      align=(0, 0, 7.5), gravity=0.75, location=(at[0], at[1], WATER_Z))
    mist = fx.fade_material("CrashMist2", (0.94, 0.97, 1.0), 1.0, 0.05, 1.0)
    fx.particle_burst(sc, "CrashMist2", fx.ring_mesh("CrashMist2R", 1.4, 0.05, 32), mist, 160, (f + 2, f + 10), 30, 0.6, 1.0, rand=1.0,
                      align=(0, 0, 2.6), damping=0.12, location=(at[0], at[1], WATER_Z))


def shed(sc, root):
    drop = stage.pbr("Shed", (0.85, 0.93, 1.0), roughness=0.08, coat=1.0, emission=(0.6, 0.76, 0.92), strength=0.8)
    em = fx.particle_burst(sc, "Shed", gc.ico_mesh("ShedE", 1.2, 1), drop, 900, (LAUNCH + 4, 70), 24, 0.028, 0.4, rand=0.8, gravity=0.8)
    em.parent = root


def rainbow(sc):
    """The dolphin's faint arc, moved over the crash and keyed to the mist."""
    dolphin.WATER_Z = WATER_Z
    dolphin.rainbow(sc)
    ob = sc.objects["Rainbow"]
    ob.location.x = centre(CRASH).x
    nt = ob.data.materials[0].node_tree
    nt.animation_data_clear()
    amt = next(n for n in nt.nodes if n.bl_idname == "ShaderNodeMath" and n.operation == "MULTIPLY"
               and n.inputs[0].is_linked and n.inputs[0].links[0].from_node.bl_idname == "ShaderNodeMath")
    stage.key_socket(amt.inputs[1], [(CRASH + 4, 0.0), (CRASH + 18, 0.18), (128, 0.18), (TOTAL - 2, 0.0)])


def camera(cam):
    cam.location = (0.0, -gc.CAM_DIST * math.cos(ELEV), gc.CAM_DIST * math.sin(ELEV) - 0.8)
    cam.rotation_euler = (R(90) - ELEV, 0, 0)


def build_show(sc, opts):
    root, arm, meshes = load(sc)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.85, hdri="sunrise.exr", lights=0.7, fog=(2.0, 6), streak=14.0)
    sc.cycles.transparent_max_bounces = 128
    camera(cam)
    animate(root, arm, meshes)
    shed(sc, root)
    dolphin.splash(sc, "Rise", centre(LAUNCH + 4), LAUNCH + 4, 1.3)
    big_splash(sc, centre(CRASH), CRASH)
    mat = water.material("Water", 7.0, 5.0, radius_keys=[(1, 0.02), (12, 1.0), (118, 1.0), (TOTAL, 0.02)])
    water.patch(sc, "Sea", WATER_Z, TOTAL, mat, span=30.0, wave=0.22, foam=False)
    rainbow(sc)
    sh.screen_extent(sc, cam, meshes, (30, APEX, 66, CRASH))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Whale caught at the top of the breach, flippers waving and flukes beating, over a still sea: exact loop."""
    global WATER_Z
    WATER_Z = -3.4
    root, arm, meshes = load(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=1.0, hdri="sunrise.exr", lights=0.85, fog=(2.0, 6), streak=8.0)
    n = stage.ICON_N
    pose = autorig.Pose(arm)
    for f in range(0, n + 1):
        w = 2 * math.pi * f / n
        root.location = (0.0, 0.0, -0.5 + 0.12 * math.sin(w))
        root.rotation_euler = (R(-70) + R(4) * math.sin(w), R(25) + R(8) * math.sin(w + 0.6), YAW)
        root.keyframe_insert("location", frame=f)
        root.keyframe_insert("rotation_euler", frame=f)
        spec = {f"spine{i}": (X, -3.0 + 0.5 * a * math.sin(w - i * 0.8)) for i, a in enumerate(WAVE) if f"spine{i}" in arm.pose.bones}
        flap = 24 + 12 * math.sin(w)
        spec["flipL"], spec["flipR"] = (Y, -flap), (Y, flap)
        pose.key(f, spec)
    mat = water.material("Water", 4.2, 5.0)
    sea = water.patch(sc, "Sea", WATER_Z, n, mat, span=22.0, res=8, wave=0.16, foam=False)
    sea.animation_data_clear()
    # shortcut: frozen sea in the icon, as for the dolphin; hardly visible at 192 px
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.15)
    stage.bake_all(sc)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
