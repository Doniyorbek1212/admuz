"""Armature for an imported static mesh: bones placed by hand, smooth skin weights computed from bone distance.

Works on any mesh soup (no manifold requirement, unlike bone heat). Bones are given in world space at rest, meshes
get their world transform baked so armature and mesh share one space under a single parent. `Pose` keys bone
rotations about axes given in rest-armature space, so bone rolls never matter.
"""
import numpy as np
import bpy
from mathutils import Quaternion, Vector


def bake_world(meshes):
    """Each mesh gets its own data with the world matrix applied, then identity transform and no parent."""
    bpy.context.view_layer.update()
    for o in meshes:
        mw = o.matrix_world.copy()
        o.data = o.data.copy()
        o.data.transform(mw)
        o.parent = None
        o.matrix_world = type(mw).Identity(4)


def add_rig(sc, name, bones, meshes, power=6.0, floor=0.02, limits=None):
    """bones: [(name, parent or None, head, tail)] in world space. limits: {bone: fn(world_xyz array) -> 0..1 mask}."""
    arm_data = bpy.data.armatures.new(name)
    arm = bpy.data.objects.new(name, arm_data)
    sc.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    with bpy.context.temp_override(active_object=arm, object=arm, selected_objects=[arm]):
        bpy.ops.object.mode_set(mode="EDIT")
        ebs = {}
        for bname, parent, head, tail in bones:
            eb = arm_data.edit_bones.new(bname)
            eb.head, eb.tail = head, tail
            if parent:
                eb.parent = ebs[parent]
            ebs[bname] = eb
        bpy.ops.object.mode_set(mode="OBJECT")
    heads = np.array([b[2] for b in bones], dtype=np.float64)
    tails = np.array([b[3] for b in bones], dtype=np.float64)
    seg = tails - heads
    seg2 = (seg * seg).sum(axis=1)
    for o in meshes:
        n = len(o.data.vertices)
        co = np.empty(n * 3, dtype=np.float64)
        o.data.vertices.foreach_get("co", co)
        co = co.reshape(-1, 3)
        rel = co[:, None, :] - heads[None, :, :]
        t = np.clip((rel * seg[None, :, :]).sum(axis=2) / seg2[None, :], 0.0, 1.0)
        d = np.linalg.norm(rel - t[:, :, None] * seg[None, :, :], axis=2)
        w = 1.0 / np.maximum(d, 1e-4) ** power
        if limits:
            for i, b in enumerate(bones):
                if b[0] in limits:
                    w[:, i] *= limits[b[0]](co)
        w /= w.sum(axis=1, keepdims=True)
        top = np.argsort(-w, axis=1)[:, :4]
        o.vertex_groups.clear()      # a file's own skin groups would shift the indices used below
        for i, b in enumerate(bones):
            o.vertex_groups.new(name=b[0])
        for vi in range(n):
            keep = [(int(j), float(w[vi, j])) for j in top[vi] if w[vi, j] > floor]
            total = sum(x for _, x in keep) or 1.0
            for j, x in keep:
                o.vertex_groups[j].add([vi], x / total, "REPLACE")
        o.parent = arm
        o.modifiers.new("Rig", "ARMATURE").object = arm
    for pb in arm.pose.bones:
        pb.rotation_mode = "QUATERNION"
    return arm


class Pose:
    """pose.key(f, {"neck": ((1, 0, 0), 20.0), ...}): rotation about a rest-armature axis, degrees.
    A value may be a list of (axis, deg) composed in order. Bones not named keep their previous key."""

    def __init__(self, arm):
        self.arm = arm
        self.local = {b.name: b.matrix_local.to_3x3().inverted() for b in arm.data.bones}

    def quat(self, bone, spec):
        q = Quaternion()
        for axis, deg in (spec if isinstance(spec, list) else [spec]):
            q = q @ Quaternion((self.local[bone] @ Vector(axis)).normalized(), np.radians(deg))
        return q

    def key(self, frame, spec):
        for bone, s in spec.items():
            pb = self.arm.pose.bones[bone]
            pb.rotation_quaternion = self.quat(bone, s)
            pb.keyframe_insert("rotation_quaternion", frame=frame)


def chain(prefix, points, parent=None):
    """Bones along a polyline: prefix0, prefix1, ... each parented to the one before."""
    out = []
    for i, (a, b) in enumerate(zip(points, points[1:])):
        out.append((f"{prefix}{i}", parent if i == 0 else f"{prefix}{i - 1}", a, b))
    return out
