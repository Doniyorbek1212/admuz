"""UZARO v2 show: camel (tier 2, 120 f = 5 s).

A Bactrian camel walks across with a camel's pacing gait (both legs on one side swing together), an original woven
saddle blanket between its humps and a brass bell swinging under its neck; sand dust puffs where the feet land.
The model has only an idle take: it plays underneath for breathing and ear flicks, and the pace is hand-keyed on the
leg bones and combined on top. The walk speed is measured from a planted forefoot so the feet do not slide.
"""
import math
import os
import sys
from dataclasses import replace

import bpy
from mathutils import Matrix

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import clipshow as cs  # noqa: E402
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R  # noqa: E402

ID = "camel"
TOTAL = 120
SIZE = 5.0
GROUND_Z = -3.4
YAW = R(68)                                    # head (-Y) turned to walk right and a little toward the lens
CYCLE = 36                                     # frames per full stride
SWING, FLEX = 12.0, 30.0                       # upper-leg swing amplitude and lower-leg fold in the swing phase (deg)
LEGS = {  # side +1 = left (local Z = +X world, +deg swings the foot back), -1 = right; phase 0 = left pair
    "L": (1, 0.0, ("Shoulder_L_31_35", "Wrist_L_29_37"), ("Hip_L_49_50", "Ankle_L_47_52")),
    "R": (-1, math.pi, ("Shoulder_R_39_43", "Wrist_R_37_45"), ("Hip_R_8_9", "Ankle_R_6_11")),
}
FEET = ("Fingers1_L_28_38", "Fingers1_R_36_46", "Toes1_L_46_53", "Toes1_R_5_12")
NECK = "Neck2_M_22_20"
WOOL = [(0.55, 0.12, 0.08), (0.92, 0.7, 0.32), (0.1, 0.14, 0.35), (0.85, 0.82, 0.72)]   # madder, ochre, indigo, natural


def pace_keys(frames):
    """Pacing: the two legs of a side move together, the sides half a cycle apart. Upper bone swings fore/aft;
    the lower joint folds the hoof up only while the leg swings forward."""
    keys = {}
    for side, phase, fore, hind in LEGS.values():
        for upper, lower in (fore, hind):
            up, lo = [], []
            for f in range(frames[0], frames[1] + 1, 2):
                p = 2 * math.pi * f / CYCLE + phase
                up.append((f, "Z", side * SWING * math.sin(p)))
                lift = max(0.0, -math.cos(p))                # cos < 0: the foot travels forward
                lo.append((f, "Z", side * FLEX * lift ** 1.5))
            keys[upper], keys[lower] = up, lo
    keys[NECK] = [(f, "Z", 4.0 * math.sin(4 * math.pi * f / CYCLE)) for f in range(frames[0], frames[1] + 1, 3)]
    return keys


def blanket_material():
    """Original kilim-style weave: bands of madder, ochre and indigo with a row of stepped diamonds
    down each flank."""
    m = stage.pbr("Blanket", WOOL[0], roughness=0.85)
    b = stage.bsdf(m)
    b.inputs["Sheen Weight"].default_value = 0.6
    nt = m.node_tree
    N, L = nt.nodes.new, nt.links.new
    uv, sep = N("ShaderNodeUVMap"), N("ShaderNodeSeparateXYZ")
    L(uv.outputs[0], sep.inputs[0])
    ramp = N("ShaderNodeValToRGB")                    # stripes across w (hem to hem)
    ramp.color_ramp.interpolation = "CONSTANT"
    el = ramp.color_ramp.elements
    stops = [(0.0, 2), (0.08, 1), (0.14, 0), (0.3, 3), (0.36, 2), (0.64, 3), (0.7, 0), (0.86, 1), (0.92, 2)]
    el[0].position, el[0].color = stops[0][0], (*WOOL[stops[0][1]], 1)
    el[1].position, el[1].color = stops[1][0], (*WOOL[stops[1][1]], 1)
    for pos, k in stops[2:]:
        e = el.new(pos)
        e.color = (*WOOL[k], 1)
    L(sep.outputs["Y"], ramp.inputs["Fac"])
    # stepped diamonds on each flank band (|w - 0.5| near 0.27), in cells along u, quantised to steps
    def mnode(op, a, bb=None):
        n = N("ShaderNodeMath")
        n.operation = op
        for i, x in enumerate((a, bb)):
            if x is None:
                continue
            if isinstance(x, (int, float)):
                n.inputs[i].default_value = x
            else:
                L(x, n.inputs[i])
        return n.outputs[0]
    cu = mnode("SUBTRACT", mnode("FRACT", mnode("MULTIPLY", sep.outputs["X"], 5.0)), 0.5)
    cw = mnode("MULTIPLY", mnode("SUBTRACT", mnode("ABSOLUTE", mnode("SUBTRACT", sep.outputs["Y"], 0.5)), 0.27), 3.6)
    d = mnode("ADD", mnode("ABSOLUTE", cu), mnode("ABSOLUTE", cw))
    stepped = mnode("SNAP", d, 0.1)
    diamond = mnode("LESS_THAN", stepped, 0.35)
    core = mnode("LESS_THAN", stepped, 0.15)
    mix1 = N("ShaderNodeMixRGB")
    L(diamond, mix1.inputs["Fac"])
    L(ramp.outputs["Color"], mix1.inputs["Color1"])
    mix1.inputs["Color2"].default_value = (*WOOL[2], 1)
    mix2 = N("ShaderNodeMixRGB")
    L(core, mix2.inputs["Fac"])
    L(mix1.outputs["Color"], mix2.inputs["Color1"])
    mix2.inputs["Color2"].default_value = (*WOOL[1], 1)
    L(mix2.outputs["Color"], b.inputs["Base Color"])
    weave = N("ShaderNodeTexWave")
    weave.inputs["Scale"].default_value = 160.0
    bump = N("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.25
    L(weave.outputs["Fac"], bump.inputs["Height"])
    L(bump.outputs[0], b.inputs["Normal"])
    return m


def bell(sc, arm, body):
    """Brass bell under the throat, parented to the neck bone; it swings fore and aft a beat behind the stride.
    Call in rest placement (before travel) so the pivot's axes are the camel's own: X is across the body."""
    brass = stage.pbr("Brass", (0.95, 0.7, 0.32), metallic=1.0, roughness=0.25)
    sc.frame_set(1)
    head = arm.matrix_world @ arm.pose.bones[NECK].head
    dg = bpy.context.evaluated_depsgraph_get()
    ev = body.evaluated_get(dg)
    near = [ev.matrix_world @ v.co for v in ev.data.vertices]
    near = [p for p in near if (p.xy - head.xy).length < 0.3 and p.z < head.z]
    low = min(p.z for p in near) if near else head.z - 0.4
    pivot = bpy.data.objects.new("BellPivot", None)
    sc.collection.objects.link(pivot)
    pivot.parent, pivot.parent_type, pivot.parent_bone = arm, "BONE", NECK
    bpy.context.view_layer.update()
    pivot.matrix_world = Matrix.Translation((head.x, head.y, low + 0.04))
    me = stage.lathe("Bell", [(0.0, 0.0), (0.14, 0.0), (0.12, 0.05), (0.09, 0.2), (0.05, 0.27), (0.0, 0.29)], 32)
    me.transform(Matrix.Translation((0, 0, -0.33)))
    strap = stage.pbr("Strap", (0.25, 0.12, 0.06), roughness=0.7)
    ob = stage.link(sc, "Bell", me, brass, parent=pivot)
    stage.link(sc, "BellCord", stage.lathe("BellCord", [(0.0, -0.06), (0.018, -0.06), (0.018, 0.9), (0.0, 0.9)], 12), strap, parent=ob)
    ob.scale = (0.9, 0.9, 0.9)
    for f in range(-1, TOTAL + 3, 2):
        ob.rotation_euler = (R(14) * math.sin(2 * math.pi * (f - 4) / (CYCLE / 2)), 0.0, 0.0)
        ob.keyframe_insert("rotation_euler", frame=f)
    return ob


def dust(sc, arm):
    mat = fx.fade_material("Dust", (0.72, 0.58, 0.4), 0.18, 0.3, 1.1)
    for i, foot in enumerate(FEET):
        em = fx.particle_burst(sc, f"Dust{i}", fx.point_mesh(f"DustSrc{i}", 0.08), mat, 60, (2, TOTAL - 8), 26, 0.16, 0.35,
                               rand=0.8, align=(0.0, 0.0, 0.35), damping=0.25, gravity=0.02)
        c = em.constraints.new("COPY_LOCATION")
        c.target, c.subtarget = arm, foot


def build(sc):
    root, arm, meshes = cs.load(ID, SIZE)
    body = max(meshes, key=lambda o: len(o.data.vertices))
    seq = cs.sequence(arm, [cs.Take("Bactrian_Camel_Idle", 1, (1, 214), blend=0)])
    cs.overlay(arm, "Pace", pace_keys((-CYCLE, TOTAL + CYCLE)))
    return root, arm, meshes, body, seq


def build_show(sc, opts):
    root, arm, meshes, body, seq = build(sc)
    v = cs.stance_speed(sc, arm, FEET[0], (1, CYCLE * 2))
    seq = [(replace(tk, speed=v), s) for tk, s in seq]
    sc.frame_set(1)
    spine = [arm.matrix_world @ arm.data.bones[n].head_local for n in ("Root_M_57_8", "Chest_M_41_17")]
    cs.drape(sc, arm, body, spine[0].lerp(spine[1], 0.2), spine[0].lerp(spine[1], 0.62), blanket_material(), reach=R(118), offset=0.035, drop=0.16)
    bell(sc, arm, body)
    cs.travel(root, TOTAL, YAW, seq, TOTAL // 2, (0.2, 0.6))
    cs.lift_to(sc, root, meshes, GROUND_Z, TOTAL // 2)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.9, hdri="sunset.exr", lights=0.85, fog=(2.0, 6), streak=10.0)
    sh.shadow_catcher(sc, GROUND_Z, 50)
    dust(sc, arm)
    sh.screen_extent(sc, cam, meshes, (1, 30, 60, 90, TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Pacing on the spot: the stride is periodic in 30 frames, so the loop closes."""
    root, arm, meshes, body, _ = build(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=0.9, hdri="sunset.exr", lights=0.85, fog=(2.0, 6), streak=8.0)
    sc.frame_set(1)
    spine = [arm.matrix_world @ arm.data.bones[n].head_local for n in ("Root_M_57_8", "Chest_M_41_17")]
    cs.drape(sc, arm, body, spine[0].lerp(spine[1], 0.2), spine[0].lerp(spine[1], 0.62), blanket_material(), reach=R(118), offset=0.035, drop=0.16)
    bell(sc, arm, body)
    root.rotation_euler = (0.0, 0.0, R(40))
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.1)
    sh.shadow_catcher(sc, gc.world_bbox(meshes)[0].z, 30)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
