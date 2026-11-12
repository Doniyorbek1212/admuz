"""UZARO dragon show (tier 3): flies in flapping, hovers, lifts its head and breathes a long fire stream
(Mantaflow fire + smoke, embers, orange fire light, camera shake), then flies out.

blender -b --factory-startup -P dragon_show.py -- <show|icon> [f=30,80] [s=16] [nofire]
Model: "European Dragon" by Regina Cachoa (CC BY), its Fly cycle drives wings/body; head, neck and jaw
are re-keyed on top of it.
"""
import math
import os
import sys

import bpy
from mathutils import Quaternion, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402

ID = "dragon"
R = math.radians
TOTAL = 156                        # 6.5 s
SIZE = 5.2
YAW = R(35)                        # faces toward screen right
ARRIVE_F, LIFT_F, FIRE_F, FIRE_END, LEAVE_F = 40, 46, 62, 106, 118
PATH = ((1, (-7.5, 3.0, 5.5)), (ARRIVE_F, (-0.6, 0.0, 1.6)), (LEAVE_F, (-0.4, 0.0, 1.8)), (TOTAL, (8.0, 2.5, 7.0)))
FLY = "Fly_Object_6"
JAW, HEAD = "DEF-Bone_014", "DEF-neck.004_012"
NECK = ("DEF-neck.002_010", "DEF-neck.003_011", HEAD)
JAW_OPEN, NECK_LIFT = 38.0, 55.0          # positive = head up toward camera (key_head negates; probed)
FIRE_WIND = 14.0
FIRE_SPEED = 15.0


def smooth(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


def env(f, a, b):
    return smooth((f - a) / (b - a))


def parse():
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    opts = {"mode": a[0] if a else "show", "test": None, "samples": 64, "fire": True}
    for t in a[1:]:
        if t.startswith("f="):
            opts["test"] = [int(x) for x in t[2:].split(",")]
        elif t.startswith("s="):
            opts["samples"] = int(t[2:])
        elif t == "nofire":
            opts["fire"] = False
    return opts


def path_pos(f):
    for (f0, p0), (f1, p1) in zip(PATH, PATH[1:]):
        if f <= f1:
            return Vector(p0).lerp(Vector(p1), smooth((f - f0) / (f1 - f0)))
    return Vector(PATH[-1][1])


# ------------------------------------------------------------------ rig
def load_dragon():
    objs = gc.import_glb(os.path.join(gc.MODELS, "european_dragon.glb"), hide=("Icosphere",))
    objs = [o for o in objs if "Icosphere" not in o.name]
    root, _ = gc.normalize(objs, SIZE, name="Dragon")
    arm = next(o for o in objs if o.type == "ARMATURE")
    return root, arm, [o for o in objs if o.type == "MESH"]


def cycle_fly(arm, keep_out):
    """Fly take on a loop, minus the bones we key ourselves; returns their take pose (rest of our keys)."""
    act = bpy.data.actions[FLY].copy()
    act.name = "DragonShow"
    base = {}
    for n in keep_out:
        pb = arm.pose.bones[n]
        pb.rotation_mode = "QUATERNION"
        base[n] = pb.rotation_quaternion.copy()
    for fc in list(act.fcurves):
        if any(f'"{n}"' in fc.data_path for n in keep_out):
            act.fcurves.remove(fc)
        else:
            fc.modifiers.new("CYCLES")
    arm.animation_data.action = act
    return base


def lateral(arm, n):
    return (arm.data.bones[n].matrix_local.to_3x3().inverted() @ Vector((1, 0, 0))).normalized()


def animate(root, arm, base, icon=False):
    root.rotation_mode = "QUATERNION"
    yaw = Quaternion((0, 0, 1), YAW)
    for f in range(1, TOTAL + 1):
        p = path_pos(f)
        v = path_pos(f + 1) - path_pos(f - 1)
        tilt_axis = Vector((0, 0, 1)).cross(v)
        lean = min(R(28), v.length * 0.9)
        tilt = Quaternion(tilt_axis.normalized(), lean) if tilt_axis.length > 1e-5 else Quaternion()
        root.location = p
        root.rotation_quaternion = tilt @ yaw
        root.keyframe_insert("location", frame=f)
        root.keyframe_insert("rotation_quaternion", frame=f)
        key_head(arm, base, f)


def key_head(arm, base, f):
    lift = NECK_LIFT * (env(f, LIFT_F, FIRE_F - 4) - env(f, FIRE_END + 2, LEAVE_F + 6))
    jaw = JAW_OPEN * (env(f, FIRE_F - 8, FIRE_F) - env(f, FIRE_END, FIRE_END + 8))
    jaw += 4.0 * math.sin(f * 0.9) * env(f, FIRE_F, FIRE_F + 4) * (1 - env(f, FIRE_END - 4, FIRE_END))
    for i, n in enumerate(NECK):
        pb = arm.pose.bones[n]
        pb.rotation_quaternion = Quaternion(lateral(arm, n), -R(lift / len(NECK))) @ base[n]
        pb.keyframe_insert("rotation_quaternion", frame=f)
    pb = arm.pose.bones[JAW]
    pb.rotation_quaternion = Quaternion(lateral(arm, JAW), R(jaw)) @ base[JAW]
    pb.keyframe_insert("rotation_quaternion", frame=f)


def mouth(arm):
    pb = arm.pose.bones
    mw = arm.matrix_world
    top, bot = mw @ pb["DEF-Teeth_Top_013"].tail, mw @ pb["DEF-Teeth_Bottom_016"].tail
    back = mw @ pb[HEAD].head
    tip = (top + bot) / 2
    return tip, (tip - back).normalized()


# ------------------------------------------------------------------ fire
def fire(sc, arm, tip, direction, cache_dir):
    centre = tip + direction * 3.2
    bpy.ops.mesh.primitive_cube_add(size=2.0, location=centre)
    dom = bpy.context.active_object
    dom.name = "FireDomain"
    dom.scale = (4.0, 4.0, 3.6)
    mod = dom.modifiers.new("Fluid", "FLUID")
    mod.fluid_type = "DOMAIN"
    ds = mod.domain_settings
    ds.domain_type = "GAS"
    ds.resolution_max = 128
    ds.use_adaptive_domain = True
    ds.vorticity = 0.6
    ds.burning_rate, ds.flame_smoke, ds.flame_vorticity = 0.55, 0.15, 1.4
    ds.flame_max_temp = 3.0
    ds.use_dissolve_smoke, ds.dissolve_speed = True, 18
    ds.cache_directory = cache_dir
    ds.cache_type = "ALL"
    ds.cache_frame_start, ds.cache_frame_end = 1, TOTAL
    dom.data.materials.append(fire_material())
    dom.cycles.use_motion_blur = False   # velocity blur dilates the volume mesh by the flow speed: 10+ min per frame in "Computing Volume Mesh"
    src = bpy.data.objects.new("FireSrc", gc.ico_mesh("FireSrc", 0.3, 2))
    sc.collection.objects.link(src)
    src.hide_render = True
    c = src.constraints.new("COPY_LOCATION")
    c.target, c.subtarget, c.head_tail = arm, "DEF-Teeth_Top_013", 1.0
    fm = src.modifiers.new("Fluid", "FLUID")
    fm.fluid_type = "FLOW"
    fs = fm.flow_settings
    fs.flow_type, fs.flow_behavior, fs.flow_source = "BOTH", "INFLOW", "MESH"
    fs.surface_distance = 0.12
    fs.use_initial_velocity = True
    fs.velocity_coord = tuple(direction * FIRE_SPEED)
    for f, v in ((FIRE_F - 1, 0.0), (FIRE_F + 1, 2.5), (FIRE_END - 2, 2.5), (FIRE_END + 1, 0.0)):
        fs.fuel_amount = v
        fs.density = v * 0.4
        src.keyframe_insert('modifiers["Fluid"].flow_settings.fuel_amount', frame=f)
        src.keyframe_insert('modifiers["Fluid"].flow_settings.density', frame=f)
    fire_wind(sc, tip, direction)
    return dom


def fire_wind(sc, tip, direction):
    """A small inflow alone stalls and burns as a ball at the mouth; wind along the breath carries it out as a stream."""
    bpy.ops.object.effector_add(type="WIND", location=tip)
    wind = bpy.context.active_object
    wind.name = "FireWind"
    wind.rotation_mode = "QUATERNION"
    wind.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(direction)
    wind.field.flow, wind.field.noise, wind.field.seed = 0.0, 2.5, 7   # noise: licks and curls, not a smooth tube
    for f, v in ((FIRE_F - 1, 0.0), (FIRE_F + 1, FIRE_WIND), (FIRE_END + 2, FIRE_WIND), (FIRE_END + 8, 0.0)):
        wind.field.strength = v
        wind.keyframe_insert("field.strength", frame=f)


def fire_material():
    m = bpy.data.materials.new("DragonFire")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out = N("ShaderNodeOutputMaterial")
    vol = N("ShaderNodeVolumePrincipled")
    vol.inputs["Color"].default_value = (0.12, 0.1, 0.09, 1.0)
    dens = N("ShaderNodeAttribute")
    dens.attribute_name = "density"
    dmul = N("ShaderNodeMath")
    dmul.operation, dmul.inputs[1].default_value = "MULTIPLY", 0.9
    L(dens.outputs["Fac"], dmul.inputs[0])
    L(dmul.outputs[0], vol.inputs["Density"])
    flame = N("ShaderNodeAttribute")
    flame.attribute_name = "flame"
    ramp = N("ShaderNodeValToRGB")
    els = ramp.color_ramp.elements
    els[0].position, els[0].color = 0.0, (0.0, 0.0, 0.0, 1.0)
    els[1].position, els[1].color = 1.0, (1.0, 0.92, 0.7, 1.0)
    for pos, col in ((0.12, (0.85, 0.07, 0.005, 1.0)), (0.45, (1.0, 0.28, 0.01, 1.0)), (0.8, (1.0, 0.62, 0.08, 1.0))):
        e = els.new(pos)
        e.color = col
    pw = N("ShaderNodeMath")     # contrast: hot core, licking edges
    pw.operation, pw.inputs[1].default_value = "POWER", 2.0
    L(flame.outputs["Fac"], pw.inputs[0])
    L(pw.outputs[0], ramp.inputs["Fac"])
    L(ramp.outputs["Color"], vol.inputs["Emission Color"])
    fmul = N("ShaderNodeMath")
    fmul.operation, fmul.inputs[1].default_value = "MULTIPLY", 30.0
    L(pw.outputs[0], fmul.inputs[0])
    L(fmul.outputs[0], vol.inputs["Emission Strength"])
    L(vol.outputs[0], out.inputs["Volume"])
    return m


def fire_light(sc, arm):
    ld = bpy.data.lights.new("FireLight", "POINT")
    ld.color, ld.shadow_soft_size = (1.0, 0.5, 0.12), 0.6
    lo = bpy.data.objects.new("FireLight", ld)
    sc.collection.objects.link(lo)
    c = lo.constraints.new("COPY_LOCATION")
    c.target, c.subtarget, c.head_tail = arm, "DEF-Teeth_Top_013", 1.0
    for f in range(FIRE_F - 2, FIRE_END + 6):
        on = env(f, FIRE_F - 1, FIRE_F + 2) * (1 - env(f, FIRE_END - 2, FIRE_END + 4))
        ld.energy = on * (2600 + 900 * math.sin(f * 2.3) * math.sin(f * 0.7))
        ld.keyframe_insert("energy", frame=f)


def embers(sc, arm, direction):
    mat = fx.fade_material("Ember", (1.0, 0.42, 0.06), 14.0, 1.0, 1.0)
    em = fx.particle_burst(sc, "Ember", fx.point_mesh("EmberSrc", 0.12), mat, 700, (FIRE_F, FIRE_END), 34, 0.018,
                           0.0, rand=2.0, align=tuple(direction * 9.0 + Vector((0, 0, 0.6))), damping=0.05,
                           gravity=-0.08, emit_from="VOLUME")
    c = em.constraints.new("COPY_LOCATION")
    c.target, c.subtarget, c.head_tail = arm, "DEF-Teeth_Top_013", 1.0


# ------------------------------------------------------------------ build
def build(sc, opts):
    root, arm, meshes = load_dragon()
    base = cycle_fly(arm, NECK + (JAW,))
    animate(root, arm, base)
    sh.setup_cycles(sc, (1, TOTAL), samples=opts["samples"])
    gc.setup_world(sc, strength=0.7)
    cam = gc.setup_camera(sc, elev_deg=6)
    gc.setup_lights(sc, follow=root, scale=1.6)
    sh.setup_comp(sc, fog_threshold=1.3, fog_size=8, streak_threshold=8.0)
    sc.frame_set(FIRE_F + 6)
    tip, direction = mouth(arm)
    print("FIRE dir", tuple(round(v, 2) for v in direction), "tip", tuple(round(v, 2) for v in tip))
    fire_light(sc, arm)
    embers(sc, arm, direction)
    sh.camera_shake(cam, FIRE_F, 40, amp=0.035, rot_deg=0.3, seed=11)
    if opts["fire"]:
        fire(sc, arm, tip, direction, sh.src_dir(ID, "fire_cache"))
    sh.screen_extent(sc, cam, meshes, (1, ARRIVE_F, FIRE_F + 20, TOTAL))
    return sc


def build_icon(sc, opts):
    """Seamless 2 s hover: one Fly cycle squeezed into 30 frames, 3/4 view."""
    root, arm, meshes = load_dragon()
    act = arm.animation_data.action
    n, span = 30, act.frame_range[1] - act.frame_range[0]
    for fc in act.fcurves:
        for kp in fc.keyframe_points:
            for attr in ("co", "handle_left", "handle_right"):
                v = getattr(kp, attr)
                v.x = 1 + (v.x - act.frame_range[0]) * n / span
        fc.modifiers.new("CYCLES")
    root.rotation_euler = (0, 0, YAW)
    sh.setup_cycles(sc, (1, n), samples=opts["samples"], res=(384, 384))
    sc.render.fps = sh.ICON_FPS
    gc.setup_world(sc, strength=0.7)
    cam = gc.setup_camera(sc, elev_deg=6)
    gc.setup_lights(sc, follow=root, scale=1.6)
    sh.setup_comp(sc, fog_threshold=1.3, fog_size=6, streak_threshold=8.0)
    lo, hi = gc.world_bbox(meshes)
    c = (lo + hi) / 2
    half = max(hi.x - lo.x, hi.z - lo.z) / 2 * 1.25
    e = R(6)
    cam.location = (c.x, c.y - gc.CAM_DIST * math.cos(e), c.z + gc.CAM_DIST * math.sin(e))
    cam.data.lens = gc.CAM_DIST * 18.0 / half
    return sc


def main():
    opts = parse()
    sc = gc.reset_scene("Dragon")
    sc.render.fps = sh.FPS
    if opts["mode"] == "show":
        build(sc, opts)
        if opts["fire"]:
            gc.save(os.path.join(sh.src_dir(ID), "dragon_test.blend" if opts["test"] else "dragon_show.blend"))
            dom = bpy.data.objects["FireDomain"]
            with bpy.context.temp_override(scene=sc, object=dom, active_object=dom):
                bpy.ops.fluid.bake_all()
            print("FIRE baked")
        sh.render(sc, ID, "show", opts["test"])
    else:
        build_icon(sc, opts)
        if not opts["test"]:
            gc.save(os.path.join(sh.src_dir(ID), "dragon_icon.blend"))
        sh.render(sc, ID, "icon", opts["test"])


if __name__ == "__main__":
    main()
