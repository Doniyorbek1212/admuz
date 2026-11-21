"""Shared setup for UZARO gift renders (Blender 4.2+, Eevee Next).

Fixed camera, 720x1280 transparent PNG (straight alpha, dither 0), AgX, motion blur,
HDRI reflections (Blender's bundled studio light, not visible), key/fill + 2 rim lights,
compositor glow whose alpha is rebuilt so it survives on a transparent background.

Frame plan: 150 frames @30 fps. Frames 1-9 and 142-150 are left empty (0.3 s each):
only ACT_START..ACT_END are rendered, the encoder pads the rest with transparent frames.
"""
import math
import os
import sys
import time

import bpy
from mathutils import Vector

FPS = 30
TOTAL = 150
PAD = 9                          # 0.3 s @ 30 fps
ACT_START, ACT_END = PAD + 1, TOTAL - PAD   # 10..141
RES_X, RES_Y = 720, 1280
CAM_DIST = 20.0
LENS = 50.0
HALF_H = CAM_DIST * 18.0 / LENS          # sensor fit AUTO -> 36 mm on the long (vertical) side
HALF_W = HALF_H * RES_X / RES_Y
SAFE_TOP = HALF_H - 2 * HALF_H * 0.08    # nothing important above this z (top 8%)
SAFE_BOTTOM = -HALF_H + 2 * HALF_H * 0.10  # ... and below this z (bottom 10%)
SAFE_CENTER_Z = (SAFE_TOP + SAFE_BOTTOM) / 2
R = math.radians


def reset_scene(name):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.name = name
    return sc


def import_glb(path, hide=()):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    objs = [o for o in bpy.data.objects if o not in before]
    for o in objs:
        if any(h in o.name for h in hide):
            o.hide_render = True
            o.hide_set(True)
    return objs


def world_bbox(objs):
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    pts = []
    for o in objs:
        if o.type == "MESH" and not o.hide_render:
            oe = o.evaluated_get(dg)
            pts += [oe.matrix_world @ Vector(c) for c in oe.bound_box]
    if not pts:
        raise RuntimeError("bbox: ko'rinadigan mesh topilmadi")
    lo = Vector(tuple(min(p[i] for p in pts) for i in range(3)))
    hi = Vector(tuple(max(p[i] for p in pts) for i in range(3)))
    return lo, hi


def normalize(objs, target_size, rot=(0.0, 0.0, 0.0), name="Gift"):
    """Root (animate this) -> Model (fixed: orientation, scale, centering) -> imported objects."""
    root = bpy.data.objects.new(f"{name}Root", None)
    model = bpy.data.objects.new(f"{name}Model", None)
    for o in (root, model):
        bpy.context.scene.collection.objects.link(o)
    model.parent = root
    model.rotation_euler = rot
    for o in objs:
        if o.parent is None:
            o.parent = model
    lo, hi = world_bbox(objs)
    size = max(hi - lo)
    s = target_size / size
    model.scale = (s, s, s)
    lo, hi = world_bbox(objs)
    model.location = -(lo + hi) / 2
    return root, model


def bbox_of(objs):
    lo, hi = world_bbox(objs)
    return lo, hi, hi - lo


def setup_render(sc, out_path, res=(RES_X, RES_Y), frames=(ACT_START, ACT_END), samples=64,
                 shutter=0.5, blur_steps=1):
    for engine in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
        try:
            sc.render.engine = engine
            break
        except TypeError:
            continue
    rd, ee = sc.render, sc.eevee
    rd.fps, rd.fps_base = FPS, 1.0
    sc.frame_start, sc.frame_end = frames
    rd.resolution_x, rd.resolution_y, rd.resolution_percentage = res[0], res[1], 100
    rd.film_transparent = True
    rd.dither_intensity = 0.0
    rd.use_motion_blur, rd.motion_blur_shutter = True, shutter
    if hasattr(ee, "motion_blur_steps"):
        ee.motion_blur_steps = blur_steps  # >1 needed for curved (rotor) smears
    sc.view_settings.view_transform = "AgX"
    try:
        sc.view_settings.look = "AgX - Medium High Contrast"
    except TypeError:
        pass
    ee.taa_render_samples = samples
    if hasattr(ee, "use_raytracing"):
        ee.use_raytracing = True
        ee.ray_tracing_method = "SCREEN"
    img = rd.image_settings
    img.file_format, img.color_mode, img.color_depth, img.compression = "PNG", "RGBA", "8", 15
    rd.filepath = out_path


def setup_world(sc, strength=1.0, rot_z=0.0, hdri="studio.exr"):
    world = bpy.data.worlds.new("GiftWorld")
    world.use_nodes = True
    nt = world.node_tree
    env = nt.nodes.new("ShaderNodeTexEnvironment")
    path = os.path.join(bpy.utils.system_resource("DATAFILES"), "studiolights", "world", hdri)
    env.image = bpy.data.images.load(path)
    tc = nt.nodes.new("ShaderNodeTexCoord")
    mp = nt.nodes.new("ShaderNodeMapping")
    mp.inputs["Rotation"].default_value = (0, 0, rot_z)
    nt.links.new(tc.outputs["Generated"], mp.inputs["Vector"])
    nt.links.new(mp.outputs["Vector"], env.inputs["Vector"])
    bg = nt.nodes["Background"]
    nt.links.new(env.outputs["Color"], bg.inputs["Color"])
    bg.inputs["Strength"].default_value = strength
    sc.world = world


def setup_camera(sc, elev_deg=0.0):
    """Static camera aimed at the origin, CAM_DIST away, raised elev_deg above the horizon."""
    cam = bpy.data.objects.new("GiftCam", bpy.data.cameras.new("GiftCam"))
    sc.collection.objects.link(cam)
    e = R(elev_deg)
    cam.location = (0.0, -CAM_DIST * math.cos(e), CAM_DIST * math.sin(e))
    cam.rotation_euler = (R(90) - e, 0.0, 0.0)
    cam.data.lens = LENS
    cam.data.sensor_fit = "AUTO"
    cam.data.sensor_width = 36.0
    cam.data.clip_start, cam.data.clip_end = 0.5, 500.0
    sc.camera = cam
    return cam


def setup_lights(sc, follow=None, scale=1.0):
    """Key + fill from the camera side, two strong rim lights behind (warm + cool)."""
    target = bpy.data.objects.new("LightTarget", None)
    sc.collection.objects.link(target)
    if follow:
        c = target.constraints.new("COPY_LOCATION")
        c.target = follow
    rigs = [
        ("Key", (1.0, 0.95, 0.88), 900, (-6, -9, 7), 4),
        ("Fill", (0.8, 0.88, 1.0), 250, (7, -8, -1), 5),
        ("RimWarm", (1.0, 0.82, 0.55), 2500, (-7, 7, 5), 3),
        ("RimCool", (0.65, 0.82, 1.0), 2500, (7, 7, -2), 3),
    ]
    for name, color, energy, loc, size in rigs:
        ld = bpy.data.lights.new(name, "AREA")
        ld.color, ld.energy, ld.size = color, energy * scale, size
        lo = bpy.data.objects.new(name, ld)
        sc.collection.objects.link(lo)
        lo.parent = target  # rig travels with the subject, so rim stays a rim at any distance
        lo.location = loc
        tr = lo.constraints.new("TRACK_TO")
        tr.target, tr.track_axis, tr.up_axis = target, "TRACK_NEGATIVE_Z", "UP_Y"
    return target


def setup_glow(sc, threshold=1.0, size=7, floor=0.02):
    """Fog glow; alpha = max(object alpha, max(R,G,B) of glow) so premultiplied colour stays <= alpha."""
    sc.use_nodes = True
    nt = sc.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    cn, lk = nt.nodes, nt.links
    rl = cn.new("CompositorNodeRLayers")
    rl.scene = sc
    glare = cn.new("CompositorNodeGlare")
    glare.glare_type, glare.quality, glare.threshold, glare.size = "FOG_GLOW", "MEDIUM", threshold, size
    sub = cn.new("CompositorNodeMixRGB")
    sub.blend_type, sub.use_clamp = "SUBTRACT", True
    sub.inputs[2].default_value = (floor, floor, floor, 0.0)
    sep = cn.new("CompositorNodeSeparateColor")
    m1, m2, m3 = (cn.new("CompositorNodeMath") for _ in range(3))
    for m in (m1, m2, m3):
        m.operation, m.use_clamp = "MAXIMUM", True
    set_a = cn.new("CompositorNodeSetAlpha")
    set_a.mode = "REPLACE_ALPHA"
    comp = cn.new("CompositorNodeComposite")
    if hasattr(comp, "use_alpha"):
        comp.use_alpha = True
    lk.new(rl.outputs["Image"], glare.inputs["Image"])
    lk.new(glare.outputs["Image"], sub.inputs[1])
    lk.new(sub.outputs[0], sep.inputs[0])
    lk.new(sep.outputs["Red"], m1.inputs[0])
    lk.new(sep.outputs["Green"], m1.inputs[1])
    lk.new(m1.outputs[0], m2.inputs[0])
    lk.new(sep.outputs["Blue"], m2.inputs[1])
    lk.new(m2.outputs[0], m3.inputs[0])
    lk.new(rl.outputs["Alpha"], m3.inputs[1])
    # colour stays unclamped (clamping it caps whites at AgX ~0.82 grey); only alpha uses the floored copy
    lk.new(glare.outputs["Image"], set_a.inputs["Image"])
    lk.new(m3.outputs[0], set_a.inputs["Alpha"])
    lk.new(set_a.outputs["Image"], comp.inputs["Image"])


def emission_material(name, rgb, strength, alpha=1.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*rgb, 1.0)
    b.inputs["Emission Color"].default_value = (*rgb, 1.0)
    b.inputs["Emission Strength"].default_value = strength
    if alpha < 1.0:
        b.inputs["Alpha"].default_value = alpha
        if hasattr(m, "surface_render_method"):
            m.surface_render_method = "BLENDED"
    return m


def pbr_material(name, rgb, metallic, roughness, clearcoat=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*rgb, 1.0)
    b.inputs["Metallic"].default_value = metallic
    b.inputs["Roughness"].default_value = roughness
    if clearcoat:
        b.inputs["Coat Weight"].default_value = clearcoat
        b.inputs["Coat Roughness"].default_value = 0.05
    return m


def ico_mesh(name, radius=1.0, subdiv=2):
    import bmesh
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=radius)
    bm.to_mesh(me)
    bm.free()
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    return me


def sparks(sc, parent, name, count, frames, lifetime, size, color, strength=12.0, radius=1.0,
           speed=0.5, random_speed=1.0, gravity=0.0, location=(0, 0, 0)):
    """Glittering emissive particle sparks emitted from an invisible sphere."""
    inst = bpy.data.objects.new(f"{name}Spark", ico_mesh(f"{name}Spark", 1.0, 1))
    inst.data.materials.append(emission_material(f"{name}SparkMat", color, strength))
    sc.collection.objects.link(inst)
    inst.location = (0, 0, -1000)  # instance source far below the camera view
    em = bpy.data.objects.new(f"{name}Emitter", ico_mesh(f"{name}Emitter", radius, 2))
    sc.collection.objects.link(em)
    em.parent = parent
    em.location = location
    em.show_instancer_for_render = False
    em.show_instancer_for_viewport = False
    em.modifiers.new("Sparks", "PARTICLE_SYSTEM")
    st = em.particle_systems[0].settings
    st.count, st.frame_start, st.frame_end = count, frames[0], frames[1]
    st.lifetime, st.lifetime_random = lifetime, 0.6
    st.emit_from, st.normal_factor, st.factor_random = "VOLUME", speed, random_speed
    st.effector_weights.gravity = gravity
    st.render_type, st.instance_object = "OBJECT", inst
    st.particle_size, st.size_random = size, 0.7
    return em


def keyframes(ob, path, items, interp=None):
    for f, v in items:
        setattr(ob, path, v)
        ob.keyframe_insert(path, frame=f)
    if interp:
        ad = ob.animation_data
        for fc in (ad.action.fcurves if ad and ad.action else []):
            if fc.data_path == path:
                for kp in fc.keyframe_points:
                    kp.interpolation = interp


def save(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        bpy.ops.wm.save_as_mainfile(filepath=path)
    except RuntimeError:  # Windows sometimes holds the old file for a moment ("Cannot change old file"); one failure must not kill a queue
        time.sleep(10)
        bpy.ops.wm.save_as_mainfile(filepath=path)


# ---------------------------------------------------------------- project paths / CLI
UZARO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODELS = os.path.join(UZARO, "models")
TEXTURES = os.path.join(UZARO, "textures")
FRAMES = os.path.join(UZARO, "frames")
ICON_RES = 384          # rendered at 2x, downscaled to 192 by the encoder
ICON_FRAMES = (1, 60)   # 2 s


def parse_args():
    """-- <main|icon> [frame,frame,...]  (frames given = quick test stills)"""
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    mode = a[0] if a else "main"
    if mode not in ("main", "icon"):
        raise SystemExit(f"mode main|icon bo'lishi kerak, berildi: {mode}")
    test = [int(f) for f in a[1].split(",")] if len(a) > 1 else None
    return mode, test


def icon_camera(sc, cam, half_extent):
    """Square icon: frames 1..60, object centred, half_extent world units visible from the centre."""
    sc.render.resolution_x = sc.render.resolution_y = ICON_RES
    sc.frame_start, sc.frame_end = ICON_FRAMES
    cam.data.lens = CAM_DIST * 18.0 / half_extent


def render(sc, name, mode, test=None):
    out_dir = os.path.join(FRAMES, f"{name}_{mode}" + ("_test" if test else ""))
    os.makedirs(out_dir, exist_ok=True)
    sc.render.filepath = os.path.join(out_dir, "f_")
    if test:
        for f in test:
            sc.frame_set(f)
            sc.render.filepath = os.path.join(out_dir, f"f_{f:04d}.png")
            bpy.ops.render.render(write_still=True)
    else:
        bpy.ops.render.render(animation=True)
    return out_dir


def run_cli(build, name):
    """build(mode) -> scene. Main mode also saves the .blend for later tweaks."""
    mode, test = parse_args()
    sc = build(mode)
    if mode == "main" and not test:
        save(os.path.join(UZARO, "scenes", f"{name}.blend"))
    print("FRAMES_DIR", render(sc, name, mode, test))


# ---------------------------------------------------------------- materials
def _mix_float(nt, fac_socket, a_value_or_socket, b_value, target):
    mix = nt.nodes.new("ShaderNodeMix")
    mix.data_type = "FLOAT"
    nt.links.new(fac_socket, mix.inputs[0])
    if isinstance(a_value_or_socket, bpy.types.NodeSocket):
        nt.links.new(a_value_or_socket, mix.inputs[2])
    else:
        mix.inputs[2].default_value = a_value_or_socket
    mix.inputs[3].default_value = b_value
    nt.links.new(mix.outputs[0], target)


def repaint(mat, color_png, mask_png=None, metallic=0.0, roughness=0.3, coat=0.0):
    """Swap the base-colour texture for a cleaned one; inside the mask use new paint metal/rough/coat."""
    nt = mat.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    tex = bsdf.inputs["Base Color"].links[0].from_node
    tex.image = bpy.data.images.load(color_png, check_existing=True)
    if not mask_png:
        if coat:
            bsdf.inputs["Coat Weight"].default_value = coat
            bsdf.inputs["Coat Roughness"].default_value = 0.05
        return
    mask = nt.nodes.new("ShaderNodeTexImage")
    mask.image = bpy.data.images.load(mask_png, check_existing=True)
    mask.image.colorspace_settings.name = "Non-Color"
    if tex.inputs["Vector"].links:
        nt.links.new(tex.inputs["Vector"].links[0].from_socket, mask.inputs["Vector"])
    fac = mask.outputs["Color"]
    for sock_name, value in (("Metallic", metallic), ("Roughness", roughness)):
        sock = bsdf.inputs[sock_name]
        src = sock.links[0].from_socket if sock.links else sock.default_value
        _mix_float(nt, fac, src, value, sock)
    if coat:
        _mix_float(nt, fac, 0.0, coat, bsdf.inputs["Coat Weight"])
        bsdf.inputs["Coat Roughness"].default_value = 0.05


def flat_color(mat, rgb_linear, metallic=None, roughness=None, coat=0.0):
    """Drop the base-colour texture (e.g. a logo decal) and use one paint colour."""
    nt = mat.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    for l in list(bsdf.inputs["Base Color"].links):
        nt.links.remove(l)
    bsdf.inputs["Base Color"].default_value = (*rgb_linear, 1.0)
    for name, v in (("Metallic", metallic), ("Roughness", roughness)):
        if v is not None:
            for l in list(bsdf.inputs[name].links):
                nt.links.remove(l)
            bsdf.inputs[name].default_value = v
    if coat:
        bsdf.inputs["Coat Weight"].default_value = coat
        bsdf.inputs["Coat Roughness"].default_value = 0.05
