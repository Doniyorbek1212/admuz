"""UZARO v2 show: helicopter (tier 2). blender -b --factory-startup -P heli_show.py -- <show|icon> [f=..] [s=N] [nodust]

Story (132 f = 5.5 s @ 24): banks in from the left nose-down, flares nose-up and settles into a low hover;
the rotor downwash kicks a ring of Mantaflow dust off the ground, tail beacon strobing, landing light on.
Then it dips the nose and climbs out to the top right. First/last frames: subject entering/gone.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402
import heli  # noqa: E402  (v1: camera tilt)
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402

R = math.radians
ID = "helicopter"
TOTAL = 132
SIZE = 6.0
GROUND_Z = -2.6
HOVER_Z = -0.35                    # skids ~1.3 above the ground: close enough for downwash dust
T = heli.TILT
MAIN_SPEED, TAIL_SPEED = 0.74, 1.4  # rad/frame (<45 deg/frame for 4 blades: no wagon-wheel)
YAW = R(65)                        # file has the nose at -Y; this turns it screen-right and 25 deg toward the camera
HUB_M, HUB_T = (-4.62, 0.0, 1.14), (-5.35, 8.8, 1.31)  # rotor hubs, file coordinates (probed)
ROTOR_R_M = 5.66
DUST_KEYS = ((1, 0.0), (36, 0.0), (48, 1.0), (92, 1.0), (104, 0.0))
DUST_FADE_F = 112                  # dust density 6 -> 0 by TOTAL (last frame empty)
BEACON_M = (-4.6, 8.3, 2.5)        # tail-fin top, file coordinates (probed)
NOSE_LIGHT_M = (-4.6, -4.3, -1.75)

LOC_KEYS = [(1, (-10.5, 0, 3.2)), (20, (-4.5, 0, 1.0)), (40, (-0.3, 0, -0.1)), (48, (0, 0, HOVER_Z)),
            (62, (0.06, 0, HOVER_Z + 0.1)), (76, (-0.05, 0, HOVER_Z - 0.06)), (90, (0.04, 0, HOVER_Z + 0.05)),
            (98, (0.1, 0, HOVER_Z + 0.05)), (112, (2.2, 0, 1.6)), (TOTAL, (10.5, 0, 8.5))]
# (tilt-to-camera + roll, pitch: + = nose down, yaw wobble)
ROT_KEYS = [(1, (T, R(14), 0)), (24, (T, R(10), 0)), (38, (T - R(2), R(-12), R(3))), (50, (T, R(2), 0)),
            (70, (T + R(1.5), 0, R(-2))), (94, (T, R(-3), 0)), (104, (T + R(3), R(16), R(4))),
            (TOTAL, (T + R(6), R(24), R(8)))]


def parse():
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    opts = {"mode": a[0] if a else "show", "test": None, "samples": 64, "dust": True}
    for t in a[1:]:
        if t.startswith("f="):
            opts["test"] = [int(x) for x in t[2:].split(",")]
        elif t.startswith("s="):
            opts["samples"] = int(t[2:])
        elif t == "nodust":
            opts["dust"] = False
    if opts["mode"] not in ("show", "icon"):
        raise SystemExit(f"mode must be show|icon, got {opts['mode']}")
    return opts


def spin_pivot(sc, hub, children):
    """Empty at the hub the rotor parts hang from; its rotation is the only rotor animation."""
    pivot = bpy.data.objects.new("Spin", None)
    sc.collection.objects.link(pivot)
    pivot.location = hub
    bpy.context.view_layer.update()
    for o in children:
        mw = o.matrix_world.copy()
        o.parent = pivot
        o.matrix_parent_inverse = pivot.matrix_world.inverted()
        o.matrix_world = mw
    return pivot


def load(sc):
    objs = gc.import_glb(os.path.join(gc.MODELS, "helicopter.glb"), hide=("Icosphere",))
    for o in objs:
        o.animation_data_clear()
    bpy.context.view_layer.update()
    main = spin_pivot(sc, HUB_M, [o for o in objs if o.name.startswith("Empty_84")])
    tail = spin_pivot(sc, HUB_T, [o for o in objs if o.name.startswith("Empty.003_41")])
    objs += [main, tail]
    root, model = gc.normalize(objs, SIZE, rot=(0, 0, YAW), name="Heli")
    glass = bpy.data.materials.get("glass")
    if glass and glass.use_nodes:
        b = next(n for n in glass.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
        b.inputs["Transmission Weight"].default_value, b.inputs["Roughness"].default_value = 1.0, 0.03
    for name in ("color_helicopter", "color_helicopter.001", "color_helicopter_tail", "color_helicopter_door"):
        m = bpy.data.materials.get(name)
        if m and m.use_nodes:
            b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
            b.inputs["Coat Weight"].default_value, b.inputs["Coat Roughness"].default_value = 1.0, 0.04
    bpy.context.view_layer.update()
    meshes = [o for o in objs if o.type == "MESH" and not o.hide_render]
    return root, model, main, tail, meshes


def spin(main, tail, main_speed, tail_speed, end):
    for ob, axis, speed in ((main, 2, main_speed), (tail, 0, tail_speed)):
        for f in (0, end):
            rot = [0.0, 0.0, 0.0]
            rot[axis] = f * speed
            ob.rotation_euler = rot
            ob.keyframe_insert("rotation_euler", frame=f)
        for fc in ob.animation_data.action.fcurves:
            for kp in fc.keyframe_points:
                kp.interpolation = "LINEAR"


def attach(sc, root, name, data, world):
    """Object at a rest-pose world point, parented to the still unanimated root."""
    ob = bpy.data.objects.new(name, data)
    sc.collection.objects.link(ob)
    ob.location = world
    ob.parent = root
    ob.matrix_parent_inverse = root.matrix_world.inverted()
    return ob


def lights(sc, root, model, total, blink_every=24):
    """Red tail beacon (2-frame strobe) + nose landing light (glint + real spot)."""
    beacon = attach(sc, root, "Beacon", gc.ico_mesh("Beacon", 0.07, 2), model.matrix_world @ Vector(BEACON_M))
    bmat = gc.emission_material("BeaconRed", (1.0, 0.08, 0.04), 0.0)
    beacon.data.materials.append(bmat)
    em = bmat.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"]
    for f in range(1, total + 1):
        em.default_value = 60.0 if (f % blink_every) in (1, 2) else 0.4
        em.keyframe_insert("default_value", frame=f)
    for fc in bmat.node_tree.animation_data.action.fcurves:
        for kp in fc.keyframe_points:
            kp.interpolation = "CONSTANT"
    nose = model.matrix_world @ Vector(NOSE_LIGHT_M)
    lamp = attach(sc, root, "NoseLamp", gc.ico_mesh("NoseLamp", 0.06, 2), nose)
    lamp.data.materials.append(gc.emission_material("NoseLampMat", (1.0, 0.93, 0.8), 45.0))
    sd = bpy.data.lights.new("LandingSpot", "SPOT")
    sd.energy, sd.spot_size, sd.spot_blend, sd.color = 900.0, R(40), 0.6, (1.0, 0.93, 0.8)
    spot = attach(sc, root, "LandingSpot", sd, nose)
    spot.rotation_euler = (R(25), 0, 0)  # mostly straight down: lights the dust and the ground shadow area


def rotor_disc(sc, root, model):
    """Faint blur disc where the blades sweep (blades alone strobe at 24 fps); denser toward the tips."""
    radius = ROTOR_R_M * model.matrix_world.to_scale()[0]
    bpy.ops.mesh.primitive_circle_add(vertices=96, radius=radius, fill_type="NGON")
    disc = bpy.context.active_object
    disc.name = "RotorDisc"
    disc.location = model.matrix_world @ Vector(HUB_M)
    disc.parent = root
    disc.matrix_parent_inverse = root.matrix_world.inverted()
    disc.visible_shadow = False
    m = bpy.data.materials.new("RotorBlur")
    m.use_nodes = True
    if hasattr(m, "surface_render_method"):
        m.surface_render_method = "BLENDED"
    nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (0.02, 0.02, 0.02, 1.0)
    b.inputs["Roughness"].default_value = 0.6
    tc = nt.nodes.new("ShaderNodeTexCoord")
    grad = nt.nodes.new("ShaderNodeTexGradient")
    grad.gradient_type = "SPHERICAL"          # 1 at the hub, 0 at the rim (object coords, radius 1 after scale)
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    els = ramp.color_ramp.elements
    els[0].position, els[0].color = 0.0, (0.0, 0.0, 0.0, 1.0)
    els[1].position, els[1].color = 0.1, (0.07, 0.07, 0.07, 1.0)
    els.new(0.9).color = (0.035, 0.035, 0.035, 1.0)
    nt.links.new(tc.outputs["Object"], grad.inputs["Vector"])
    nt.links.new(grad.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], b.inputs["Alpha"])
    disc.data.materials.append(m)
    # gradient wants coords in -1..1: normalise the circle mesh to unit radius and scale the object instead
    for v in disc.data.vertices:
        v.co /= radius
    disc.scale = (radius,) * 3
    return disc


def animate(root):
    gc.keyframes(root, "location", LOC_KEYS)
    gc.keyframes(root, "rotation_euler", ROT_KEYS)


def dust(sc, root, cache_dir):
    """Mantaflow downwash: ground ring under the heli, outward-normal inflow, density keyed by altitude."""
    bpy.ops.mesh.primitive_cube_add(size=2.0)
    dom = bpy.context.active_object
    dom.name = "DustDomain"
    dom.location = (0.0, 0.0, GROUND_Z + 1.1)
    dom.scale = (6.0, 4.4, 1.1)
    dom.modifiers.new("Fluid", "FLUID").fluid_type = "DOMAIN"
    ds = dom.modifiers["Fluid"].domain_settings
    ds.domain_type = "GAS"
    ds.resolution_max = 128
    ds.use_adaptive_domain = True
    ds.use_dissolve_smoke, ds.dissolve_speed = True, 26
    ds.vorticity = 0.5
    ds.timesteps_max, ds.cfl_condition = 8, 2.0     # fast radial inflow: more substeps, no dt blow-up
    ds.cache_directory = cache_dir
    ds.cache_type = "ALL"
    ds.cache_frame_start, ds.cache_frame_end = 1, TOTAL
    mat = bpy.data.materials.new("Dust")
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    vol = nt.nodes.new("ShaderNodeVolumePrincipled")
    vol.inputs["Color"].default_value = (0.78, 0.68, 0.52, 1.0)
    dens = vol.inputs["Density"]
    for f, v in ((DUST_FADE_F, 6.0), (TOTAL, 0.0)):
        dens.default_value = v
        dens.keyframe_insert("default_value", frame=f)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(vol.outputs[0], out.inputs["Volume"])
    dom.data.materials.append(mat)
    dom.cycles.use_motion_blur = False   # velocity blur dilates the volume mesh by the flow speed: minutes per frame

    ring = bpy.data.objects.new("DustRing", fx.ring_mesh("DustRing", 0.9, 0.12, 64))
    sc.collection.objects.link(ring)
    ring.hide_render = True
    fs_mod = ring.modifiers.new("Fluid", "FLUID")
    fs_mod.fluid_type = "FLOW"
    fs = fs_mod.flow_settings
    fs.flow_type, fs.flow_behavior, fs.flow_source = "SMOKE", "INFLOW", "MESH"
    fs.surface_distance = 0.35
    fs.use_initial_velocity, fs.velocity_normal = True, 7.0
    fs.temperature = 0.0                   # no buoyancy: dust rolls out along the ground
    for f, v in DUST_KEYS:
        fs.density = v
        ring.keyframe_insert('modifiers["Fluid"].flow_settings.density', frame=f)
    fcx, fcy = (root.animation_data.action.fcurves.find("location", index=i) for i in (0, 1))
    for f in range(1, TOTAL + 1):  # follows the heli over the ground (x/y only); no frame_set: it trips Mantaflow
        ring.location = (fcx.evaluate(f), fcy.evaluate(f), GROUND_Z + 0.02)
        ring.keyframe_insert("location", frame=f)
    return dom


def build(sc, opts, icon=False):
    root, model, main, tail, meshes = load(sc)
    total = 30 if icon else TOTAL
    sh.setup_cycles(sc, (1, total), samples=opts["samples"], shutter=0.6)
    gc.setup_world(sc, strength=0.9, hdri="city.exr")
    cam = gc.setup_camera(sc, elev_deg=10)
    gc.setup_lights(sc, follow=root)
    sh.setup_comp(sc, fog_threshold=1.6, fog_size=7, streak_threshold=5.0)
    lights(sc, root, model, total, blink_every=15 if icon else 24)
    rotor_disc(sc, root, model)
    if icon:
        return root, main, tail, meshes, cam
    spin(main, tail, MAIN_SPEED, TAIL_SPEED, 200)
    animate(root)
    sh.shadow_catcher(sc, GROUND_Z, 60)
    sh.camera_shake(cam, 44, 50, amp=0.015, rot_deg=0.12, seed=11)
    sh.camera_shake(cam, 100, 16, amp=0.03, rot_deg=0.2, seed=12)
    sh.screen_extent(sc, cam, meshes, (1, 48, 98, TOTAL))   # before the fluid: frame_set on it errors
    if opts["dust"]:
        dust(sc, root, sh.src_dir(ID, "dust_cache"))
    return root


def build_icon(sc, opts):
    """2 s seamless loop @ 15 fps: hovering, rotors exactly 3 (main) / 7 (tail) turns, gentle bob + yaw sway."""
    root, main, tail, meshes, cam = build(sc, opts, icon=True)
    n = 30
    sc.render.fps = sh.ICON_FPS
    sc.render.resolution_x = sc.render.resolution_y = 384
    spin(main, tail, 2 * math.pi * 3 / n, 2 * math.pi * 7 / n, n)   # frame n == frame 0: seamless
    gc.keyframes(root, "location", [(0, (0, 0, 0)), (n // 2, (0, 0, 0.12)), (n, (0, 0, 0))])
    gc.keyframes(root, "rotation_euler", [(0, (T, 0, R(-6))), (n // 2, (T, 0, R(6))), (n, (T, 0, R(-6)))])
    sh.shadow_catcher(sc, -SIZE * 0.32, 30)
    bpy.context.view_layer.update()
    lo, hi = gc.world_bbox(meshes)
    c = (lo + hi) / 2
    half = max(hi.x - lo.x, hi.z - lo.z) / 2 * 1.12
    e = R(10)
    cam.location = (c.x, c.y - gc.CAM_DIST * math.cos(e), c.z + gc.CAM_DIST * math.sin(e))
    cam.data.lens = gc.CAM_DIST * 18.0 / half
    return sc


def main():
    opts = parse()
    sc = gc.reset_scene("Heli")
    sc.render.fps = sh.FPS
    if opts["mode"] == "show":
        build(sc, opts)
        if opts["dust"]:
            gc.save(os.path.join(sh.src_dir(ID), "helicopter_show.blend" if not opts["test"] else "heli_test.blend"))
            dom = bpy.data.objects["DustDomain"]
            with bpy.context.temp_override(scene=sc, object=dom, active_object=dom):
                bpy.ops.fluid.bake_all()
            print("DUST baked")
        sh.render(sc, ID, "show", opts["test"])
    else:
        build_icon(sc, opts)
        if not opts["test"]:
            gc.save(os.path.join(sh.src_dir(ID), "helicopter_icon.blend"))
        sh.render(sc, ID, "icon", opts["test"])


if __name__ == "__main__":
    main()
