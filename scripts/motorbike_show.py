"""UZARO v2 show: motorbike (tier 2, 120 f = 5 s). shortcut: riderless, no rider model was approved; ask if one is wanted.

The cafe racer roars in from the left, the front wheel lifts into a long wheelie with sparks and backfire from the
exhaust and tyre smoke, slams down, bounces on its forks and shoots out to the right. Headlight carries a lens flare.
The file's single mesh is split into body and two wheels by connected islands.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import autorig  # noqa: E402
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, env, interp  # noqa: E402

ID = "motorbike"
TOTAL = 120
SIZE = 6.0
K = 1.08
GROUND_Z = -3.0
YAW = R(-20)              # front toward camera
REAR = Vector((-2.07, 0.0, -0.71))
FRONT = Vector((2.05, 0.0, -0.71))
WHEEL_R = 0.93
CONTACT = Vector((-2.07, 0.0, -1.63))
LAMP = Vector((1.84, 0.0, 1.1))
EXHAUST = Vector((-1.05, 0.12, -1.0))
TRAVEL = [(1, -9.2), (28, -1.6), (78, -0.3), (88, 0.1), (TOTAL, 11.5)]
WHEELIE = [(1, 0.0), (28, 0.0), (40, 40.0), (50, 34.0), (62, 41.0), (74, 37.0), (84, 0.0)]
SLAM = 84


def split_wheels(meshes):
    """Move each wheel's islands into its own mesh, centred on the axle."""
    out = {"R": [], "F": []}
    for ob in meshes:
        groups = stage.islands(ob.data)
        take = {"R": [], "F": []}
        co = [v.co.copy() for v in ob.data.vertices]
        for g in groups:
            pts = [co[i] for i in g]
            for key, c in (("R", REAR), ("F", FRONT)):
                if all(math.hypot(p.x - c.x, p.z - c.z) < WHEEL_R + 0.04 and abs(p.y) < 0.36 for p in pts):
                    take[key] += g
                    break
        for key in ("R", "F"):
            if take[key]:
                out[key].append(extract(ob, take[key], REAR if key == "R" else FRONT))
        drop = set(take["R"] + take["F"])
        keep_only(ob.data, set(range(len(co))) - drop)
    return out


def keep_only(me, keep):
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.verts.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.index not in keep], context="VERTS")
    bm.to_mesh(me)
    bm.free()


def extract(ob, idx, center):
    me = ob.data.copy()
    keep_only(me, set(idx))
    me.transform(Matrix.Translation(-center))
    nb = bpy.data.objects.new(f"Wheel_{ob.name}", me)
    bpy.context.scene.collection.objects.link(nb)
    return nb


def load(sc):
    root, model, objs, meshes = stage.load(ID, SIZE)
    autorig.bake_world(meshes)
    wheels = split_wheels(meshes)
    pivot = bpy.data.objects.new("Pivot", None)
    sc.collection.objects.link(pivot)
    pivot.parent = root
    pivot.rotation_mode = "XYZ"
    for m in meshes:
        m.data.transform(Matrix.Translation(-CONTACT))
        m.parent = pivot
    hubs = {}
    for key, c in (("R", REAR), ("F", FRONT)):
        hub = bpy.data.objects.new(f"Hub{key}", None)
        sc.collection.objects.link(hub)
        hub.parent = pivot
        hub.location = c - CONTACT
        hub.rotation_mode = "XYZ"
        hubs[key] = hub
        for w in wheels[key]:
            w.parent = hub
    print("INFO_WHEELS", {k: [len(w.data.vertices) for w in v] for k, v in wheels.items()})
    root.scale = (K, K, K)
    root.rotation_euler = (0, 0, YAW)
    bike = meshes + wheels["R"] + wheels["F"]
    for s in {mat for m in bike for mat in m.data.materials}:
        stage.shiny(s, coat=0.35)
    return root, pivot, hubs, bike


def headlight(sc, pivot):
    """Lamp disc plus a camera-facing flare sprite: comp star glare catches the hot centre."""
    p = LAMP - CONTACT
    lamp = stage.link(sc, "Lamp", gc.ico_mesh("Lamp", 0.13, 2), stage.emit("Lamp", (1.0, 0.92, 0.72), 22.0), parent=pivot, loc=p, shadow=False)
    ld = bpy.data.lights.new("Beam", "SPOT")
    ld.energy, ld.spot_size, ld.color = 1500.0, R(50), (1.0, 0.9, 0.7)
    beam = bpy.data.objects.new("Beam", ld)
    sc.collection.objects.link(beam)
    beam.parent = pivot
    beam.location = p
    beam.rotation_euler = (0, R(90), 0)
    me = bpy.data.meshes.new("FlareSprite")
    me.from_pydata([(-0.8, 0, -0.8), (0.8, 0, -0.8), (0.8, 0, 0.8), (-0.8, 0, 0.8)], [], [(0, 1, 2, 3)])
    me.uv_layers.new(name="UV")
    for i, uv in enumerate(((0, 0), (1, 0), (1, 1), (0, 1))):
        me.uv_layers[0].data[i].uv = uv
    m = bpy.data.materials.new("Flare")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    tc, sep, out = N("ShaderNodeTexCoord"), N("ShaderNodeSeparateXYZ"), N("ShaderNodeOutputMaterial")
    L(tc.outputs["UV"], sep.inputs[0])
    cx = N("ShaderNodeMath")
    cx.operation, cx.inputs[1].default_value = "SUBTRACT", 0.5
    L(sep.outputs["X"], cx.inputs[0])
    cz = N("ShaderNodeMath")
    cz.operation, cz.inputs[1].default_value = "SUBTRACT", 0.5
    L(sep.outputs["Y"], cz.inputs[0])
    # anamorphic: a tight round core plus a long horizontal streak
    length = N("ShaderNodeVectorMath")
    length.operation = "LENGTH"
    comb = N("ShaderNodeCombineXYZ")
    L(cx.outputs[0], comb.inputs["X"])
    L(cz.outputs[0], comb.inputs["Y"])
    L(comb.outputs[0], length.inputs[0])
    fall = N("ShaderNodeMapRange")
    fall.inputs["From Min"].default_value, fall.inputs["From Max"].default_value = 0.5, 0.0
    fall.interpolation_type = "SMOOTHSTEP"
    L(length.outputs["Value"], fall.inputs["Value"])
    pw = N("ShaderNodeMath")
    pw.operation, pw.inputs[1].default_value = "POWER", 5.0
    L(fall.outputs[0], pw.inputs[0])
    em = N("ShaderNodeEmission")
    em.inputs["Color"].default_value = (1.0, 0.86, 0.6, 1.0)
    em.inputs["Strength"].default_value = 2.5
    tr = N("ShaderNodeBsdfTransparent")
    mix = N("ShaderNodeMixShader")
    L(pw.outputs[0], mix.inputs[0])
    L(tr.outputs[0], mix.inputs[1])
    L(em.outputs[0], mix.inputs[2])
    L(mix.outputs[0], out.inputs["Surface"])
    sprite = stage.link(sc, "Flare", me, m, parent=pivot, loc=p + Vector((0.1, 0, 0)), shadow=False)
    c = sprite.constraints.new("TRACK_TO")
    c.target, c.track_axis, c.up_axis = sc.camera, "TRACK_NEGATIVE_Y", "UP_Z"
    return lamp


def spin(hubs, frames, dist_at):
    for f in frames:
        for key, extra in (("R", 2.2 if 36 < f < 82 else 1.0), ("F", 0.55 if 36 < f < 82 else 1.0)):
            hubs[key].rotation_euler = (0, dist_at(f) * extra / (WHEEL_R * K), 0)
            hubs[key].keyframe_insert("rotation_euler", frame=f)


def animate(root, pivot, hubs):
    dist = {}
    d, prev = 0.0, interp(TRAVEL, 0)
    for f in range(1, TOTAL + 1):
        x = interp(TRAVEL, f)
        d += abs(x - prev) + 0.04
        prev = x
        dist[f] = d
        pitch = interp(WHEELIE, f)
        bounce = 0.0
        if f >= SLAM:
            bounce = 5.0 * math.exp(-(f - SLAM) / 4.0) * math.sin((f - SLAM) * 1.5)
        pivot.rotation_euler = (R(3.0 * math.sin(f / 3.5) * env(f, 36, 44) * (1 - env(f, 74, 84))), R(-pitch - bounce), 0)
        pivot.keyframe_insert("rotation_euler", frame=f)
        root.location = (x, 0.0, GROUND_Z + 0.08 * bounce * (1 if f >= SLAM else 0) + 0.008 * math.sin(f * 2.1))
        root.keyframe_insert("location", frame=f)
    spin(hubs, range(1, TOTAL + 1), lambda f: dist[f])


def effects(sc, pivot):
    p = EXHAUST - CONTACT
    sparks = stage.emit("BikeSparks", (1.0, 0.56, 0.16), 26.0)
    em = fx.particle_burst(sc, "BikeSparks", fx.ring_mesh("SparkR", 0.09, 0.05, 12), sparks, 900, (34, 84), 13, 0.03, 1.4, rand=1.5, align=(-6.0, 0.0, 0.8), gravity=0.5, location=p)
    em.parent = pivot
    fire = stage.emit("Backfire", (1.0, 0.45, 0.08), 22.0)
    for i, frames in enumerate(((36, 39), (52, 54), (70, 72))):
        b = fx.particle_burst(sc, f"Backfire{i}", fx.ring_mesh(f"BackfireR{i}", 0.05, 0.03, 8), fire, 60, frames, 7, 0.09, 0.4, rand=0.5, align=(-4.5, 0.0, 0.2), damping=0.2, location=p)
        b.parent = pivot
    smoke = fx.fade_material("TyreSmoke", (0.8, 0.78, 0.76), 1.2, 0.1, 1.2)
    s = fx.particle_burst(sc, "TyreSmoke", fx.ring_mesh("SmokeR", 0.3, 0.05, 16), smoke, 260, (30, 96), 26, 0.34, 0.5, rand=1.0, align=(-1.8, 0.0, 0.3), damping=0.12, gravity=-0.03, location=(0.0, 0.0, 0.05))
    s.parent = pivot
    return em


def build_show(sc, opts):
    root, pivot, hubs, bike = load(sc)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=1.0, follow=root, lights=0.9, fog=(1.8, 6), streak=6.0, shutter=0.45)
    e = R(5)
    cam.location, cam.rotation_euler = (0.0, -gc.CAM_DIST * math.cos(e), gc.CAM_DIST * math.sin(e)), (R(90) - e, 0, 0)
    sh.shadow_catcher(sc, GROUND_Z, 60)
    headlight(sc, pivot)
    animate(root, pivot, hubs)
    effects(sc, pivot)
    sh.camera_shake(cam, SLAM, 10, amp=0.05, rot_deg=0.3, seed=8)
    sh.screen_extent(sc, cam, bike, (1, 28, 45, 70, 90, TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Held wheelie, wheels turning a whole number of times, sparks steady."""
    root, pivot, hubs, bike = load(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=1.0, follow=root, lights=0.9, fog=(1.8, 6), streak=6.0)
    root.location = (0, 0, 0)
    headlight(sc, pivot)
    n = stage.ICON_N
    for f in range(0, n + 1):
        w = 2 * math.pi * f / n
        pivot.rotation_euler = (R(2.5 * math.sin(w)), R(-32.0 - 4.0 * math.sin(w)), 0)
        pivot.keyframe_insert("rotation_euler", frame=f)
        hubs["R"].rotation_euler = (0, 8 * w, 0)
        hubs["R"].keyframe_insert("rotation_euler", frame=f)
        hubs["F"].rotation_euler = (0, 3 * w, 0)
        hubs["F"].keyframe_insert("rotation_euler", frame=f)
    sc.frame_set(1)
    stage.frame_icon(cam, bike, pad=1.12)
    sparks = stage.emit("BikeSparks", (1.0, 0.56, 0.16), 26.0)
    em = fx.particle_burst(sc, "BikeSparks", fx.ring_mesh("SparkR", 0.09, 0.05, 12), sparks, 220, (-20, n), 13, 0.024, 1.2, rand=1.5, align=(-6.0, 0.0, 0.8), gravity=0.5, location=EXHAUST - CONTACT)
    em.parent = pivot
    stage.bake_all(sc)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
