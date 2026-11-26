"""Shows built from a model's own animation takes: load, sequence takes on NLA tracks, move the root along the ground.

A plan is a list of Take(action prefix, start frame, (first, last) take frames, repeat, blend, reverse); each take gets
its own NLA track so neighbouring takes cross-fade. The root walks along a heading at a speed that each take sets
(0 for a take played in place), measured from a planted foot for walk takes.
"""
import math
import os
import statistics
from dataclasses import dataclass

import bpy
from mathutils import Quaternion, Vector

import gift_common as gc


@dataclass(frozen=True)
class Take:
    action: str                  # action name prefix
    start: float                 # scene frame the strip starts
    frames: tuple = None         # (first, last) frames of the action; None = its whole range
    repeat: float = 1.0
    blend: float = 6.0
    speed: float = 0.0           # root travel per frame while this take is fully in
    reverse: bool = False

    def length(self, act):
        a, b = self.frames or act.frame_range
        return (b - a) * self.repeat


def load(gift_id, size, rot=(0.0, 0.0, 0.0), hide=("Icosphere",)):
    objs = gc.import_glb(os.path.join(gc.MODELS, f"{gift_id}.glb"), hide=hide)
    objs = [o for o in objs if not any(h in o.name for h in hide)]
    root, _ = gc.normalize(objs, size, rot=rot, name=gift_id)
    arm = next((o for o in objs if o.type == "ARMATURE"), None)
    meshes = [o for o in objs if o.type == "MESH"]
    return root, arm, meshes


def action(prefix):
    return next(a for a in bpy.data.actions if a.name.startswith(prefix))


def foot_speed(sc, arm, prefix, bone, frames=None):
    """World units per frame the planted `bone` slides back in an in-place take: the walk speed that keeps it planted."""
    ad = arm.animation_data or arm.animation_data_create()
    act = action(prefix)
    ad.action = act
    lo, hi = map(int, frames or act.frame_range)
    pts = []
    for f in range(lo, hi + 1):
        sc.frame_set(f)
        pts.append((arm.matrix_world @ arm.pose.bones[bone].head).copy())
    ad.action = None
    floor = min(p.z for p in pts)
    span = max(p.z for p in pts) - floor
    low = [p for p in pts]
    steps = [(b - a).xy.length for a, b in zip(low, low[1:]) if a.z < floor + 0.1 * span and b.z < floor + 0.1 * span]
    v = statistics.median(steps) if steps else 0.0
    print("FOOT SPEED", prefix, round(v, 4), "per frame,", len(steps), "stance samples over", hi - lo, "frames")
    return v


def sequence(arm, plan):
    """One NLA track per take, in plan order (later tracks on top). Returns [(take, strip)]."""
    ad = arm.animation_data or arm.animation_data_create()
    ad.action = None
    for tr in ad.nla_tracks:        # the importer stacks every take on its own track; only ours may play
        tr.mute = True
    out = []
    for i, tk in enumerate(plan):
        act = action(tk.action)
        tr = ad.nla_tracks.new()
        tr.name = f"T{i}_{tk.action}"
        s = tr.strips.new(tr.name, int(tk.start), act)
        if tk.frames:
            s.action_frame_start, s.action_frame_end = tk.frames
        s.repeat = tk.repeat
        s.frame_end = tk.start + tk.length(act)
        s.use_reverse = tk.reverse
        s.blend_in = s.blend_out = tk.blend if i else 0.0
        if i == len(plan) - 1:
            s.blend_out = 0.0
        s.extrapolation = "HOLD" if i == 0 else ("HOLD_FORWARD" if i == len(plan) - 1 else "NOTHING")
        s.blend_type = "REPLACE"
        out.append((tk, s))
    return out


def weight(f, strip):
    if f < strip.frame_start or f > strip.frame_end:
        return 0.0
    w = 1.0
    if strip.blend_in:
        w = min(w, (f - strip.frame_start) / strip.blend_in)
    if strip.blend_out:
        w = min(w, (strip.frame_end - f) / strip.blend_out)
    return max(0.0, w)


def speed_at(f, seq):
    """Top-most take wins by its blend weight, as REPLACE strips stack."""
    v = 0.0
    for tk, s in seq:
        w = weight(f, s) if s.blend_in or s.blend_out else (1.0 if s.frame_start <= f <= s.frame_end else 0.0)
        v = v * (1 - w) + tk.speed * w
    return v


def travel(root, total, yaw, seq, anchor_frame, anchor):
    """Key the root along the heading (model nose at -Y turned by yaw) so it sits at `anchor` (x, y) on anchor_frame."""
    d = Vector((math.sin(yaw), -math.cos(yaw), 0.0))
    dist, acc = {}, 0.0
    for f in range(1, total + 1):
        dist[f] = acc
        acc += speed_at(f + 0.5, seq)
    root.rotation_euler = (0.0, 0.0, yaw)
    z = root.location.z
    for f in range(1, total + 1):
        p = Vector((anchor[0], anchor[1], 0.0)) + d * (dist[f] - dist[anchor_frame])
        root.location = (p.x, p.y, z)
        root.keyframe_insert("location", frame=f)
    return d


def lift_to(sc, root, meshes, ground_z, frame):
    """Shift every root location key so the lowest vertex sits on ground_z at `frame` (evaluated, posed meshes)."""
    sc.frame_set(frame)
    dg = bpy.context.evaluated_depsgraph_get()
    lo = min((m.evaluated_get(dg).matrix_world @ v.co).z for m in meshes for v in m.evaluated_get(dg).data.vertices)
    dz = ground_z - lo
    if root.animation_data and root.animation_data.action:
        for fc in root.animation_data.action.fcurves:
            if fc.data_path == "location" and fc.array_index == 2:
                for kp in fc.keyframe_points:
                    kp.co.y += dz
                    kp.handle_left.y += dz
                    kp.handle_right.y += dz
    else:
        root.location.z += dz
    return dz


def overlay(arm, name, keys):
    """Hand-keyed bone turns on top of the NLA (COMBINE: quaternions multiply onto the takes).
    keys: {bone: [(frame, axis "X"/"Y"/"Z", degrees), ...]} in the bone's local space."""
    ad = arm.animation_data or arm.animation_data_create()
    act = bpy.data.actions.new(name)
    ad.action = act
    ad.action_blend_type = "COMBINE"
    for bone, items in keys.items():
        pb = arm.pose.bones[bone]
        pb.rotation_mode = "QUATERNION"
        for f, axis, deg in items:
            pb.rotation_quaternion = Quaternion(Vector({"X": (1, 0, 0), "Y": (0, 1, 0), "Z": (0, 0, 1)}[axis]), math.radians(deg))
            pb.keyframe_insert("rotation_quaternion", frame=f)
    return act


def blink(bones, frames, deg=38.0, axis="X"):
    """Overlay keys that shut the upper lids for 4 frames at each frame in `frames`."""
    out = {}
    for b in bones:
        ks = []
        for f in frames:
            ks += [(f - 1, axis, 0.0), (f + 1, axis, deg), (f + 2, axis, deg), (f + 4, axis, 0.0)]
        out[b] = ks
    return out


def stance_speed(sc, arm, bone, frames):
    """Like foot_speed, but samples whatever the rig plays now (NLA plus overlay) over `frames`."""
    pts = []
    for f in range(frames[0], frames[1] + 1):
        sc.frame_set(f)
        pts.append((arm.matrix_world @ arm.pose.bones[bone].head).copy())
    floor = min(p.z for p in pts)
    span = max(p.z for p in pts) - floor
    steps = [(b - a).xy.length for a, b in zip(pts, pts[1:]) if a.z < floor + 0.1 * span and b.z < floor + 0.1 * span]
    v = statistics.median(steps) if steps else 0.0
    print("STANCE SPEED", bone, round(v, 4), "per frame,", len(steps), "samples")
    return v


def drape(sc, arm, body, back, front, mat, name="Blanket", reach=math.radians(100), offset=0.03, drop=0.1, nu=18, nw=26):
    """A cloth laid over the back: rays at the line back->front (world points, rest pose) from a fan across the body;
    hit + offset, hems dropped a little, UV u along the body, w hem to hem; skinned with the body's nearest weights."""
    from mathutils.bvhtree import BVHTree
    arm.data.pose_position = "REST"
    bpy.context.view_layer.update()
    mw = body.matrix_world
    bvh = BVHTree.FromPolygons([mw @ v.co for v in body.data.vertices], [p.vertices[:] for p in body.data.polygons])
    up = Vector((0.0, 0.0, 1.0))
    side = (front - back).cross(up).normalized()
    rows = []
    for i in range(nu + 1):
        c = back.lerp(front, i / nu)
        row = []
        for j in range(nw + 1):
            a = -reach + 2 * reach * j / nw
            out = side * math.sin(a) + up * math.cos(a)
            hit = bvh.ray_cast(c + out * 3.0, -out)
            p = hit[0] if hit[0] is not None else c + out * 0.3
            row.append(p + out * offset)
        row[0] += up * -drop
        row[-1] += up * -drop
        rows.append(row)
    verts = [tuple(p) for row in rows for p in row]
    faces = [(i * (nw + 1) + j, i * (nw + 1) + j + 1, (i + 1) * (nw + 1) + j + 1, (i + 1) * (nw + 1) + j) for i in range(nu) for j in range(nw)]
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    uvl = me.uv_layers.new()
    for poly in me.polygons:
        for li, vi in zip(poly.loop_indices, poly.vertices):
            uvl.data[li].uv = ((vi // (nw + 1)) / nu, (vi % (nw + 1)) / nw)
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    ob = bpy.data.objects.new(name, me)
    sc.collection.objects.link(ob)
    me.materials.append(mat)
    sol = ob.modifiers.new("Thick", "SOLIDIFY")
    sol.thickness, sol.offset = 0.012, -1.0
    _skin_like(ob, body, arm)
    arm.data.pose_position = "POSE"
    return ob


def _skin_like(ob, body, arm):
    from mathutils import kdtree
    mw = body.matrix_world
    kd = kdtree.KDTree(len(body.data.vertices))
    for v in body.data.vertices:
        kd.insert(mw @ v.co, v.index)
    kd.balance()
    names = {g.index: g.name for g in body.vertex_groups}
    groups = {}
    for v in ob.data.vertices:
        _, idx, _ = kd.find(v.co)
        for g in body.data.vertices[idx].groups:
            name = names[g.group]
            if name not in groups:
                groups[name] = ob.vertex_groups.new(name=name)
            groups[name].add([v.index], g.weight, "REPLACE")
    ob.data.transform(arm.matrix_world.inverted())
    ob.parent = arm
    ob.modifiers.new("Rig", "ARMATURE").object = arm
    bpy.context.view_layer.update()
