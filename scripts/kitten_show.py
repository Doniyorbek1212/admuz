"""UZARO v2 show: kitten (tier 1, 96 f = 4 s).

A fluffy ginger kitten trots in from the left, turns to camera and sits, licks a raised paw (tongue out, eyes shut),
looks up, blinks, tail curling. Rig: autorig on the bind pose; fur: particle hair; blink and tongue: shape keys.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import animal  # noqa: E402
import autorig  # noqa: E402
import gift_common as gc  # noqa: E402
import quadruped as qp  # noqa: E402
import show_common as sh  # noqa: E402
import stage  # noqa: E402
from stage import R, env, interp  # noqa: E402

ID = "kitten"
TOTAL = 96
SIZE = 6.0
K = 1.0
GROUND_Z = -3.2
PAW_Z = -2.68
X, Y, Z = animal.X, animal.Y, animal.Z
GAIT = qp.Gait(cycle_dist=2.4, duty=0.55, lift=0.28, bob=0.05, hind_flex=25.0, fore_flex=35.0)
TRAVEL = [(1, -9.6), (34, -0.9), (46, 0.0)]
HEADING = [(1, 62.0), (40, 62.0), (54, 14.0)]
SIT = (42, 54)
LICK = (56, 80)
BLINKS = (86,)
LID_OUT, LID_SCALE, LID_UP = 0.05, 1.14, 0.03
JOINTS = {
    "spine": [(0, 1.3, -1.3), (0, 0.2, -1.3), (0, -0.75, -1.2)],
    "neck": [(0, -0.75, -1.2), (0, -0.85, -0.85)],
    "head": [(0, -0.85, -0.85), (0, -0.7, 2.2)],
    "ear": [(1.15, -1.1, 1.75), (2.15, -1.8, 2.75)],
    "tail": [(0, 1.45, -0.95), (0, 1.85, -0.4), (0, 2.25, 0.1), (0, 2.7, 0.55)],
    "hind": [(0.75, 1.05, -1.4), (0.75, 1.2, -1.75), (0.78, 1.35, -2.1), (0.8, 1.3, -2.45), (0.8, 1.15, -2.68)],
    "fore": [(0.75, -0.75, -1.35), (0.72, -0.72, -1.75), (0.78, -0.72, -2.1), (0.8, -0.72, -2.45), (0.8, -0.85, -2.68)],
}
EYE_Z = 0.55
EYE_TOP = 1.02


def limits():
    lim = animal.side_limits(JOINTS)
    above = lambda z: (lambda c: (c[:, 2] > z) * 1.0)
    below = lambda z: (lambda c: (c[:, 2] < z) * 1.0)
    lim.update({"head": above(-1.1), "neck0": above(-1.25), "spine0": below(-0.55), "spine1": below(-0.55)})
    for i in range(3):
        lim[f"tail{i}"] = lambda c: ((c[:, 1] > 1.2) & (c[:, 2] > -1.3)) * 1.0
    for side, s in (("earL0", 1.0), ("earR0", -1.0)):
        lim[side] = lambda c, s=s: ((c[:, 0] * s > 1.15) & (c[:, 2] > 1.5)) * 1.0
    for leg in ("LB", "RB", "LF", "RF"):
        for i in range(4):
            prev = lim[f"{leg}{i}"]
            lim[f"{leg}{i}"] = lambda c, p=prev: p(c) * (c[:, 2] < -1.25)
    return lim


def tongue_mesh():
    """Pink tongue below the nose: basis inside the head, shape key "Out" licks forward."""
    me = bpy.data.meshes.new("Tongue")
    bm_verts, faces = [], []
    n, rows = 8, 6
    for i in range(rows):
        t = i / (rows - 1)
        w = 0.17 * math.sqrt(max(0.0, 1 - t ** 3))
        for k in range(n):
            a = 2 * math.pi * k / n
            bm_verts.append((w * math.cos(a), -2.05 - 0.04 * t, -0.28 - 0.02 * t + 0.03 * math.sin(a)))
    for i in range(rows - 1):
        for k in range(n):
            j = (k + 1) % n
            faces.append((i * n + k, i * n + j, (i + 1) * n + j, (i + 1) * n + k))
    me.from_pydata(bm_verts, [], faces)
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    me.update()
    return me


def add_tongue(sc, arm):
    ob = stage.link(sc, "Tongue", tongue_mesh(), stage.pbr("Tongue", (0.95, 0.32, 0.38), roughness=0.3, coat=0.4))
    ob.parent = arm
    ob.vertex_groups.new(name="head").add(list(range(len(ob.data.vertices))), 1.0, "REPLACE")
    ob.modifiers.new("Rig", "ARMATURE").object = arm
    ob.shape_key_add(name="Basis")
    out = ob.shape_key_add(name="Out")
    for i, v in enumerate(ob.data.vertices):
        t = (i // 8) / 5
        out.data[i].co = (v.co.x, v.co.y - 0.1 - 0.55 * t, v.co.z - 0.12 - 0.22 * t)
    return out


def eye_dome(name, verts):
    """Convex hull of one eye: a seamless lid. Copies of the iris and pupil meshes showed their rim, like goggles."""
    bm = bmesh.new()
    for co in verts:
        bm.verts.new(co)
    hull = bmesh.ops.convex_hull(bm, input=bm.verts)
    bmesh.ops.delete(bm, geom=list(set(hull["geom_interior"] + hull["geom_unused"])), context="VERTS")
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    return me


def add_blink(sc, arm, meshes):
    """Eyelids: a fur-coloured dome over each eye, pushed out a little. Basis folds it up under the brow, "Blink" covers the eye."""
    keys = []
    skin = stage.pbr("Eyelid", (0.3, 0.07, 0.008), roughness=0.75)
    eye_verts = [v.co.copy() for m in meshes if m.data.materials[0].name.split(".")[0] in ("EyeColor", "Pupil") for v in m.data.vertices]
    for n, side in enumerate((1, -1)):
        me = eye_dome(f"Eyelid{n}", [c for c in eye_verts if c.x * side > 0])
        lid = stage.link(sc, f"Eyelid{n}", me, skin, parent=arm)
        lid.vertex_groups.new(name="head").add(list(range(len(me.vertices))), 1.0, "REPLACE")
        lid.modifiers.new("Rig", "ARMATURE").object = arm
        mid = sum((v.co for v in me.vertices), Vector()) / len(me.vertices)
        closed = [(mid.x + (v.co.x - mid.x) * LID_SCALE, v.co.y - LID_OUT, mid.z + (v.co.z - mid.z) * LID_SCALE + LID_UP) for v in me.vertices]
        for v in me.vertices:
            v.co.z = EYE_TOP + 0.02 * (v.co.z - EYE_Z)
            v.co.y += 0.2
        lid.shape_key_add(name="Basis")
        key = lid.shape_key_add(name="Blink")
        for i, c in enumerate(closed):
            key.data[i].co = c
        keys.append(key)
    return keys


def face_mask(m):
    """No fur over the eyes, short sparse fur around the nose: the face must read."""
    vg = m.vertex_groups.new(name="FurMask")
    for v in m.data.vertices:
        p = v.co
        eye = min(((p.x - s * 0.62) ** 2 + (p.z - EYE_Z) ** 2) ** 0.5 for s in (1, -1))
        weight = 0.0 if p.y < -1.1 and eye < 0.62 else 1.0
        vg.add([v.index], weight, "REPLACE")
    return vg.name


def blink_value(f, licking=True):
    v = 0.0
    if licking:
        v = max(v, env(f, LICK[0] + 2, LICK[0] + 5) * (1 - env(f, LICK[1] - 3, LICK[1])))
    for b in BLINKS:
        v = max(v, env(f, b, b + 2) * (1 - env(f, b + 2, b + 5)))
    return v


def load(sc):
    root, model, objs, meshes = stage.load(ID, SIZE, strip_rig=True)
    palette = {"MainColor": (0.42, 0.11, 0.012), "DarkerColor": (0.16, 0.03, 0.004), "Pupil": (0.005, 0.005, 0.008), "EyeColor": (0.13, 0.42, 0.16)}
    for m in meshes:
        mat = m.data.materials[0]
        base = mat.name.split(".")[0]
        if base in palette:
            stage.bsdf(mat).inputs["Base Color"].default_value = (*palette[base], 1.0)
        if base in ("MainColor", "DarkerColor"):
            stage.shiny(mat, roughness=0.8, sheen=0.6)
        if base == "Glass":
            m.hide_render = True    # its flat pale layer washes the eye out; the eye gets a glossy coat instead
        if base == "EyeColor":
            stage.shiny(mat, roughness=0.06, coat=1.0)
        if base == "Pupil":     # a coat mirrors the bright sky and turns it grey
            stage.bsdf(mat).inputs["Specular IOR Level"].default_value = 0.05
    bpy.context.view_layer.update()
    arm_meshes = [m for m in meshes if not m.hide_render]
    autorig.bake_world(arm_meshes)
    for m in arm_meshes:
        stage.weld(m)
        stage.apply_modifier(m, "SUBSURF", levels=2, render_levels=2)
        m.data.polygons.foreach_set("use_smooth", [True] * len(m.data.polygons))
    animal_arm = animal.build(sc, "Kitten", JOINTS, arm_meshes, power=8.0, limits=limits())
    wrap = bpy.data.objects.new("Heading", None)
    sc.collection.objects.link(wrap)
    wrap.parent = root
    animal_arm.parent = wrap
    root.scale = (K, K, K)
    for m in arm_meshes:
        base = m.data.materials[0].name.split(".")[0]
        if base == "MainColor":
            animal.fur(m, 0.17, count=9000, children=40, radius=0.012, seed=3, clump=0.25, density_vg=face_mask(m))
        elif base == "DarkerColor":
            animal.fur(m, 0.15, count=2600, children=40, radius=0.012, seed=5, clump=0.25, density_vg=face_mask(m))
    return root, wrap, animal_arm, arm_meshes


def paw_to_mouth(mover, f, lick, stroke):
    """The chibi head is far wider than the stub legs reach: swing the foreleg forward as a whole and stretch it, cartoon style."""
    mover.body(f, {"RF0": (X, (-108.0 - 8.0 * stroke) * lick) if lick > 0.001 else (X, 0.0), "RF1": (X, 0.0), "RF2": (X, 0.0), "RF3": (X, 0.0)})
    pb = mover.arm.pose.bones["RF0"]
    s = 1.0 + 0.3 * lick
    pb.scale = (1.0 + 0.1 * lick, s, 1.0 + 0.1 * lick)
    pb.keyframe_insert("scale", frame=f)


def animate(sc, arm, root, wrap, mover, meshes, tongue):
    blink_keys = add_blink(sc, arm, meshes)
    dist, prev = 0.0, interp(TRAVEL, 0)
    bobs = {}
    for f in range(1, TOTAL + 1):
        x = interp(TRAVEL, f)
        dist += abs(x - prev) / K
        prev = x
        amp = 1 - env(f, 34, 46)
        bobs[f] = mover.legs_at(f, dist, amp)
        sit = env(f, *SIT)
        lick = env(f, LICK[0], LICK[0] + 6) * (1 - env(f, LICK[1] - 4, LICK[1] + 2))
        stroke = 0.5 + 0.5 * math.sin((f - LICK[0]) * 2 * math.pi / 8.0)
        look = env(f, LICK[1], LICK[1] + 6)
        c = math.cos(2 * math.pi * dist / GAIT.cycle_dist)
        swish = math.sin(f / 4.5)
        mover.body(f, {
            "root": (X, -12.0 * sit),
            "spine0": [(X, 1.5 * amp * c), (Y, 3.0 * amp * math.sin(2 * math.pi * dist / GAIT.cycle_dist))],
            "neck0": (X, 6.0 * sit + 4.0 * lick),
            "head": [(Z, -22.0 * amp + 4.0 * look * math.sin(f / 7.0)), (X, 2.0 * sit - 3.0 * amp * c + (6.0 + 6.0 * stroke) * lick - 5.0 * look), (Y, -8.0 * lick + 7.0 * look)],
            "earL0": (X, 8.0 * amp * c + 5.0 * lick * stroke),
            "earR0": (X, -8.0 * amp * c + 5.0 * lick * stroke),
            "tail0": [(Z, 22.0 * sit + 10.0 * swish), (X, -18.0 * sit + 8.0 * amp)],
            "tail1": [(X, 26.0 * sit + 6.0 * amp), (Z, 14.0 * sit + 12.0 * math.sin(f / 4.5 - 0.8))],
            "tail2": [(X, 48.0 * sit + 12.0 * amp), (Z, 16.0 * math.sin(f / 4.5 - 1.6))],
        })
        if lick > 0.001:
            paw_to_mouth(mover, f, lick, stroke)
        tongue.value = lick * (0.35 + 0.65 * stroke)
        tongue.keyframe_insert("value", frame=f)
        for key in blink_keys:
            key.value = blink_value(f)
            key.keyframe_insert("value", frame=f)
        wrap.rotation_euler = (0, 0, R(interp(HEADING, f)))
        wrap.keyframe_insert("rotation_euler", frame=f)
        root.location = (x, 0.0, GROUND_Z - PAW_Z * K + bobs[f] * K - 0.22 * sit)
        root.keyframe_insert("location", frame=f)


def stage_common(cam):
    e = R(5)
    cam.location, cam.rotation_euler = (0.0, -gc.CAM_DIST * math.cos(e), gc.CAM_DIST * math.sin(e)), (R(90) - e, 0, 0)


def build_show(sc, opts):
    root, wrap, arm, meshes = load(sc)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=1.0, follow=root, lights=0.9, fog=(1.8, 5), streak=9.0)
    stage_common(cam)
    sh.shadow_catcher(sc, GROUND_Z, 50)
    mover = animal.Mover(arm, GAIT, animal.TROT_PHASES)
    tongue = add_tongue(sc, arm)
    animate(sc, arm, root, wrap, mover, meshes, tongue)
    sh.screen_extent(sc, cam, meshes, (1, 40, 56, 90))
    sc.frame_set(68)
    dg = bpy.context.evaluated_depsgraph_get()
    for m in meshes:
        groups = {g.index: g.name for g in m.vertex_groups}
        me = m.evaluated_get(dg).to_mesh()
        rows = {}
        for v, ev in zip(m.data.vertices, me.vertices):
            for g in v.groups:
                if groups.get(g.group, "").startswith("RF") and g.weight > 0.3:
                    rows.setdefault(groups[g.group], []).append(m.matrix_world @ ev.co)
        print("INFO_PAWMESH", m.name, m.data.materials[0].name, {k: (len(p), round(min(q.y for q in p), 2), round(max(q.z for q in p), 2)) for k, p in rows.items()})
        m.evaluated_get(dg).to_mesh_clear()
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Sitting and licking its paw: stroke and tail on integer harmonics of the loop."""
    root, wrap, arm, meshes = load(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=1.0, follow=root, lights=0.9, fog=(1.8, 5), streak=9.0)
    mover = animal.Mover(arm, GAIT, animal.TROT_PHASES)
    tongue = add_tongue(sc, arm)
    blink = add_blink(sc, arm, meshes)
    wrap.rotation_euler = (0, 0, R(14))
    root.location = (0, 0, GROUND_Z - PAW_Z * K - 0.22)
    n = stage.ICON_N
    for f in range(0, n + 1):
        w = 2 * math.pi * f / n
        stroke = 0.5 + 0.5 * math.sin(3 * w)
        mover.legs_at(f, 0.0, 0.0)
        paw_to_mouth(mover, f, 1.0, stroke)
        mover.body(f, {
            "root": (X, -12.0), "neck0": (X, 10.0),
            "head": [(X, 8.0 + 6.0 * stroke), (Y, -8.0)],
            "earL0": (X, 5.0 * stroke), "earR0": (X, 5.0 * stroke),
            "tail0": [(Z, 22.0 + 8.0 * math.sin(w)), (X, -18.0)],
            "tail1": [(X, 26.0), (Z, 14.0 + 10.0 * math.sin(w - 0.8))],
            "tail2": [(X, 48.0), (Z, 14.0 * math.sin(w - 1.6))],
        })
        tongue.value = 0.35 + 0.65 * stroke
        tongue.keyframe_insert("value", frame=f)
        for key in blink:
            key.value = 1.0
            key.keyframe_insert("value", frame=f)
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.14)
    stage.bake_all(sc)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
