"""UZARO v2 show: rose_bloom (tier 1, 84 f = 3.5 s).

A closed bud rises from below on its stem, the petals open outer ring first (per-petal shape keys), dew drops
roll off and fall, then a gust lifts loose petals away. Exit: the fade the encoder applies, while petals leave.
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
import stage  # noqa: E402
from stage import R, env, smooth  # noqa: E402

ID = "rose_bloom"
TOTAL = 84
SIZE = 13.0
RISE = (1, 24)
BLOOM = (16, 60)
HEAD_FRACTION = 0.8        # of the model height: everything above is flower head
GROUPS = 8
BUD_RADIUS, BUD_STRETCH, BUD_TWIST = 0.42, 1.2, 0.5
DROPS = 16
LOOSE_PETALS = 8
GUST_F = 56
REST_Z = -2.2
FRAME_ZOOM = 0.8           # leaves touched the left edge at 1.0: whole plant inside the safe area


def head_verts(meshes):
    """Per mesh: (index, world position) for the head, plus the head centre."""
    bpy.context.view_layer.update()
    pts = [(o, v.index, o.matrix_world @ v.co) for o in meshes for v in o.data.vertices]
    zs = [p[2].z for p in pts]
    z0, z1 = min(zs), max(zs)
    cut = z0 + HEAD_FRACTION * (z1 - z0)
    head = [p for p in pts if p[2].z > cut]
    c = sum((p[2] for p in head), Vector()) / len(head)
    return head, Vector((c.x, c.y, cut)), z1


def bud_position(p, axis, z_top):
    """Closed-bud position of a world point: pulled to the axis, stretched up, twisted."""
    d = p - axis
    h = (p.z - axis.z) / max(1e-4, z_top - axis.z)
    r = Vector((d.x, d.y)).length
    a = math.atan2(d.y, d.x) + BUD_TWIST * h
    k = BUD_RADIUS * (1.0 - 0.25 * h)
    return Vector((axis.x + r * k * math.cos(a), axis.y + r * k * math.sin(a), axis.z + (p.z - axis.z) * BUD_STRETCH))


def petal_keys(meshes, axis, z_top):
    """One shape key per ring of islands: outer rings open first. Returns [(key, delay 0..1)]."""
    out = []
    for o in meshes:
        inv, mw = o.matrix_world.inverted(), o.matrix_world
        rings = []
        for isl in stage.islands(o.data):
            pts = [mw @ o.data.vertices[i].co for i in isl]
            if max(p.z for p in pts) <= axis.z:
                continue
            c = sum(pts, Vector()) / len(pts)
            rings.append((Vector((c.x - axis.x, c.y - axis.y)).length, isl))
        if not rings:
            continue
        rings.sort(key=lambda t: -t[0])
        o.shape_key_add(name="Basis")
        for g in range(GROUPS):
            part = rings[g * len(rings) // GROUPS:(g + 1) * len(rings) // GROUPS]
            if not part:
                continue
            k = o.shape_key_add(name=f"Bud{g}", from_mix=False)
            for _, isl in part:
                for i in isl:
                    p = mw @ o.data.vertices[i].co
                    if p.z > axis.z:
                        k.data[i].co = inv @ bud_position(p, axis, z_top)
            out.append((k, g / max(1, GROUPS - 1)))
        print("ROSE", o.name, "islands in head", len(rings))
    return out


def animate_bloom(keys):
    span = BLOOM[1] - BLOOM[0]
    for k, delay in keys:
        a = BLOOM[0] + delay * span * 0.55
        b = a + span * 0.45
        k.value = 1.0
        k.keyframe_insert("value", frame=int(a))
        k.value = 0.0
        k.keyframe_insert("value", frame=int(b))


def drops(sc, root, head, axis):
    """Glass beads riding the opening petals, then rolling off and falling."""
    glass = stage.pbr("Dew", (1, 1, 1), roughness=0.02, transmission=1.0, ior=1.33)
    rnd = stage.seeded(5)
    outer = sorted(head, key=lambda p: -Vector((p[2].x - axis.x, p[2].y - axis.y)).length)[:len(head) // 3]
    for i in range(DROPS):
        _, _, p = rnd.choice(outer)
        r = rnd.uniform(0.035, 0.075)
        ob = stage.link(sc, f"Dew{i}", gc.ico_mesh(f"Dew{i}", r, 3), glass, shadow=False)
        start = rnd.randint(40, 62)
        fall = rnd.uniform(0.0, 3.0)

        def pos(f, p=p, start=start, fall=fall):
            base = p
            rise = rise_offset(f)
            t = max(0.0, f - start) / sh.FPS
            return (base.x + fall * t * 0.4, base.y - 0.1, base.z + rise - 14.0 * t * t)
        stage.key_path(ob, range(1, TOTAL + 1, 2), pos)
        ob.hide_render = False


def rise_offset(f):
    """Root z relative to its rest height."""
    return -14.0 * (1 - smooth((f - RISE[0]) / (RISE[1] - RISE[0])) ** 0.8)


def petals(sc, meshes, axis, source_island):
    """Loose copies of an outer petal: start on the head, leave on the gust with a tumble."""
    src_ob, isl = source_island
    co = [src_ob.matrix_world @ src_ob.data.vertices[i].co for i in isl]
    c = sum(co, Vector()) / len(co)
    idx = {v: n for n, v in enumerate(isl)}
    faces = [[idx[v] for v in p.vertices] for p in src_ob.data.polygons if all(v in idx for v in p.vertices)]
    rnd = stage.seeded(11)
    mat = src_ob.data.materials[0]
    uv = src_ob.data.uv_layers.active.data
    for n in range(LOOSE_PETALS):
        me = bpy.data.meshes.new(f"Loose{n}")
        me.from_pydata([p - c for p in co], [], faces)
        lay = me.uv_layers.new(name="UV")
        keep = [p for p in src_ob.data.polygons if all(v in idx for v in p.vertices)]
        loops = [li for p in keep for li in p.loop_indices]
        for dst, li in zip(lay.data, loops):
            dst.uv = uv[li].uv
        me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
        ob = stage.link(sc, f"Loose{n}", me, mat)
        s = rnd.uniform(0.6, 0.95)
        ob.scale = (s, s, s)
        ang, rad = rnd.uniform(0, 6.28), rnd.uniform(0.2, 0.7)
        start = c + Vector((rad * math.cos(ang), rad * math.sin(ang), rnd.uniform(-0.1, 0.25)))
        t0 = GUST_F - 12 + n * 2
        spin = Vector((rnd.uniform(-6, 6), rnd.uniform(-6, 6), rnd.uniform(-4, 4)))
        lift, drift, phase = rnd.uniform(1.5, 4.5), rnd.uniform(6, 10), rnd.uniform(0, 6.28)

        def path(f, start=start, t0=t0, lift=lift, drift=drift, phase=phase):
            t = max(0.0, f - t0) / sh.FPS
            hidden = 0.0 if f >= t0 else -60.0
            return (start.x + drift * t * t * 0.9 + 0.3 * math.sin(4 * t + phase),
                    start.y - 1.2 * t,
                    start.z + lift * t + 0.35 * math.sin(6 * t + phase) + hidden)

        def rot(f, t0=t0, spin=spin):
            t = max(0.0, f - t0) / sh.FPS
            return tuple(a * t for a in spin)
        stage.key_path(ob, range(1, TOTAL + 1, 2), path)
        stage.key_path(ob, range(1, TOTAL + 1, 2), rot, path="rotation_euler")


def outer_island(meshes, axis):
    """A real petal: the largest island of the head away from the axis."""
    best, size = None, 0
    for o in meshes:
        for isl in stage.islands(o.data):
            pts = [o.matrix_world @ o.data.vertices[i].co for i in isl[::8]]
            if len(isl) > size and min(p.z for p in pts) > axis.z:
                best, size = (o, isl), len(isl)
    print("ROSE petal source verts", size)
    return best


def build_show(sc, opts):
    root, model, objs, meshes = stage.load("red_rose", SIZE, rot=(0, 0, R(30)))
    root.location.z = REST_Z
    bpy.context.view_layer.update()
    head, axis, z_top = head_verts(meshes)
    src = outer_island(meshes, axis)
    keys = petal_keys(meshes, axis, z_top)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.7, follow=root, lights=0.6, fog=(1.4, 7))
    cam.location.z = 0.0
    cam.data.lens *= FRAME_ZOOM
    cam.data.shift_x, cam.data.shift_y = -0.05, -0.05   # the leaves reach left and the stem down: centre the whole plant
    animate_bloom(keys)
    petals(sc, meshes, axis, src)
    drops(sc, root, head, axis)
    stage.key_path(root, range(1, TOTAL + 1, 2), lambda f: (0.12 * math.sin(f / 9), 0.0, REST_Z + rise_offset(f)))
    stage.key_path(root, range(1, TOTAL + 1, 2),
                   lambda f: (0.0, R(1.2) * math.sin(f / 7) + R(5) * env(f, GUST_F, GUST_F + 12), 0.0),
                   path="rotation_euler")
    mat = fx.fade_material("Glint", (1.0, 0.75, 0.55), 18.0)
    fx.particle_burst(sc, "Glint", gc.ico_mesh("GlintE", 1.2, 2), mat, 70, (28, 70), 22, 0.02, 0.6, rand=1.0,
                      location=(axis.x, axis.y, axis.z + 0.6))
    sh.screen_extent(sc, cam, meshes, (1, RISE[1], BLOOM[1], TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    root, model, objs, meshes = stage.load("red_rose", SIZE, rot=(0, 0, R(30)))
    cam = stage.setup_icon(sc, opts["samples"], world=0.7, follow=root, lights=0.6, fog=(1.4, 7))
    bpy.context.view_layer.update()
    head, axis, z_top = head_verts(meshes)
    n = stage.ICON_N
    half = (z_top - axis.z) * 1.15
    cam.location = (axis.x, axis.y - gc.CAM_DIST, axis.z + half * 0.5)
    cam.data.lens = gc.CAM_DIST * 18.0 / half
    stage.key_path(root, range(0, n + 1), lambda f: (0.0, R(2.2) * math.sin(2 * math.pi * f / n), 0.0), path="rotation_euler")


stage.run(ID, build_show, build_icon)
