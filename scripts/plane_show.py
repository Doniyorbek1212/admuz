"""UZARO v2 show: private jet (tier 2). blender -b --factory-startup -P plane_show.py -- <show|icon> [f=..] [s=N]

Story (144 f = 6 s @ 24): the jet appears far away bottom-left, banks into a sweeping turn toward the camera,
rolls level as it crosses close in front (sun glints racing along the fuselage, wingtip strobes, contrails
off both engines), then rolls the other way and climbs out past the top right. The path is keyed in screen
space (plane.py's catmull/world_pos), so framing is exact: first frame offscreen, last frame offscreen.
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Quaternion, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402
import plane  # noqa: E402  (v1: catmull path, orientation)
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402

R = math.radians
ID = "plane"
TOTAL = 144
SIZE = 7.0
MODEL_ROT = (0.0, R(-30.2), R(180))  # file has the jet pitched 30.2 deg, nose at -X (PCA of the windows)
# (frame, u, v, depth): u/v in half-frame units at that depth; offscreen at both ends incl. half the jet
PATH = [(-6, -1.95, -0.95, 48), (1, -1.6, -0.8, 46), (36, -0.7, -0.35, 36), (72, 0.0, 0.0, 27),
        (104, 0.55, 0.3, 21), (132, 1.45, 0.72, 17), (TOTAL, 2.5, 1.2, 15.5), (TOTAL + 6, 2.9, 1.4, 15)]
BANK = [(1, 40.0), (40, 30.0), (78, 18.0), (110, 36.0), (TOTAL, 50.0)]   # deg; + shows the top to camera (probed)
BAKE = (-2, TOTAL + 3)
TRAIL_RADIUS, TRAIL_LIFE = 0.11, 34.0
STROBE_EVERY = 18
PASS_F = 100                         # closest pass: camera buffet


def parse():
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    opts = {"mode": a[0] if a else "show", "test": None, "samples": 64}
    for t in a[1:]:
        if t.startswith("f="):
            opts["test"] = [int(x) for x in t[2:].split(",")]
        elif t.startswith("s="):
            opts["samples"] = int(t[2:])
    if opts["mode"] not in ("show", "icon"):
        raise SystemExit(f"mode must be show|icon, got {opts['mode']}")
    return opts


def lerp_keys(keys, f):
    if f <= keys[0][0]:
        return keys[0][1]
    for (f0, a), (f1, b) in zip(keys, keys[1:]):
        if f <= f1:
            t = (f - f0) / (f1 - f0)
            t = t * t * (3 - 2 * t)
            return a + (b - a) * t
    return keys[-1][1]


def pose(f):
    """World matrix of the jet at frame f: screen-space path, nose along velocity, banked."""
    q = plane.orientation(f) @ Quaternion((1, 0, 0), R(lerp_keys(BANK, f)))
    return Matrix.Translation(plane.world_pos(f)) @ q.to_matrix().to_4x4(), q


def load():
    objs = gc.import_glb(os.path.join(gc.MODELS, "private_jet.glb"))
    root, _ = gc.normalize(objs, SIZE, rot=MODEL_ROT, name="Jet")
    bpy.context.view_layer.update()
    meshes = [o for o in objs if o.type == "MESH"]
    return root, meshes


def mesh_points(meshes, mat_name):
    o = next(o for o in meshes if o.data.materials and o.data.materials[0].name == mat_name)
    return [o.matrix_world @ v.co for v in o.data.vertices]


def anchors(meshes):
    """Root-space points (root is still identity): two engine nozzles, two wingtips."""
    eng = mesh_points(meshes, "Material.004")
    nozzles = []
    for side in (-1, 1):
        pts = [p for p in eng if p.y * side > 0]
        rear = min(p.x for p in pts)
        back = [p for p in pts if p.x < rear + 0.12]
        nozzles.append(sum(back, Vector()) / len(back) + Vector((-0.15, 0, 0)))
    body = mesh_points(meshes, "Red_AeroPlane")
    tips = [max(body, key=lambda p: p.y), min(body, key=lambda p: p.y)]   # left (+Y), right (-Y)
    return nozzles, tips


def materials():
    m = bpy.data.materials.get("Red_AeroPlane")
    if m and m.use_nodes:
        b = m.node_tree.nodes.get("Principled BSDF")
        if b:
            b.inputs["Roughness"].default_value = 0.16
            b.inputs["Coat Weight"].default_value = 1.0
            b.inputs["Coat Roughness"].default_value = 0.03


def nav_lights(sc, root, tips, total, strobe_every):
    """Red left / green right steady, white strobe double-flash on both tips."""
    for k, (tip, rgb) in enumerate(zip(tips, ((1.0, 0.05, 0.03), (0.05, 1.0, 0.25)))):
        nav = bpy.data.objects.new(f"Nav{k}", gc.ico_mesh(f"Nav{k}", 0.06, 2))
        sc.collection.objects.link(nav)
        nav.parent, nav.location = root, tip
        nav.data.materials.append(gc.emission_material(f"NavMat{k}", rgb, 25.0))
        st = bpy.data.objects.new(f"Strobe{k}", gc.ico_mesh(f"Strobe{k}", 0.05, 2))
        sc.collection.objects.link(st)
        st.parent, st.location = root, tip + Vector((-0.1, 0, 0))
        mat = gc.emission_material(f"StrobeMat{k}", (1.0, 1.0, 1.0), 0.0)
        st.data.materials.append(mat)
        em = mat.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"]
        for f in range(1, total + 1):
            em.default_value = 120.0 if (f % strobe_every) in (0, 3) else 0.0
            em.keyframe_insert("default_value", frame=f)
        for fc in mat.node_tree.animation_data.action.fcurves:
            for kp in fc.keyframe_points:
                kp.interpolation = "CONSTANT"


def sun(sc):
    """Low warm sun high camera-left: speculars sweep along the fuselage as the jet turns (STREAKS glints)."""
    ld = bpy.data.lights.new("Sun", "SUN")
    ld.energy, ld.angle, ld.color = 4.5, R(1.5), (1.0, 0.86, 0.66)
    ob = bpy.data.objects.new("Sun", ld)
    sc.collection.objects.link(ob)
    ob.rotation_euler = (R(55), R(-35), R(-20))


def animate(root):
    root.rotation_mode = "QUATERNION"
    prev = None
    for f in range(BAKE[0], BAKE[1] + 1):
        m, q = pose(f)
        if prev is not None and prev.dot(q) < 0:
            q.negate()
        prev = q
        root.location, root.rotation_quaternion = m.to_translation(), q
        root.keyframe_insert("location", frame=f)
        root.keyframe_insert("rotation_quaternion", frame=f)


def trail_mesh(name, pts, radius=TRAIL_RADIUS, sides=8):
    """Static tube along the whole flown path; UV.x holds the frame index at each ring."""
    verts, faces = [], []
    for c, a, b in zip(pts, pts[1:] + pts[-1:], pts[:1] + pts[:-1]):
        fwd = (a - b).normalized()
        u = fwd.cross(Vector((0, 0, 1))).normalized()
        v = fwd.cross(u).normalized()
        verts += [c + (u * math.cos(2 * math.pi * k / sides) + v * math.sin(2 * math.pi * k / sides)) * radius
                  for k in range(sides)]
    for i in range(len(pts) - 1):
        for k in range(sides):
            j = (k + 1) % sides
            faces.append((i * sides + k, i * sides + j, (i + 1) * sides + j, (i + 1) * sides + k))
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    uv = me.uv_layers.new(name="age")
    for loop in me.loops:
        uv.data[loop.index].uv = (loop.vertex_index // sides, 0.0)
    for poly in me.polygons:
        poly.use_smooth = True
    return me


def trail_material(first):
    """Alpha by age: (now - ring frame) / life, soft toward the silhouette. 'now' is keyed per frame, the mesh never moves."""
    m = bpy.data.materials.new("Contrail")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out = N("ShaderNodeOutputMaterial")
    tc, sep, now = N("ShaderNodeTexCoord"), N("ShaderNodeSeparateXYZ"), N("ShaderNodeValue")
    now.name = "Now"
    L(tc.outputs["UV"], sep.inputs[0])
    age = N("ShaderNodeMath")
    age.operation = "SUBTRACT"
    L(now.outputs[0], age.inputs[0])
    L(sep.outputs["X"], age.inputs[1])
    ramp = N("ShaderNodeMapRange")          # age 0..life -> 1..0; clamped; ages < 0 (not flown yet) cut below
    ramp.inputs["From Min"].default_value, ramp.inputs["From Max"].default_value = 0.0, TRAIL_LIFE
    ramp.inputs["To Min"].default_value, ramp.inputs["To Max"].default_value = 0.55, 0.0
    L(age.outputs[0], ramp.inputs["Value"])
    flown = N("ShaderNodeMath")
    flown.operation = "GREATER_THAN"
    flown.inputs[1].default_value = 0.0
    L(age.outputs[0], flown.inputs[0])
    lw = N("ShaderNodeLayerWeight")
    lw.inputs["Blend"].default_value = 0.5
    rim = N("ShaderNodeMath")
    rim.operation, rim.use_clamp = "POWER", True
    rim.inputs[1].default_value = 2.0
    L(lw.outputs["Facing"], rim.inputs[0])
    inv = N("ShaderNodeMath")
    inv.operation, inv.use_clamp = "SUBTRACT", True
    inv.inputs[0].default_value = 1.0
    L(rim.outputs[0], inv.inputs[1])
    a1, a2 = N("ShaderNodeMath"), N("ShaderNodeMath")
    a1.operation = a2.operation = "MULTIPLY"
    L(ramp.outputs[0], a1.inputs[0])
    L(flown.outputs[0], a1.inputs[1])
    L(a1.outputs[0], a2.inputs[0])
    L(inv.outputs[0], a2.inputs[1])
    fx._emit_mix(nt, (0.95, 0.95, 0.97), 1.3, a2.outputs[0], out)
    for f in range(first, TOTAL + 1):
        now.outputs[0].default_value = float(f - first)
        now.outputs[0].keyframe_insert("default_value", frame=f)
    return m


def contrails(sc, nozzles):
    frames = list(range(BAKE[0], TOTAL + 1))
    mat = trail_material(BAKE[0])
    for k, off in enumerate(nozzles):
        pts = [pose(f)[0] @ off for f in frames]
        assert len(pts) > 2 and all((b - a).length > 0 for a, b in zip(pts, pts[1:]))
        me = trail_mesh(f"Contrail{k}", pts)
        me.materials.append(mat)
        ob = bpy.data.objects.new(f"Contrail{k}", me)
        sc.collection.objects.link(ob)
        ob.visible_shadow = False


def build(sc, opts, icon=False):
    plane.PATH = PATH                     # plane.world_pos/orientation read this module global
    root, meshes = load()
    nozzles, tips = anchors(meshes)
    materials()
    total = 30 if icon else TOTAL
    sh.setup_cycles(sc, (1, total), samples=opts["samples"], shutter=0.5)
    gc.setup_world(sc, strength=0.8, hdri="sunrise.exr")
    cam = gc.setup_camera(sc)
    gc.setup_lights(sc, follow=root, scale=1.0)
    sun(sc)
    sh.setup_comp(sc, fog_threshold=1.6, fog_size=7, streak_threshold=4.0)
    nav_lights(sc, root, tips, total, 15 if icon else STROBE_EVERY)
    if icon:
        return root, meshes, cam
    animate(root)
    contrails(sc, nozzles)
    sh.camera_shake(cam, PASS_F - 6, 18, amp=0.05, rot_deg=0.35, seed=21)
    sh.screen_extent(sc, cam, meshes, (1, 72, PASS_F, TOTAL))
    return root


def build_icon(sc, opts):
    """2 s loop @ 15 fps: 3/4 front view, gentle bank rock and bob, strobes."""
    root, meshes, cam = build(sc, opts, icon=True)
    n = 30
    sc.render.fps = sh.ICON_FPS
    sc.render.resolution_x = sc.render.resolution_y = 384
    root.rotation_mode = "XYZ"
    gc.keyframes(root, "rotation_euler", [(0, (R(-6), R(-8), R(-35))), (n // 2, (R(6), R(-8), R(-35))),
                                          (n, (R(-6), R(-8), R(-35)))])
    gc.keyframes(root, "location", [(0, (0, 0, -0.08)), (n // 2, (0, 0, 0.08)), (n, (0, 0, -0.08))])
    bpy.context.view_layer.update()
    lo, hi = gc.world_bbox(meshes)
    c = (lo + hi) / 2
    half = max(hi.x - lo.x, hi.z - lo.z) / 2 * 1.1
    cam.location = (c.x, c.y - gc.CAM_DIST, c.z)
    cam.data.lens = gc.CAM_DIST * 18.0 / half
    return sc


def main():
    opts = parse()
    sc = gc.reset_scene("Jet")
    sc.render.fps = sh.FPS
    if opts["mode"] == "show":
        build(sc, opts)
        if not opts["test"]:
            gc.save(os.path.join(sh.src_dir(ID), "plane_show.blend"))
        sh.render(sc, ID, "show", opts["test"])
    else:
        build_icon(sc, opts)
        if not opts["test"]:
            gc.save(os.path.join(sh.src_dir(ID), "plane_icon.blend"))
        sh.render(sc, ID, "icon", opts["test"])


if __name__ == "__main__":
    main()
