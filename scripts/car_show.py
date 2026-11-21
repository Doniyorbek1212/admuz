"""UZARO sports_car show (tier 2): drifts in sideways, stops, revs twice, burnout, launches out.

blender -b --factory-startup -P car_show.py -- <show|icon> [f=20,60] [s=16] [nosmoke]
Model: "Generic Sport Coupe Car" by MMC Works (CC BY), an unbranded design. Wheels are re-rigged
(steer + spin pivots), body sits on a sprung pivot; Mantaflow tyre smoke; exhaust flame pops.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402

ID = "sports_car"
R = math.radians
SMOKE_FADE_F = 116          # smoke density 10 -> 0 by TOTAL
TOTAL = 132                        # 5.5 s @ 24 fps
CAR_LEN = 5.5
GROUND_Z = -2.2
STOP_F, BLIPS, BURN_F, LAUNCH_F = 50, (58, 70), 82, 100
V0 = 0.36                          # entry speed, world units / frame
STOP_XY = Vector((0.35, 0.6))
ENTRY_DIR = Vector((1.0, -0.18)).normalized()
LAUNCH_ACC = 0.024
DRIFT_KEYS = ((1, -12), (14, -35), (30, -62), (44, -40), (50, -45), (56, -42), (100, -42), (116, -34), (132, -30))
WHEEL_PARTS = ("wheel-full", "tire-low", "brake-disc")
SMOKE_KEYS = ((1, 0.0), (8, 1.0), (40, 1.0), (50, 0.0), (BURN_F, 0.0), (BURN_F + 3, 1.0), (LAUNCH_F + 8, 1.0),
              (LAUNCH_F + 14, 0.0))


def smooth(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


def parse():
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    opts = {"mode": a[0] if a else "show", "test": None, "samples": 64, "smoke": True}
    for t in a[1:]:
        if t.startswith("f="):
            opts["test"] = [int(x) for x in t[2:].split(",")]
        elif t.startswith("s="):
            opts["samples"] = int(t[2:])
        elif t == "nosmoke":
            opts["smoke"] = False
    if opts["mode"] not in ("show", "icon"):
        raise SystemExit(f"mode must be show|icon, got {opts['mode']}")
    return opts


def interp(keys, f):
    """Smooth piecewise interpolation through (frame, value) keys."""
    if f <= keys[0][0]:
        return keys[0][1]
    for (f0, v0), (f1, v1) in zip(keys, keys[1:]):
        if f <= f1:
            return v0 + (v1 - v0) * smooth((f - f0) / (f1 - f0))
    return keys[-1][1]


# ------------------------------------------------------------------ rig
def reparent(ob, parent):
    mw = ob.matrix_world.copy()
    ob.parent = parent
    ob.matrix_world = mw


def empty(name, loc, parent=None):
    e = bpy.data.objects.new(name, None)
    bpy.context.scene.collection.objects.link(e)
    e.location = loc
    if parent:
        e.parent = parent
    return e


def load_car():
    objs = gc.import_glb(os.path.join(gc.MODELS, "generic_coupe.glb"), hide=("Icosphere",))
    objs = [o for o in objs if "Icosphere" not in o.name]
    root, model = gc.normalize(objs, CAR_LEN, name="Car")
    bpy.context.view_layer.update()
    meshes = [o for o in objs if o.type == "MESH"]
    wheels = rig_wheels(root, meshes)
    lo, _ = gc.world_bbox([o for o in meshes if o.name.startswith("tire-low")])
    axle_z = wheels[0]["center"].z
    body = empty("CarBody", (0.0, 0.0, axle_z), root)       # sprung mass pivots at axle height
    reparent(model, body)
    return root, body, model, meshes, wheels, lo.z


def rig_wheels(root, meshes):
    """Steer + spin pivot per wheel, centred on its rim; calipers steer but do not spin."""
    rims = [o for o in meshes if o.name.startswith("wheel-full")]
    wheels = []
    for rim in rims:
        lo, hi = gc.world_bbox([rim])
        c = (lo + hi) / 2
        front = c.y < 0                                      # the model's nose points to -Y
        steer = empty(f"Steer_{rim.name[:14]}", c, root)
        spin = empty(f"Spin_{rim.name[:14]}", (0, 0, 0), steer)
        wheels.append({"center": c, "front": front, "steer": steer, "spin": spin, "radius": (hi.z - lo.z) / 2})
    for o in meshes:
        if not o.name.startswith(WHEEL_PARTS + ("brake-caliper",)):
            continue
        lo, hi = gc.world_bbox([o])
        c = (lo + hi) / 2
        w = min(wheels, key=lambda w: (w["center"] - c).length)
        reparent(o, w["steer"] if o.name.startswith("brake-caliper") else w["spin"])
    tires = [o for o in meshes if o.name.startswith("tire-low")]
    r = max(gc.world_bbox([t])[1].z - gc.world_bbox([t])[0].z for t in tires) / 2
    for w in wheels:
        w["radius"] = r
    return wheels


# ------------------------------------------------------------------ motion
class Drive:
    """World path, yaw, suspension and wheel angles for every frame."""

    def __init__(self, wheels):
        self.wheels = wheels
        self.pos, self.yaw = {}, {}
        self._path()
        self.spin = {id(w): 0.0 for w in wheels}

    def _path(self):
        d_in = sum(self.speed_in(f) for f in range(1, STOP_F))
        p = Vector(STOP_XY) - ENTRY_DIR * d_in
        for f in range(1, TOTAL + 2):
            self.yaw[f] = R(interp(DRIFT_KEYS, f))
            self.pos[f] = p.copy()
            if f < STOP_F:
                p += ENTRY_DIR * self.speed_in(f)
            elif f >= LAUNCH_F:
                t = f - LAUNCH_F + 1
                nose = Vector((math.cos(self.yaw[f]), math.sin(self.yaw[f])))
                p += nose * LAUNCH_ACC * t
            elif f >= BURN_F:
                p += Vector((math.cos(self.yaw[f]), math.sin(self.yaw[f]))) * 0.004

    @staticmethod
    def speed_in(f):
        return V0 * (1.0 - smooth((f - 1) / (STOP_F - 1)) ** 1.3)

    def velocity(self, f):
        return self.pos[f + 1] - self.pos[f]

    def body_angles(self, f):
        """(pitch nose-down +, roll) in radians on the sprung body."""
        decel = 1.0 if 20 <= f < STOP_F else 0.0
        pitch = R(2.2) * decel * smooth((f - 20) / 10)
        t = f - STOP_F
        if t >= 0:
            pitch += R(2.2) * math.exp(-t / 5.0) * math.cos(2 * math.pi * t / 13)
        roll = R(3.2) * smooth((f - 8) / 10) * (1 - smooth((f - 38) / 12))
        for b in BLIPS:
            u = f - b
            if u >= 0:
                roll += R(1.4) * math.exp(-u / 4.0) * math.sin(2 * math.pi * u / 9)
        if f >= BURN_F:
            pitch -= R(1.6) * smooth((f - BURN_F) / 4)                       # squat on the rear
            u = f - LAUNCH_F
            if u >= 0:
                pitch -= R(2.4) * math.exp(-u / 8.0) * smooth(u / 3)
            roll += R(0.6) * math.sin(f * 1.7) * (1 - smooth((f - LAUNCH_F - 10) / 10))
        return pitch, roll

    def wheel_pose(self, f):
        v = self.velocity(f)
        yaw = self.yaw[f]
        nose = Vector((math.cos(yaw), math.sin(yaw)))
        fwd = v.dot(nose)
        slip = math.atan2(v.y, v.x) - yaw if v.length > 1e-4 else 0.0
        steer = max(-R(32), min(R(32), slip)) if f < STOP_F else R(14) * (1 - smooth((f - LAUNCH_F) / 10))
        burn = 0.95 if BURN_F + 2 <= f < LAUNCH_F + 10 else 0.0
        drift = 0.6 * v.length if f < STOP_F - 6 else 0.0
        out = []
        for w in self.wheels:
            d = fwd / w["radius"]
            if not w["front"]:
                d += burn + drift / w["radius"]
            self.spin[id(w)] += d
            out.append((w, steer if w["front"] else 0.0, self.spin[id(w)]))
        return out


def animate(root, body, drive, ground_rel):
    for f in range(1, TOTAL + 1):
        p = drive.pos[f]
        root.location = (p.x, p.y, GROUND_Z - ground_rel)
        root.rotation_euler = (0.0, 0.0, R(90) + drive.yaw[f])            # model nose -Y -> +X at yaw 0
        root.keyframe_insert("location", frame=f)
        root.keyframe_insert("rotation_euler", frame=f)
        pitch, roll = drive.body_angles(f)
        body.rotation_euler = (pitch, roll, 0.0)
        body.keyframe_insert("rotation_euler", frame=f)
        for w, steer, spin in drive.wheel_pose(f):
            w["steer"].rotation_euler = (0.0, 0.0, steer)
            w["spin"].rotation_euler = (spin, 0.0, 0.0)
            w["steer"].keyframe_insert("rotation_euler", frame=f)
            w["spin"].keyframe_insert("rotation_euler", frame=f)


# ------------------------------------------------------------------ look
def materials(meshes):
    lamp = fx_emission("HeadLamp", (1.0, 0.93, 0.82), 40.0)
    tail = fx_emission("TailLamp", (1.0, 0.05, 0.02), 18.0)
    for o in meshes:
        n = o.name
        if n.startswith(("headlights.l_Glass", "headlights.r_Glass", "headlight-drl")):
            o.data.materials.clear()
            o.data.materials.append(lamp)
        elif n.startswith("taillight-led"):
            o.data.materials.clear()
            o.data.materials.append(tail)
    for m in bpy.data.materials:
        if m.name == "car-body" and m.node_tree:
            b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
            for k, v in (("Metallic", 0.6), ("Roughness", 0.22)):
                for l in list(b.inputs[k].links):
                    m.node_tree.links.remove(l)
                b.inputs[k].default_value = v
            b.inputs["Coat Weight"].default_value = 1.0
            b.inputs["Coat Roughness"].default_value = 0.03


def fx_emission(name, rgb, strength):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*rgb, 1.0)
    b.inputs["Emission Color"].default_value = (*rgb, 1.0)
    b.inputs["Emission Strength"].default_value = strength
    return m


def softbox(sc, root):
    """Big overhead area light: long highlights on roof and hood instead of a black reflection."""
    ld = bpy.data.lights.new("Softbox", "AREA")
    ld.shape, ld.size, ld.size_y, ld.energy = "RECTANGLE", 7.0, 3.0, 220.0
    ld.color = (1.0, 0.95, 0.88)
    lo = bpy.data.objects.new("Softbox", ld)
    sc.collection.objects.link(lo)
    c = lo.constraints.new("COPY_LOCATION")
    c.target = root
    c.use_offset = False
    lo.location = (0, 0, 0)
    lo.delta_location = (0.0, 0.0, 4.5)


def exhaust_pops(sc, root, meshes):
    pipe = next(o for o in meshes if o.name.startswith("exhaust-pipe"))
    lo, hi = gc.world_bbox([pipe])
    tip = Vector((0.0, hi.y - 0.05, lo.z + 0.12)) - root.location   # root not yet moved: world == local
    flame = fx.fade_material("ExhaustFlame", (1.0, 0.45, 0.08), 25.0, 1.0, 1.2)
    for i, b in enumerate(BLIPS):
        for side in (-1, 1):
            em = fx.particle_burst(sc, f"Pop{i}{side}", fx.point_mesh(f"PopSrc{i}{side}", 0.04), flame, 90,
                                   (b, b + 2), 6, 0.035, 0.0, rand=0.4, align=(0.0, 3.5, 0.2),
                                   emit_from="VOLUME")
            em.parent = root
            em.location = (0.5 * side, tip.y, tip.z)


def smoke(sc, root, wheels, cache_dir):
    """Mantaflow gas domain over the whole path; inflow spheres at the rear tyre contact patches."""
    bpy.ops.mesh.primitive_cube_add(size=2.0)
    dom = bpy.context.active_object
    dom.name = "SmokeDomain"
    dom.location = (-0.5, -0.5, GROUND_Z + 1.8)
    dom.scale = (9.5, 6.0, 1.9)
    mod = dom.modifiers.new("Fluid", "FLUID")
    mod.fluid_type = "DOMAIN"
    ds = mod.domain_settings
    ds.domain_type = "GAS"
    ds.resolution_max = 128
    ds.use_adaptive_domain = True
    ds.use_dissolve_smoke, ds.dissolve_speed = True, 30
    ds.vorticity = 0.25
    ds.cache_directory = cache_dir
    ds.cache_type = "ALL"
    ds.cache_frame_start, ds.cache_frame_end = 1, TOTAL
    mat = bpy.data.materials.new("TyreSmoke")
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    vol = nt.nodes.new("ShaderNodeVolumePrincipled")
    vol.inputs["Color"].default_value = (0.82, 0.8, 0.78, 1.0)
    vol.inputs["Density"].default_value = 10.0
    fade_smoke(vol)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(vol.outputs[0], out.inputs["Volume"])
    dom.data.materials.append(mat)
    for w in wheels:
        if w["front"]:
            continue
        c = w["center"]
        src = bpy.data.objects.new(f"SmokeSrc_{w['spin'].name}", gc.ico_mesh("SmokeSrc", 0.35, 2))
        sc.collection.objects.link(src)
        src.parent = root
        src.location = (c.x * 1.05, c.y + 0.25, c.z - w["radius"] + 0.12)
        src.hide_render = True
        fm = src.modifiers.new("Fluid", "FLUID")
        fm.fluid_type = "FLOW"
        fs = fm.flow_settings
        fs.flow_type, fs.flow_behavior, fs.flow_source = "SMOKE", "INFLOW", "MESH"
        fs.surface_distance = 0.5
        fs.temperature = 1.0
        fs.use_initial_velocity, fs.velocity_factor = True, 0.3
        for f, v in SMOKE_KEYS:
            fs.density = v
            src.keyframe_insert('modifiers["Fluid"].flow_settings.density', frame=f)
    return dom


def fade_smoke(vol):
    """Thin the lingering cloud to nothing so the last frame is empty (contract: last frame empty / subject exits)."""
    dens = vol.inputs["Density"]
    for f, v in ((SMOKE_FADE_F, 10.0), (TOTAL, 0.0)):
        dens.default_value = v
        dens.keyframe_insert("default_value", frame=f)


def bake_smoke(sc, dom):
    with bpy.context.temp_override(scene=sc, object=dom, active_object=dom):
        bpy.ops.fluid.bake_all()
    print("SMOKE baked")


# ------------------------------------------------------------------ build
def build(sc, opts, icon=False):
    root, body, model, meshes, wheels, tire_lo = load_car()
    ground_rel = tire_lo - root.location.z
    drive = Drive(wheels)
    materials(meshes)
    sh.setup_cycles(sc, (1, TOTAL), samples=opts["samples"])
    gc.setup_world(sc, strength=0.9)
    cam = gc.setup_camera(sc, elev_deg=9)
    gc.setup_lights(sc, follow=root, scale=1.4)
    sh.setup_comp(sc, fog_threshold=1.8, fog_size=7, streak_threshold=6.0)
    if icon:
        return sc, root, body, drive, ground_rel, cam, meshes
    exhaust_pops(sc, root, meshes)
    animate(root, body, drive, ground_rel)
    sh.shadow_catcher(sc, GROUND_Z, 60)
    softbox(sc, root)
    sh.camera_shake(cam, BLIPS[0], 8, amp=0.03, rot_deg=0.25, seed=3)
    sh.camera_shake(cam, LAUNCH_F, 14, amp=0.06, rot_deg=0.5, seed=5)
    if opts["smoke"]:
        smoke(sc, root, wheels, sh.src_dir(ID, "smoke_cache"))
    sh.screen_extent(sc, cam, meshes, (1, STOP_F, BURN_F, TOTAL))
    return sc


def build_icon(sc, opts):
    """2 s seamless loop at 15 fps: parked 3/4 front, wheels turning, headlights pulsing."""
    sc_, root, body, drive, ground_rel, cam, meshes = build(sc, opts, icon=True)
    n = 30
    sc.frame_start, sc.frame_end = 1, n
    sc.render.fps = sh.ICON_FPS
    sc.render.resolution_x = sc.render.resolution_y = 384
    root.location = (0.0, 0.0, -ground_rel)
    root.rotation_euler = (0.0, 0.0, R(90) + R(-40))
    for i in range(1, n + 1):
        ph = 2 * math.pi * (i - 1) / n
        body.rotation_euler = (R(0.8) * math.sin(ph), R(0.8) * math.sin(2 * ph), 0.0)
        body.keyframe_insert("rotation_euler", frame=i)
        for w in drive.wheels:
            w["spin"].rotation_euler = (ph, 0.0, 0.0)
            w["spin"].keyframe_insert("rotation_euler", frame=i)
    for w in drive.wheels:
        for fc in w["spin"].animation_data.action.fcurves:
            for kp in fc.keyframe_points:
                kp.interpolation = "LINEAR"
            fc.modifiers.new("CYCLES")
    sh.shadow_catcher(sc, 0.0, 30)
    bpy.context.view_layer.update()
    lo, hi = gc.world_bbox(meshes)
    c = (lo + hi) / 2
    half = max(hi.x - lo.x, hi.z - lo.z) / 2 * 1.15
    e = R(9)
    cam.location = (c.x, c.y - gc.CAM_DIST * math.cos(e), c.z + gc.CAM_DIST * math.sin(e))
    cam.data.lens = gc.CAM_DIST * 18.0 / half
    return sc


def main():
    opts = parse()
    sc = gc.reset_scene("Car")
    sc.render.fps = sh.FPS
    if opts["mode"] == "show":
        build(sc, opts)
        if opts["smoke"]:
            gc.save(os.path.join(sh.src_dir(ID), "sports_car_show.blend" if not opts["test"] else "car_test.blend"))
            bake_smoke(sc, bpy.data.objects["SmokeDomain"])
        sh.render(sc, ID, "show", opts["test"])
    else:
        build_icon(sc, opts)
        if not opts["test"]:
            gc.save(os.path.join(sh.src_dir(ID), "sports_car_icon.blend"))
        sh.render(sc, ID, "icon", opts["test"])


if __name__ == "__main__":
    main()
