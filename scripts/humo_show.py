"""UZARO v2 show: Humo bird (tier 4, 168 f = 7 s).

The mythical Humo rises from below the frame with wings swept up, flares at the centre and throws its huge golden
wings open across the screen while a sun halo blooms behind it; it glides on slow, heavy beats as feathers made of
light shiver along the wing edges and gold feathers drift down, then drives itself up and out of the top of the frame.
Original design: the batch 1 eagle rig (Filip "Free Eagle", CC BY) re-skinned in hammered gold with glowing feather
edges, plus procedural light feathers along each wing's trailing edge, five long flowing tail plumes and a crest.

    blender -b --factory-startup -P humo_show.py -- <show|icon> [f=1,60,100] [s=16]
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import autorig  # noqa: E402
import eagle_show as eagle  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, env, interp  # noqa: E402

ID = "humo"
TOTAL = 168
K = 0.66
X, Y, Z = (1, 0, 0), (0, 1, 0), (0, 0, 1)
SIDES = eagle.SIDES
GOLD = (1.0, 0.62, 0.2)
LIGHT = (1.0, 0.78, 0.42)
PATH = [(1, (0.0, 1.0, -12.5)), (40, (0.0, 0.0, -2.6)), (62, (0.0, -0.6, 0.2)), (112, (0.0, -0.8, 0.9)),
        (TOTAL, (0.4, 2.0, 14.0))]
PITCH = [(1, -72.0), (40, -66.0), (62, -38.0), (112, -34.0), (130, -58.0), (TOTAL, -70.0)]    # nose up, chest to camera
ROLL = [(1, 0.0), (90, 3.0), (112, -2.0), (TOTAL, 0.0)]
YAW = [(1, 0.0), (TOTAL, 0.0)]
FOLD = (1, 40, 58)          # wings swept until 40, thrown open by 58
HERO_F = 60                 # the big downbeat: halo blooms, light shivers out along the feathers
GLIDE = (64, 112)
CLIMB_F = 116


# ------------------------------------------------------------------ materials
def gold_feather_material(src):
    """Hammered gold that keeps the eagle's feather detail as relief and tone, with a hot rim (feathers made of light)."""
    nt = src.node_tree
    b = stage.bsdf(src)
    tex_sock = b.inputs["Base Color"].links[0].from_socket if b.inputs["Base Color"].links else None
    for name in ("Roughness", "Metallic"):
        for lk in list(b.inputs[name].links):
            nt.links.remove(lk)
    N, L = nt.nodes.new, nt.links.new
    ramp = N("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (0.62, 0.36, 0.08, 1)
    ramp.color_ramp.elements[1].color = (1.0, 0.86, 0.5, 1)
    if tex_sock is not None:
        bw = N("ShaderNodeRGBToBW")
        L(tex_sock, bw.inputs[0])
        L(bw.outputs[0], ramp.inputs["Fac"])
        bump = N("ShaderNodeBump")
        bump.inputs["Strength"].default_value = 0.35
        L(bw.outputs[0], bump.inputs["Height"])
        L(bump.outputs["Normal"], b.inputs["Normal"])
        rough = N("ShaderNodeMapRange")
        rough.inputs["To Min"].default_value, rough.inputs["To Max"].default_value = 0.38, 0.16
        L(bw.outputs[0], rough.inputs["Value"])
        L(rough.outputs["Result"], b.inputs["Roughness"])
    else:
        ramp.inputs["Fac"].default_value = 0.7
        b.inputs["Roughness"].default_value = 0.25
    L(ramp.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Metallic"].default_value = 0.92
    b.inputs["Coat Weight"].default_value = 0.25
    b.inputs["Coat Roughness"].default_value = 0.08
    lw = N("ShaderNodeLayerWeight")
    lw.inputs["Blend"].default_value = 0.35
    rim = N("ShaderNodeMath")
    rim.operation = "POWER"
    rim.inputs[1].default_value = 2.0
    L(lw.outputs["Fresnel"], rim.inputs[0])
    glow = N("ShaderNodeValue")
    glow.name = "Glow"
    mul = N("ShaderNodeMath")
    mul.operation = "MULTIPLY"
    L(rim.outputs[0], mul.inputs[0])
    L(glow.outputs[0], mul.inputs[1])
    b.inputs["Emission Color"].default_value = (*LIGHT, 1)
    L(mul.outputs[0], b.inputs["Emission Strength"])
    return glow.outputs[0]


def light_material(name, strength):
    """Feather of light: hot gold core along the shaft, fading to nothing at the tip and the edges."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out = N("ShaderNodeOutputMaterial")
    uv = N("ShaderNodeUVMap")
    sep = N("ShaderNodeSeparateXYZ")
    L(uv.outputs[0], sep.inputs[0])
    along = N("ShaderNodeMapRange")              # u: 0 root .. 1 tip
    along.inputs["From Min"].default_value, along.inputs["From Max"].default_value = 1.0, 0.25
    L(sep.outputs["X"], along.inputs["Value"])
    across = N("ShaderNodeMath")                 # v: 0..1 across, 1 at the shaft
    across.operation = "PINGPONG"
    across.inputs[1].default_value = 0.5
    L(sep.outputs["Y"], across.inputs[0])
    core = N("ShaderNodeMapRange")
    core.inputs["From Min"].default_value, core.inputs["From Max"].default_value = 0.0, 0.5
    core.interpolation_type = "SMOOTHSTEP"
    L(across.outputs[0], core.inputs["Value"])
    a = N("ShaderNodeMath")
    a.operation, a.use_clamp = "MULTIPLY", True
    L(along.outputs["Result"], a.inputs[0])
    L(core.outputs["Result"], a.inputs[1])
    glow = N("ShaderNodeValue")
    glow.name = "Glow"
    a2 = N("ShaderNodeMath")
    a2.operation, a2.use_clamp = "MULTIPLY", True
    L(a.outputs[0], a2.inputs[0])
    L(glow.outputs[0], a2.inputs[1])
    em = N("ShaderNodeEmission")
    hot = N("ShaderNodeMix")
    hot.data_type = "RGBA"
    hot.inputs["A"].default_value = (*GOLD, 1)
    hot.inputs["B"].default_value = (1.0, 0.74, 0.36, 1)
    L(core.outputs["Result"], hot.inputs["Factor"])
    L(hot.outputs["Result"], em.inputs["Color"])
    em.inputs["Strength"].default_value = strength
    tr = N("ShaderNodeBsdfTransparent")
    mix = N("ShaderNodeMixShader")
    L(a2.outputs[0], mix.inputs[0])
    L(tr.outputs[0], mix.inputs[1])
    L(em.outputs[0], mix.inputs[2])
    L(mix.outputs[0], out.inputs["Surface"])
    m.surface_render_method = "BLENDED"
    return m, glow.outputs[0]


# ------------------------------------------------------------------ meshes
def blade(verts, faces, uvs, root, direction, side_vec, length, width, curl=0.0, segs=10):
    """One feather blade (a strip along direction, slightly cupped), appended to verts/faces/uvs."""
    d, s = Vector(direction).normalized(), Vector(side_vec).normalized()
    up = d.cross(s).normalized()
    base = len(verts)
    for i in range(segs + 1):
        t = i / segs
        w = width * math.sin(math.pi * min(1.0, 0.15 + t * 0.95)) * (1 - 0.6 * t)
        c = Vector(root) + d * length * t + up * curl * length * t * t
        for j, k in enumerate((-1.0, 0.0, 1.0)):
            verts.append(tuple(c + s * w * k + up * 0.04 * width * (1 - abs(k))))
            uvs.append((t, j / 2))
    for i in range(segs):
        for j in range(2):
            a = base + i * 3 + j
            faces.append((a, a + 1, a + 4, a + 3))


def make_mesh(name, verts, faces, uvs):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    uv = me.uv_layers.new(name="UVMap")
    for poly in me.polygons:
        for li in poly.loop_indices:
            uv.data[li].uv = uvs[me.loops[li].vertex_index]
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    return me


def skin_to(ob, arm, groups):
    """Rigid-ish skinning: groups = [(bone, [vertex indices], weight), ...]."""
    for bone, idx, w in groups:
        vg = ob.vertex_groups.get(bone) or ob.vertex_groups.new(name=bone)
        vg.add(idx, w, "ADD")
    ob.parent = arm
    ob.modifiers.new("Rig", "ARMATURE").object = arm


def light_feathers(sc, arm):
    """Long glowing primaries along each wing's trailing edge, riding the wing bones."""
    mat, glow = light_material("LightFeather", 1.7)
    for side, s in SIDES:
        verts, faces, uvs, groups = [], [], [], []
        bones_ = [arm.data.bones[f"wing{side}{i}"] for i in range(3)]
        n = 24
        for k in range(n):
            t = k / (n - 1)
            jit = math.sin(k * 12.9898) * 0.5          # fixed per-feather variation                       # 0 at the body .. 1 at the tip
            seg = min(2, int(t * 3))
            b = bones_[seg]
            u = t * 3 - seg
            root = b.head_local.lerp(b.tail_local, u) + Vector((0, 0.18, -0.02))
            ang = R(-8 + 38 * t ** 1.3 + 4 * jit)           # fan: straight back near the body, sweeping outward at the tip
            direction = (s * math.sin(ang), math.cos(ang), -0.05)
            start = len(verts)
            blade(verts, faces, uvs, root, direction, (math.cos(ang), -s * math.sin(ang), 0), (1.0 + 1.1 * t ** 0.8) * (1 + 0.25 * jit),
                  0.12 + 0.04 * t, curl=-0.08)
            groups.append((b.name, list(range(start, len(verts))), 1.0))
        ob = stage.link(sc, f"LightFeathers{side}", make_mesh(f"LightFeathers{side}", verts, faces, uvs), mat, shadow=False)
        skin_to(ob, arm, groups)
    return glow


def flow_group():
    """Geometry nodes: a lateral S-wave that travels root to tip, growing toward the tip (u = 0 root .. 1 tip)."""
    g = bpy.data.node_groups.new("PlumeFlow", "GeometryNodeTree")
    g.interface.new_socket("Geometry", in_out="INPUT", socket_type="NodeSocketGeometry")
    for name in ("Phase", "Speed", "Amp"):
        g.interface.new_socket(name, in_out="INPUT", socket_type="NodeSocketFloat")
    g.interface.new_socket("Geometry", in_out="OUTPUT", socket_type="NodeSocketGeometry")
    N, L = g.nodes.new, g.links.new
    gi, go = N("NodeGroupInput"), N("NodeGroupOutput")
    u = N("GeometryNodeInputNamedAttribute")
    u.data_type = "FLOAT"
    u.inputs["Name"].default_value = "u"
    t = N("GeometryNodeInputSceneTime")

    def math(op, a, b):
        m = N("ShaderNodeMath")
        m.operation = op
        for i, x in enumerate((a, b)):
            if isinstance(x, (int, float)):
                m.inputs[i].default_value = x
            else:
                L(x, m.inputs[i])
        return m.outputs[0]
    uval = u.outputs["Attribute"]
    arg = math("SUBTRACT", math("MULTIPLY", uval, 7.0), math("ADD", math("MULTIPLY", t.outputs["Frame"], gi.outputs["Speed"]), gi.outputs["Phase"]))
    amp = math("MULTIPLY", math("POWER", uval, 1.5), gi.outputs["Amp"])
    off = N("ShaderNodeCombineXYZ")
    L(math("MULTIPLY", math("SINE", arg, 0.0), amp), off.inputs["X"])
    L(math("MULTIPLY", math("COSINE", arg, 0.0), math("MULTIPLY", amp, 0.35)), off.inputs["Y"])
    sp = N("GeometryNodeSetPosition")
    L(gi.outputs["Geometry"], sp.inputs["Geometry"])
    L(off.outputs["Vector"], sp.inputs["Offset"])
    L(sp.outputs["Geometry"], go.inputs["Geometry"])
    return g


def tail_plumes(sc, arm, total):
    """Five long ribbons from the tail with an S-wave travelling down each: the train of a bird of paradise, in light."""
    mat, glow = light_material("Plume", 1.7)
    tail = arm.data.bones["tail1"]
    group = flow_group()
    for i, (yaw, ln) in enumerate(((-24, 5.6), (-11, 6.8), (0, 7.6), (11, 6.8), (24, 5.6))):
        verts, faces, uvs = [], [], []
        a = R(yaw)
        # hangs below the bird: world-down in the chest-on pose is (0, 0.59, -0.81) in body space; fans out sideways
        blade(verts, faces, uvs, (0, 0, 0), (1.3 * math.sin(a), 0.59, -0.81), (math.cos(a), 0, 0), ln, 0.34, curl=0.0, segs=36)
        me = make_mesh(f"Plume{i}", verts, faces, uvs)
        at = me.attributes.new("u", "FLOAT", "POINT")
        at.data.foreach_set("value", [uv[0] for uv in uvs])
        ob = stage.link(sc, f"Plume{i}", me, mat, shadow=False)
        md = ob.modifiers.new("Flow", "NODES")
        md.node_group = group
        ids = {it.name: it.identifier for it in group.interface.items_tree if it.in_out == "INPUT" and it.name != "Geometry"}
        md[ids["Phase"]], md[ids["Speed"]], md[ids["Amp"]] = i * 1.3, 0.2, 0.55
        ob.parent, ob.parent_type, ob.parent_bone = arm, "BONE", "tail1"
        bpy.context.view_layer.update()
        ob.matrix_world = arm.matrix_world @ Matrix.Translation(tail.tail_local)
    return glow


def crest(sc, arm):
    mat, glow = light_material("Crest", 3.0)
    head = arm.data.bones["head"]
    verts, faces, uvs = [], [], []
    for k, (dx, ln) in enumerate(((-0.1, 0.7), (0.0, 0.95), (0.1, 0.7))):
        blade(verts, faces, uvs, head.head_local + Vector((dx, -0.25, 0.22)), (dx * 1.5, 0.55, 1.0), (1, 0, 0), ln, 0.07, curl=0.3, segs=8)
    ob = stage.link(sc, "Crest", make_mesh("Crest", verts, faces, uvs), mat, shadow=False)
    skin_to(ob, arm, [("head", list(range(len(verts))), 1.0)])
    return glow


def halo(sc, root):
    """Sun disc behind the bird: soft core, a thin bright ring and radial rays; blooms on the downbeat."""
    import bmesh
    me = bpy.data.meshes.new("Halo")
    bm = bmesh.new()
    bmesh.ops.create_circle(bm, cap_ends=True, radius=1.0, segments=128)
    bm.to_mesh(me)
    bm.free()
    ob = stage.link(sc, "Halo", me, shadow=False)
    ob.rotation_euler = (R(90), 0, 0)
    m = bpy.data.materials.new("HaloMat")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out = N("ShaderNodeOutputMaterial")
    tc = N("ShaderNodeTexCoord")
    sep = N("ShaderNodeSeparateXYZ")
    L(tc.outputs["Object"], sep.inputs[0])
    r = N("ShaderNodeVectorMath")
    r.operation = "LENGTH"
    L(tc.outputs["Object"], r.inputs[0])
    ang = N("ShaderNodeMath")
    ang.operation = "ARCTAN2"
    L(sep.outputs["Y"], ang.inputs[0])
    L(sep.outputs["X"], ang.inputs[1])
    rays = N("ShaderNodeMath")
    rays.operation = "SINE"
    k = N("ShaderNodeMath")
    k.operation = "MULTIPLY"
    k.inputs[1].default_value = 24.0
    L(ang.outputs[0], k.inputs[0])
    L(k.outputs[0], rays.inputs[0])
    rays01 = N("ShaderNodeMapRange")
    rays01.inputs["From Min"].default_value, rays01.inputs["From Max"].default_value = 0.2, 1.0
    L(rays.outputs[0], rays01.inputs["Value"])
    core = N("ShaderNodeFloatCurve")
    cm = core.mapping
    cm.curves[0].points[0].location = (0.0, 0.75)
    cm.curves[0].points[1].location = (1.0, 0.0)
    for x, y in ((0.35, 0.22), (0.62, 0.55), (0.68, 0.08), (0.85, 0.02)):
        cm.curves[0].points.new(x, y)
    cm.update()
    L(r.outputs["Value"], core.inputs["Value"])
    ray_fall = N("ShaderNodeMapRange")
    ray_fall.inputs["From Min"].default_value, ray_fall.inputs["From Max"].default_value = 0.3, 1.0
    ray_fall.inputs["To Min"].default_value, ray_fall.inputs["To Max"].default_value = 0.3, 0.0
    L(r.outputs["Value"], ray_fall.inputs["Value"])
    rm = N("ShaderNodeMath")
    rm.operation = "MULTIPLY"
    L(rays01.outputs["Result"], rm.inputs[0])
    L(ray_fall.outputs["Result"], rm.inputs[1])
    total = N("ShaderNodeMath")
    total.operation = "ADD"
    L(core.outputs["Value"], total.inputs[0])
    L(rm.outputs[0], total.inputs[1])
    fade = N("ShaderNodeValue")
    fade.name = "Fade"
    a = N("ShaderNodeMath")
    a.operation, a.use_clamp = "MULTIPLY", True
    L(total.outputs[0], a.inputs[0])
    L(fade.outputs[0], a.inputs[1])
    em = N("ShaderNodeEmission")
    em.inputs["Color"].default_value = (1.0, 0.58, 0.2, 1)
    em.inputs["Strength"].default_value = 1.8
    tr = N("ShaderNodeBsdfTransparent")
    mix = N("ShaderNodeMixShader")
    L(a.outputs[0], mix.inputs[0])
    L(tr.outputs[0], mix.inputs[1])
    L(em.outputs[0], mix.inputs[2])
    L(mix.outputs[0], out.inputs["Surface"])
    m.surface_render_method = "BLENDED"
    me.materials.append(m)
    ob.visible_shadow = False
    ob.visible_diffuse = ob.visible_glossy = False
    for f, s, v in ((HERO_F - 6, 0.6, 0.0), (HERO_F + 4, 3.0, 1.0), (GLIDE[1], 3.4, 0.85), (CLIMB_F + 22, 3.8, 0.0)):
        ob.scale = (s, s, s)
        ob.keyframe_insert("scale", frame=f)
        fade.outputs[0].default_value = v
        fade.outputs[0].keyframe_insert("default_value", frame=f)
    ob.location = (0.0, 2.6, 0.9)
    return ob


def gold_feathers(sc):
    """Real gold feathers shaken loose on the downbeat and in the climb, tumbling down slowly."""
    mat = stage.pbr("LooseGold", (1.0, 0.7, 0.3), metallic=0.95, roughness=0.25, emission=GOLD, strength=0.4)
    out = []
    for name, frames, loc, count in (("FeatherFall", (HERO_F - 2, HERO_F + 30), (0.0, -0.6, 0.6), 46),
                                     ("FeatherClimb", (CLIMB_F, CLIMB_F + 30), (0.0, -0.4, 3.0), 30)):
        em = fx.particle_burst(sc, name, fx.ring_mesh(f"{name}R", 2.2, 0.4, 32), mat, count, frames, 90, 0.16, 0.9,
                               rand=1.2, damping=0.35, gravity=0.06, location=loc)
        st = em.particle_systems[0].settings
        st.instance_object.data = stage.lathe(f"{name}Shape", [(0, 0.5), (0.12, 0.3), (0.18, -0.1), (0.07, -0.5), (0, -0.6)], 8)
        st.instance_object.data.transform(Matrix.Scale(0.06, 4, (0, 1, 0)))
        st.instance_object.data.materials.append(mat)
        st.use_rotations, st.rotation_factor_random = True, 1.0
        st.angular_velocity_mode, st.angular_velocity_factor = "RAND", 2.0
        out.append(em)
    spark = fx.fade_material("GoldDust", (1.0, 0.8, 0.45), 9.0, 1.0, 1.4)
    fx.particle_burst(sc, "Dust", fx.ring_mesh("DustR", 2.6, 0.3, 48), spark, 500, (HERO_F - 2, GLIDE[1]), 40, 0.022, 0.5,
                      rand=1.4, damping=0.3, gravity=0.04, location=(0.0, -0.7, 0.6))
    return out


def light_trail(sc, root):
    """Gold sparks streaming off the bird on the rise in and the climb out."""
    spark = fx.fade_material("Trail", (1.0, 0.75, 0.38), 10.0, 1.0, 1.6)
    em = fx.particle_burst(sc, "Trail", fx.point_mesh("TrailP", 0.6), spark, 900, (1, TOTAL - 10), 26, 0.02, 0.1, rand=0.6,
                           damping=0.4, gravity=0.0, emit_from="VOLUME")
    em.parent = root
    return em


# ------------------------------------------------------------------ animation
def flap_at(f):
    """Slow, heavy glide beats; faster, deeper drive on the climb. Signed, down positive."""
    up_f, down_f = FOLD[2] - 4, HERO_F + 4
    if f < up_f:
        return -0.5 * env(f, FOLD[1], up_f)                   # wings lift as they open
    if f < down_f:
        return -0.5 + 1.4 * env(f, up_f, down_f)              # the big downbeat
    if f < CLIMB_F:
        a = 0.5 + 0.4 * (1 - env(f, down_f, down_f + 16))
        return a * math.cos((f - down_f) * 2 * math.pi / 30.0)
    return math.sin((f - CLIMB_F) * 2 * math.pi / 16.0) * env(f, CLIMB_F, CLIMB_F + 5)


def animate(root, pose, glows):
    for f in range(1, TOTAL + 1):
        fold = 1 - env(f, FOLD[1], FOLD[2])
        flap = flap_at(f)
        call = env(f, HERO_F - 2, HERO_F + 3) * (1 - env(f, HERO_F + 12, HERO_F + 20))
        eagle.pose_frame(pose, f, flap, 0.0, call)
        sweep = fold * 0.85                       # rising in: wings swept up and back, not tucked like a stoop
        for side, s in SIDES:
            pb = pose.arm.pose.bones[f"wing{side}0"]
            pb.rotation_quaternion = pose.quat(f"wing{side}0", [(Y, -s * 62.0 * sweep), (Z, s * 26.0 * sweep)]) @ pb.rotation_quaternion
            pb.keyframe_insert("rotation_quaternion", frame=f)
            pb1 = pose.arm.pose.bones[f"wing{side}1"]
            pb1.rotation_quaternion = pose.quat(f"wing{side}1", (Z, -s * 34.0 * sweep)) @ pb1.rotation_quaternion
            pb1.keyframe_insert("rotation_quaternion", frame=f)
        x, y, z = interp(PATH, f) if f < CLIMB_F else stage.catmull([interp(PATH, CLIMB_F), (0.2, 0.4, 4.0), PATH[-1][1]], env(f, CLIMB_F, TOTAL) ** 1.25)
        bob = -0.22 * flap if f >= FOLD[2] else 0.0
        root.location = (x, y, z + bob)
        root.keyframe_insert("location", frame=f)
        root.rotation_euler = (R(interp(PITCH, f)), R(interp(ROLL, f)), R(interp(YAW, f)))
        root.keyframe_insert("rotation_euler", frame=f)
    keys = [(1, 0.25), (HERO_F - 4, 0.6), (HERO_F + 2, 4.0), (HERO_F + 14, 1.4), (GLIDE[1], 1.2), (CLIMB_F + 10, 2.2), (TOTAL, 1.0)]
    for sock, gain in glows:
        stage.key_socket(sock, [(f, v * gain) for f, v in keys])


def load(sc):
    root, arm, meshes = eagle.load(sc)
    root.scale = (K, K, K)
    glows, seen = [], set()
    for m in meshes:
        for mat in m.data.materials:
            if mat and mat.use_nodes and mat.name not in seen:
                seen.add(mat.name)
                glows.append((gold_feather_material(mat), 1.0))
    glows.append((light_feathers(sc, arm), 1.0))
    glows.append((tail_plumes(sc, arm, TOTAL), 1.0))
    glows.append((crest(sc, arm), 1.0))
    return root, arm, meshes, glows


def build_show(sc, opts):
    root, arm, meshes, glows = load(sc)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.7, hdri="sunset.exr", follow=root, lights=0.9, fog=(1.5, 8),
                      streak=5.0, shutter=0.5)
    pose = autorig.Pose(arm)
    animate(root, pose, glows)
    halo(sc, root)
    gold_feathers(sc)
    light_trail(sc, root)
    sh.camera_shake(cam, HERO_F, 14, amp=0.05, rot_deg=0.3, seed=11)
    sh.screen_extent(sc, cam, meshes + [o for o in sc.objects if o.name.startswith(("LightFeathers", "Plume"))],
                     (1, 30, 50, HERO_F, 90, 120, 150, TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Front-on, wings open on slow beats, plumes flowing: a seamless 2 s loop."""
    root, arm, meshes, glows = load(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=0.7, hdri="sunset.exr", follow=root, lights=0.9, fog=(1.5, 8), streak=5.0)
    pose = autorig.Pose(arm)
    root.rotation_euler = (R(-36), 0, 0)
    n = stage.ICON_N
    for f in range(0, n + 1):
        w = 2 * math.pi * f / n
        flap = 0.6 * math.sin(w)
        eagle.pose_frame(pose, f, flap, 0.0, 0.3 + 0.3 * math.sin(w))
        root.location = (0.0, 0.0, -0.2 * flap)
        root.keyframe_insert("location", frame=f)
    for sock, gain in glows:
        stage.key_socket(sock, [(0, 1.6), (n // 2, 2.6), (n, 1.6)])
    for o in sc.objects:
        for md in o.modifiers:
            if md.type == "NODES" and md.node_group and md.node_group.name == "PlumeFlow":
                sid = next(it.identifier for it in md.node_group.interface.items_tree if it.name == "Speed")
                md[sid] = 2 * math.pi / n      # one wave per loop: seamless
    h = halo(sc, root)
    h.animation_data_clear()
    h.data.materials[0].node_tree.animation_data_clear()
    h.scale = (2.6, 2.6, 2.6)
    h.data.materials[0].node_tree.nodes["Fade"].outputs[0].default_value = 0.8
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.15)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
