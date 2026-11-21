"""Skeleton for the remaining gift shows: CLI, stage (Cycles, light, comp), small animation and mesh helpers.

A show script defines build_show(sc, opts) and build_icon(sc, opts) and calls stage.run(ID, build_show, build_icon).
    blender -b --factory-startup -P <gift>_show.py -- <show|icon> [f=1,40,80] [s=16]
"""
import math
import os
import random
import sys

import bmesh
import bpy
from mathutils import Vector

import gift_common as gc
import show_common as sh

R = math.radians
ICON_N = 30           # 2 s @ 15 fps


def smooth(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


def env(f, a, b):
    return smooth((f - a) / (b - a))


def interp(keys, f):
    """Smoothstep between (frame, value) keys; values may be floats or tuples."""
    if f <= keys[0][0]:
        return keys[0][1]
    for (f0, a), (f1, b) in zip(keys, keys[1:]):
        if f <= f1:
            t = smooth((f - f0) / (f1 - f0))
            if isinstance(a, (int, float)):
                return a + (b - a) * t
            return tuple(x + (y - x) * t for x, y in zip(a, b))
    return keys[-1][1]


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


def load(name, size, rot=(0.0, 0.0, 0.0), hide=(), strip_rig=False):
    """Import models/<name>.glb under Root -> Model. hide: substrings of objects to leave out of the render.
    strip_rig: drop the file's skinning so the mesh stays in its bind pose, ready for autorig."""
    objs = gc.import_glb(os.path.join(gc.MODELS, f"{name}.glb"), hide=("Icosphere", *hide))
    if strip_rig:
        for o in objs:
            if o.type == "MESH":
                for mod in [m for m in o.modifiers if m.type == "ARMATURE"]:
                    o.modifiers.remove(mod)
    root, model = gc.normalize(objs, size, rot=rot, name=name)
    meshes = [o for o in objs if o.type == "MESH" and not o.hide_render]
    return root, model, objs, meshes


def apply_modifier(ob, kind, **props):
    """Bake one modifier into the mesh data (Decimate before rigging heavy scans, Subsurf for low poly)."""
    mod = ob.modifiers.new("Tmp", kind)
    for k, v in props.items():
        setattr(mod, k, v)
    bpy.context.view_layer.update()
    ob.data = bpy.data.meshes.new_from_object(ob.evaluated_get(bpy.context.evaluated_depsgraph_get()))
    ob.modifiers.remove(mod)


def weld(ob, dist=1e-4):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=dist)
    bm.to_mesh(ob.data)
    bm.free()


def spring(drive, k=0.12, c=0.28):
    """Damped follow-through: drive is {frame: target}; returns {frame: value} that lags and overshoots."""
    x, v, out = 0.0, 0.0, {}
    for f in sorted(drive):
        v += k * (drive[f] - x) - c * v
        x += v
        out[f] = x
    return out


def setup(sc, total, samples, world=0.8, hdri="sunrise.exr", follow=None, lights=1.0, fog=(1.6, 7), streak=4.0,
          res=sh.RES, shutter=0.5):
    """Cycles, world, camera, lights, comp. Returns the camera."""
    sh.setup_cycles(sc, (1, total), samples=samples, shutter=shutter, res=res)
    sc.cycles.film_transparent_glass = True
    sc.cycles.caustics_refractive = sc.cycles.caustics_reflective = False
    gc.setup_world(sc, strength=world, hdri=hdri)
    cam = gc.setup_camera(sc)
    if lights:
        gc.setup_lights(sc, follow=follow, scale=lights)
    sh.setup_comp(sc, fog_threshold=fog[0], fog_size=fog[1], streak_threshold=streak)
    return cam


def setup_icon(sc, samples, world=0.8, hdri="sunrise.exr", follow=None, lights=1.0, fog=(1.6, 7), streak=4.0):
    cam = setup(sc, ICON_N, samples, world, hdri, follow, lights, fog, streak, res=(384, 384))
    sc.render.fps = sh.ICON_FPS
    return cam


def frame_icon(cam, meshes, pad=1.12):
    """Aim the static icon camera at the box of meshes as they are posed right now."""
    bpy.context.view_layer.update()
    lo, hi = gc.world_bbox(meshes)
    c = (lo + hi) / 2
    half = max(hi.x - lo.x, hi.z - lo.z) / 2 * pad
    cam.location = (c.x, c.y - gc.CAM_DIST, c.z)
    cam.rotation_euler = (R(90), 0, 0)
    cam.data.lens = gc.CAM_DIST * 18.0 / half


def key_path(ob, frames, fn, path="location", interpolation=None):
    """fn(frame) -> value, keyed every given frame."""
    for f in frames:
        setattr(ob, path, fn(f))
        ob.keyframe_insert(path, frame=f)
    if interpolation and ob.animation_data and ob.animation_data.action:
        for fc in ob.animation_data.action.fcurves:
            if fc.data_path == path:
                for kp in fc.keyframe_points:
                    kp.interpolation = interpolation


def key_socket(sock, items, interpolation=None):
    """Key a node socket default_value: [(frame, value), ...] on a material or world node tree."""
    for f, v in items:
        sock.default_value = v
        sock.keyframe_insert("default_value", frame=f)
    if interpolation:
        tree = sock.id_data
        for fc in tree.animation_data.action.fcurves:
            for kp in fc.keyframe_points:
                kp.interpolation = interpolation


def bsdf(mat):
    return next(n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")


def shiny(mat, roughness=None, coat=0.0, metallic=None, sheen=0.0):
    """Tweak an imported material; texture links on the changed sockets are removed."""
    b, tree = bsdf(mat), mat.node_tree
    for name, v in (("Roughness", roughness), ("Metallic", metallic)):
        if v is not None:
            for l in list(b.inputs[name].links):
                tree.links.remove(l)
            b.inputs[name].default_value = v
    if coat:
        b.inputs["Coat Weight"].default_value = coat
        b.inputs["Coat Roughness"].default_value = 0.04
    if sheen:
        b.inputs["Sheen Weight"].default_value = sheen
        b.inputs["Sheen Roughness"].default_value = 0.45


def pbr(name, rgb, metallic=0.0, roughness=0.4, coat=0.0, transmission=0.0, ior=1.45, emission=None, strength=0.0):
    m = gc.pbr_material(name, rgb, metallic, roughness, coat)
    b = bsdf(m)
    b.inputs["Transmission Weight"].default_value = transmission
    b.inputs["IOR"].default_value = ior
    if emission:
        b.inputs["Emission Color"].default_value = (*emission, 1.0)
        b.inputs["Emission Strength"].default_value = strength
    return m


def emit(name, rgb, strength):
    """Pure emission, no shadow-side grey: flames, sparks, window glow. Key .node_tree.nodes['Emission'] to animate."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = (*rgb, 1.0)
    em.inputs["Strength"].default_value = strength
    nt.links.new(em.outputs[0], nt.nodes.new("ShaderNodeOutputMaterial").inputs["Surface"])
    return m


def link(sc, name, mesh, *mats, parent=None, loc=None, shadow=True):
    ob = bpy.data.objects.new(name, mesh)
    sc.collection.objects.link(ob)
    for m in mats:
        mesh.materials.append(m)
    if parent:
        ob.parent = parent
    if loc is not None:
        ob.location = loc
    ob.visible_shadow = shadow
    return ob


def lathe(name, profile, segs=48, smooth_shade=True):
    """Revolve [(r, z), ...] about Z; r=0 points close the shape."""
    verts, faces = [], []
    rows = []
    for r, z in profile:
        if r <= 1e-5:
            rows.append([len(verts)])
            verts.append((0.0, 0.0, z))
        else:
            rows.append(list(range(len(verts), len(verts) + segs)))
            verts += [(r * math.cos(2 * math.pi * i / segs), r * math.sin(2 * math.pi * i / segs), z) for i in range(segs)]
    for a, b in zip(rows, rows[1:]):
        for i in range(segs):
            j = (i + 1) % segs
            if len(a) == 1:
                faces.append((a[0], b[i], b[j]))
            elif len(b) == 1:
                faces.append((a[i], b[0], a[j]))
            else:
                faces.append((a[i], b[i], b[j], a[j]))
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.update()
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    if smooth_shade:
        me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    return me


def heart_mesh(name, size=1.0, depth=0.42, rings=10, segs=64):
    """Puffy foil-balloon heart in the XZ plane, centred, about 2*size wide; tip at -Z, knot end. Depth is along Y."""
    def outline(t):
        x = 16 * math.sin(t) ** 3
        z = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        return x / 16 * size, (z + 2.5) / 16 * size

    verts = [(0.0, -depth * size, 0.0), (0.0, depth * size, 0.0)]
    faces, rows = [], {}
    for side, pole in ((-1, 0), (1, 1)):
        for r in range(1, rings + 1):
            a = r / rings * math.pi / 2
            if r == rings and side == 1:     # both halves share the rim
                rows[(side, r)] = rows[(-1, r)]
                continue
            rows[(side, r)] = list(range(len(verts), len(verts) + segs))
            for k in range(segs):
                x, z = outline(2 * math.pi * k / segs)
                verts.append((x * math.sin(a), side * depth * size * math.cos(a), z * math.sin(a)))
        for k in range(segs):
            j = (k + 1) % segs
            faces.append((pole, rows[(side, 1)][k], rows[(side, 1)][j]))
            for r in range(1, rings):
                aa, bb = rows[(side, r)], rows[(side, r + 1)]
                faces.append((aa[k], bb[k], bb[j], aa[j]))
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.update()
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    return me


def box_mesh(name, x, y, z):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=(x, y, z), verts=bm.verts)
    bm.to_mesh(me)
    bm.free()
    return me


def islands(mesh, decimals=5):
    """Connected vertex groups, welding duplicates at UV seams by position (glTF splits them)."""
    weld = {}
    parent = list(range(len(mesh.vertices)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for v in mesh.vertices:
        key = tuple(round(c, decimals) for c in v.co)
        if key in weld:
            parent[find(v.index)] = find(weld[key])
        else:
            weld[key] = v.index
    for e in mesh.edges:
        parent[find(e.vertices[0])] = find(e.vertices[1])
    groups = {}
    for i in range(len(parent)):
        groups.setdefault(find(i), []).append(i)
    return list(groups.values())


def bake_all(sc):
    """Bake particles, cloth, hair and rigid bodies in memory: test stills then land on the right sim frame."""
    with bpy.context.temp_override(scene=sc):
        bpy.ops.ptcache.bake_all(bake=True)


def rigid_world(sc, end, substeps=20):
    with bpy.context.temp_override(scene=sc):
        bpy.ops.rigidbody.world_add()
    w = sc.rigidbody_world
    w.substeps_per_frame, w.solver_iterations = substeps, 12
    w.point_cache.frame_start, w.point_cache.frame_end = 1, end
    w.collection = bpy.data.collections.new("RigidBodies")
    sc.collection.children.link(w.collection)
    sc.collection.children.unlink(w.collection)   # membership only, objects stay in the scene collection
    return w


def rigid(sc, ob, kind="ACTIVE", mass=1.0, shape="CONVEX_HULL", friction=0.5, bounce=0.3, kinematic=False):
    w = sc.rigidbody_world
    w.collection.objects.link(ob)
    rb = ob.rigid_body
    rb.type, rb.mass, rb.collision_shape = kind, mass, shape
    rb.friction, rb.restitution, rb.kinematic = friction, bounce, kinematic
    rb.collision_margin = 0.01
    return rb


def seeded(seed):
    return random.Random(seed)


def catmull(points, t):
    """Smooth curve through points, t in 0..1 over the whole list: no stop at each key, unlike interp."""
    n = len(points) - 1
    u = min(max(t, 0.0), 1.0) * n
    i = min(int(u), n - 1)
    s = u - i
    p0, p1, p2, p3 = (Vector(points[max(i - 1, 0)]), Vector(points[i]), Vector(points[i + 1]), Vector(points[min(i + 2, n)]))
    return tuple(0.5 * ((2 * p1) + (p2 - p0) * s + (2 * p0 - 5 * p1 + 4 * p2 - p3) * s * s + (3 * p1 - p0 - 3 * p2 + p3) * s ** 3))


def aim(direction):
    """(pitch, yaw) in radians, for rotation_euler (pitch, roll, yaw), that points a model's -Y nose along direction."""
    x, y, z = direction
    return math.atan2(-z, math.hypot(x, y)), math.atan2(x, -y)


def flag(sc, name, parent, loc, w, h, rgb, total, yaw=0.0):
    """Cloth flag pinned along its hoist, trailing +X before yaw. Needs a wind field in the scene."""
    nx, nz = 18, 8
    verts = [(i / nx * w, 0.0, -j / nz * h) for j in range(nz + 1) for i in range(nx + 1)]
    faces = [(j * (nx + 1) + i, j * (nx + 1) + i + 1, (j + 1) * (nx + 1) + i + 1, (j + 1) * (nx + 1) + i) for j in range(nz) for i in range(nx)]
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    mat = pbr(f"{name}Cloth", rgb, roughness=0.55)
    bsdf(mat).inputs["Sheen Weight"].default_value = 0.5
    ob = link(sc, name, me, mat, parent=parent, loc=loc)
    ob.rotation_euler = (0, 0, yaw)
    ob.vertex_groups.new(name="Pin").add([j * (nx + 1) for j in range(nz + 1)], 1.0, "REPLACE")
    cl = ob.modifiers.new("Cloth", "CLOTH")
    cl.settings.vertex_group_mass = "Pin"
    cl.settings.quality = 8
    cl.settings.mass, cl.settings.air_damping = 0.12, 1.0
    cl.settings.bending_stiffness = 0.2
    cl.point_cache.frame_start, cl.point_cache.frame_end = 1, total
    return ob


def wind(strength=7.0, location=(4.0, -6.0, 3.0), rotation=(R(90), 0, R(-90)), gust=2.0):
    """Steady wind plus turbulence for cloth."""
    bpy.ops.object.effector_add(type="WIND", location=location)
    w = bpy.context.active_object
    w.rotation_euler = rotation
    w.field.strength, w.field.noise, w.field.flow = strength, 2.5, 0.0
    bpy.ops.object.effector_add(type="TURBULENCE", location=(0, 0, 2))
    t = bpy.context.active_object
    t.field.strength, t.field.size, t.field.noise = gust, 0.6, 1.5


def run(gift_id, build_show, build_icon):
    opts = parse()
    sc = gc.reset_scene(gift_id)
    sc.render.fps = sh.FPS
    part = opts["mode"]
    (build_show if part == "show" else build_icon)(sc, opts)
    if not opts["test"]:
        gc.save(os.path.join(sh.src_dir(gift_id), f"{gift_id}_{part}.blend"))
    sh.render(sc, gift_id, part, opts["test"])


__all__ = ["Vector"]
