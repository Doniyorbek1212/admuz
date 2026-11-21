"""Quadruped rig from hand-placed joints (autorig distance weights) plus gallop/trot keying, and particle fur.

Space: the rig is built at world rest with the animal's nose toward -Y, up +Z, lateral X; `root` then carries it.
Pitch convention: rotation about +X by a positive angle lowers the front (nose down).
"""
import bpy
from mathutils import Vector

import autorig
import quadruped as qp

X = (1, 0, 0)
Y = (0, 1, 0)
Z = (0, 0, 1)
GALLOP_PHASES = {"LB": 0.0, "RB": 0.12, "LF": 0.5, "RF": 0.62}
TROT_PHASES = {"LB": 0.0, "RF": 0.0, "RB": 0.5, "LF": 0.5}


def mirror(p):
    return (-p[0], p[1], p[2])


def build(sc, name, joints, meshes, power=6.0, limits=None, extra=()):
    """joints: spine [hip, .., chest], neck [base, .., poll], head [poll, muzzle], tail [...], hind/fore [4 or 5 points, x > 0 side],
    optional ear [base, tip], jaw [hinge, chin], tongue [...]."""
    v = lambda p: Vector(p)
    bones = [("root", None, v(joints["hind"][0]) + Vector((0, 0.0, 0.0)), v(joints["hind"][0]) + Vector((0, 0.25, 0.0)))]
    bones += autorig.chain("spine", [v(p) for p in joints["spine"]], "root")
    chest = f"spine{len(joints['spine']) - 2}"
    bones += autorig.chain("neck", [v(p) for p in joints["neck"]], chest)
    head_parent = f"neck{len(joints['neck']) - 2}"
    bones.append(("head", head_parent, v(joints["head"][0]), v(joints["head"][1])))
    if "jaw" in joints:
        bones.append(("jaw", "head", v(joints["jaw"][0]), v(joints["jaw"][1])))
    if "tongue" in joints:
        bones += autorig.chain("tongue", [v(p) for p in joints["tongue"]], "jaw" if "jaw" in joints else "head")
    if "ear" in joints:
        for side, f in (("L", lambda p: p), ("R", mirror)):
            bones += autorig.chain(f"ear{side}", [v(f(p)) for p in joints["ear"]], "head")
    bones += autorig.chain("tail", [v(p) for p in joints["tail"]], "spine0")
    for key, pts, parent, f in (("LB", joints["hind"], "root", lambda p: p), ("RB", joints["hind"], "root", mirror),
                                ("LF", joints["fore"], chest, lambda p: p), ("RF", joints["fore"], chest, mirror)):
        bones += autorig.chain(key, [v(f(p)) for p in pts], parent)
    bones += list(extra)    # extra bones (a wing, say): give them a zero mask in limits if the body must not follow
    autorig.bake_world(meshes)
    arm = autorig.add_rig(sc, name, bones, meshes, power=power, limits=limits)
    return arm


class Mover:
    """Keys legs (quadruped IK) and body parts on one armature."""

    def __init__(self, arm, gait, phases):
        self.arm, self.gait = arm, gait
        self.pose = autorig.Pose(arm)
        chains = {k: [f"{k}{i}" for i in range(4)] for k in ("LB", "RB", "LF", "RF")}
        qp.WALK_PHASES.update(phases)
        self.legs = qp.make_legs(arm, chains, Vector((0, -1, 0)), Vector((0, 0, 1)), Vector((1, 0, 0)), gait)
        self.leg_bones = [b for ch in chains.values() for b in ch]

    def legs_at(self, frame, dist, amp, crouch=0.0):
        """Run cycle by travelled distance; returns the body bob the caller adds to the root."""
        bob = qp.pose_walk(self.legs, self.gait, dist, amp, crouch)
        for b in self.leg_bones:
            self.arm.pose.bones[b].keyframe_insert("rotation_quaternion", frame=frame)
        return bob

    def leg(self, frame, key, paw=(0.0, 0.0), flex=0.0):
        """One leg to a paw offset (fwd, up) from rest."""
        leg = next(lg for lg in self.legs if lg.bones[0].name.startswith(key))
        leg.solve(Vector(paw), Vector((0.0, 0.0)), flex, -0.5 * flex)
        for pb in leg.bones:
            pb.keyframe_insert("rotation_quaternion", frame=frame)

    def body(self, frame, spec):
        self.pose.key(frame, spec)


def side_limits(joints, margin=0.05):
    """Weight masks: a leg never grabs the other side, the static root bone grabs nothing."""
    out = {"root": lambda c: c[:, 0] * 0.0}
    for side, sign in (("L", 1.0), ("R", -1.0)):
        for leg in ("B", "F"):
            for i in range(len(joints["hind" if leg == "B" else "fore"]) - 1):
                out[f"{side}{leg}{i}"] = lambda c, s=sign: (c[:, 0] * s > -margin) * 1.0
    return out


def fur(ob, length, count=2200, children=30, radius=0.006, roughness=0.5, density_vg=None, length_vg=None, seed=1, clump=0.15, tint=None, multiply=None, gamma=None):
    """Short fur coloured by the emitter's own base-colour texture (UV from the instancer). tint: (hue, sat, value) of a Hue/Sat node."""
    src = ob.data.materials[0]
    tree = src.node_tree
    bs = next(n for n in tree.nodes if n.type == "BSDF_PRINCIPLED")
    tex = bs.inputs["Base Color"].links[0].from_node if bs.inputs["Base Color"].links else None
    while tex is not None and tex.type != "TEX_IMAGE":      # a tint node may sit between the texture and the BSDF
        linked = [i for i in tex.inputs if i.is_linked and i.type == "RGBA"]
        tex = linked[0].links[0].from_node if linked else None
    m = bpy.data.materials.new(f"{ob.name}Fur")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    hair = N("ShaderNodeBsdfHairPrincipled")
    hair.parametrization = "COLOR"
    if tex is not None and tex.type == "TEX_IMAGE":
        uv = N("ShaderNodeUVMap")
        uv.from_instancer = True
        im = N("ShaderNodeTexImage")
        im.image = tex.image
        L(uv.outputs[0], im.inputs["Vector"])
        col = im.outputs["Color"]
        if gamma:
            g = N("ShaderNodeGamma")
            g.inputs["Gamma"].default_value = gamma
            L(col, g.inputs["Color"])
            col = g.outputs["Color"]
        if tint:
            hs = N("ShaderNodeHueSaturation")
            hs.inputs["Hue"].default_value, hs.inputs["Saturation"].default_value, hs.inputs["Value"].default_value = tint
            L(col, hs.inputs["Color"])
            col = hs.outputs["Color"]
        if multiply:
            mx = N("ShaderNodeMix")
            mx.data_type, mx.blend_type = "RGBA", "MULTIPLY"
            mx.inputs["Factor"].default_value = 1.0
            mx.inputs["B"].default_value = (*multiply, 1.0)
            L(col, mx.inputs["A"])
            col = mx.outputs["Result"]
        L(col, hair.inputs["Color"])
    else:
        hair.inputs["Color"].default_value = bs.inputs["Base Color"].default_value
    hair.inputs["Roughness"].default_value, hair.inputs["Radial Roughness"].default_value = 0.42, 0.6
    L(hair.outputs[0], N("ShaderNodeOutputMaterial").inputs["Surface"])
    ob.data.materials.append(m)
    mod = ob.modifiers.new("Fur", "PARTICLE_SYSTEM")
    ps = mod.particle_system
    st = ps.settings
    st.type, st.count, st.use_advanced_hair = "HAIR", count, True
    st.hair_step = 3
    st.emit_from, st.use_emit_random = "FACE", True
    # measured on 4.2: a hair's length is 4 * normal_factor, hair_length has no effect here
    st.normal_factor, st.tangent_factor = length / 4.0, 0.0
    st.object_align_factor = (0.0, 0.0, -0.25 * length / 4.0)
    st.factor_random = 0.25 * length / 4.0
    st.child_type = "INTERPOLATED"
    st.child_percent, st.rendered_child_count = children // 3, children
    st.clump_factor, st.roughness_1, st.roughness_1_size = clump, 0.015, 0.4
    st.root_radius, st.tip_radius, st.radius_scale = 1.0, 0.08, radius
    st.material = len(ob.data.materials)
    ps.seed = seed
    if density_vg:
        ps.vertex_group_density = density_vg
    if length_vg:
        ps.vertex_group_length = length_vg
    return ps
