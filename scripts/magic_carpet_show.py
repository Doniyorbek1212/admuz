"""UZARO v2 show: magic_carpet (tier 2, 120 f = 5 s).

A carpet with an original suzani-style pattern flies in from the left, rippling, loops the loop on a plane tilted
toward the lens (so its face shows), and flies out to the right, leaving a trail of gold sparkles. Ripple is a
geometry-nodes travelling wave (not a cloth sim), so the icon loop closes exactly. Fringe is part of the same mesh.
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R  # noqa: E402

ID = "magic_carpet"
TOTAL = 120
W, LEN = 2.0, 3.0                       # carpet width (X) and length (Y, nose at -Y)
FRINGE = 0.16
LOOP_C, LOOP_R = Vector((0.3, 0.0, 1.0)), 2.0
V = Vector((0.0, -0.57, 0.82))          # loop plane tilts toward the lens: the carpet's face shows
ENTER, LOOP, EXIT = 1, 30, 80
SPEED = 2 * math.pi * LOOP_R / (EXIT - LOOP)
CREAM, CRIMSON, INDIGO, GREEN, GOLD = (0.86, 0.78, 0.6), (0.55, 0.04, 0.05), (0.08, 0.09, 0.3), (0.12, 0.3, 0.12), (1.0, 0.72, 0.28)


# ---------------------------------------------------------------- pattern
def suzani_material():
    """Cream ground; per cell a crimson rosette with 12 petals, an indigo ring and a gold eye; green leaf dots at
    the cell corners; an indigo border with a gold zigzag. Fringe (material slot 2) is cream thread."""
    m = stage.pbr("Suzani", CREAM, roughness=0.75)
    b = stage.bsdf(m)
    b.inputs["Sheen Weight"].default_value = 0.6
    nt = m.node_tree
    N, L = nt.nodes.new, nt.links.new

    def op(o, a, bb=None, clamp=False):
        n = N("ShaderNodeMath")
        n.operation, n.use_clamp = o, clamp
        for i, x in enumerate((a, bb)):
            if x is None:
                continue
            if isinstance(x, (int, float)):
                n.inputs[i].default_value = x
            else:
                L(x, n.inputs[i])
        return n.outputs[0]

    def mix(fac, a, col):
        n = N("ShaderNodeMix")
        n.data_type = "RGBA"
        n.inputs["B"].default_value = (*col, 1)
        if isinstance(a, tuple):
            n.inputs["A"].default_value = (*a, 1)
        else:
            L(a, n.inputs["A"])
        L(fac, n.inputs["Factor"])
        return n.outputs["Result"]

    uv, sep = N("ShaderNodeUVMap"), N("ShaderNodeSeparateXYZ")
    L(uv.outputs[0], sep.inputs[0])
    u, v = sep.outputs["X"], sep.outputs["Y"]
    edge = op("MINIMUM", op("MULTIPLY", op("MINIMUM", u, op("SUBTRACT", 1.0, u)), W), op("MULTIPLY", op("MINIMUM", v, op("SUBTRACT", 1.0, v)), LEN))
    border = op("LESS_THAN", edge, 0.24)
    zig = op("ABSOLUTE", op("SUBTRACT", op("PINGPONG", op("MULTIPLY", op("ADD", op("MULTIPLY", u, W), op("MULTIPLY", v, LEN)), 3.0), 1.0), 0.5))
    zigline = op("MULTIPLY", op("LESS_THAN", op("ABSOLUTE", op("SUBTRACT", op("MULTIPLY", edge, 4.2), op("ADD", zig, 0.25))), 0.09), border)
    trim = op("LESS_THAN", op("ABSOLUTE", op("SUBTRACT", edge, 0.24)), 0.018)
    cu = op("SUBTRACT", op("FRACT", op("MULTIPLY", u, 2.0)), 0.5)          # 2 x 3 cells
    cv = op("SUBTRACT", op("FRACT", op("MULTIPLY", v, 3.0)), 0.5)
    r = op("SQRT", op("ADD", op("MULTIPLY", cu, cu), op("MULTIPLY", cv, cv)))
    ang = op("ARCTAN2", cv, cu)
    petal_r = op("ADD", 0.33, op("MULTIPLY", op("ABSOLUTE", op("COSINE", op("MULTIPLY", ang, 6.0))), 0.08))
    rosette = op("LESS_THAN", r, petal_r)
    ring = op("LESS_THAN", op("ABSOLUTE", op("SUBTRACT", r, 0.2)), 0.035)
    eye = op("LESS_THAN", r, 0.07)
    corner = op("LESS_THAN", op("SQRT", op("ADD", op("MULTIPLY", op("SUBTRACT", op("ABSOLUTE", cu), 0.5), op("SUBTRACT", op("ABSOLUTE", cu), 0.5)),
                                              op("MULTIPLY", op("SUBTRACT", op("ABSOLUTE", cv), 0.5), op("SUBTRACT", op("ABSOLUTE", cv), 0.5)))), 0.12)
    inside = op("SUBTRACT", 1.0, border)
    col = mix(op("MULTIPLY", rosette, inside), CREAM, CRIMSON)
    col = mix(op("MULTIPLY", ring, inside), col, INDIGO)
    col = mix(op("MULTIPLY", eye, inside), col, GOLD)
    col = mix(op("MULTIPLY", corner, inside), col, GREEN)
    col = mix(border, col, INDIGO)
    gold = op("MAXIMUM", op("MAXIMUM", zigline, trim), op("MULTIPLY", eye, inside))
    col = mix(gold, col, GOLD)
    L(col, b.inputs["Base Color"])
    L(gold, b.inputs["Metallic"])
    weave = N("ShaderNodeTexBrick")                                          # fine weave bump
    weave.inputs["Scale"].default_value = 90.0
    weave.inputs["Mortar Size"].default_value = 0.08
    L(uv.outputs[0], weave.inputs["Vector"])
    bump = N("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.25
    L(weave.outputs["Fac"], bump.inputs["Height"])
    L(bump.outputs[0], b.inputs["Normal"])
    thread = stage.pbr("Fringe", (0.9, 0.85, 0.72), roughness=0.8)
    return m, thread


def carpet_mesh():
    """Grid W x LEN (UV 0..1) with fringe strips past both short ends (material 1)."""
    nx, ny = 24, 36
    verts, faces, uvs, mats = [], [], [], []
    for j in range(ny + 1):
        for i in range(nx + 1):
            verts.append(((i / nx - 0.5) * W, (j / ny - 0.5) * LEN, 0.0))
            uvs.append((i / nx, j / ny))
    for j in range(ny):
        for i in range(nx):
            a = j * (nx + 1) + i
            faces.append((a, a + 1, a + nx + 2, a + nx + 1))
            mats.append(0)
    strands = 22
    for end, sgn in ((0, -1), (ny, 1)):
        y0 = (end / ny - 0.5) * LEN
        for k in range(strands):
            x = ((k + 0.5) / strands - 0.5) * W * 0.96
            base = len(verts)
            for dy in (0.0, FRINGE):
                for dx in (-0.018, 0.018):
                    verts.append((x + dx, y0 + sgn * dy, 0.0))
                    uvs.append((0.5, 0.5))
            faces.append((base, base + 1, base + 3, base + 2))
            mats.append(1)
    me = bpy.data.meshes.new("Carpet")
    me.from_pydata(verts, [], faces)
    lay = me.uv_layers.new()
    for p, mi in zip(me.polygons, mats):
        p.material_index = mi
        for li, vi in zip(p.loop_indices, p.vertices):
            lay.data[li].uv = uvs[vi]
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    return me


def ripple_group(rate):
    """z += A(y) * sin(k*y - rate*frame) + a small cross roll: a wave running from the nose to the tail."""
    ng = bpy.data.node_groups.new("Ripple", "GeometryNodeTree")
    ng.interface.new_socket(name="Geometry", in_out="INPUT", socket_type="NodeSocketGeometry")
    ng.interface.new_socket(name="Geometry", in_out="OUTPUT", socket_type="NodeSocketGeometry")
    N, L = ng.nodes.new, ng.links.new
    gi, go, sp, pos = N("NodeGroupInput"), N("NodeGroupOutput"), N("GeometryNodeSetPosition"), N("GeometryNodeInputPosition")
    sep, t = N("ShaderNodeSeparateXYZ"), N("GeometryNodeInputSceneTime")
    L(pos.outputs[0], sep.inputs[0])

    def op(o, a, b=None):
        n = N("ShaderNodeMath")
        n.operation = o
        for i, x in enumerate((a, b)):
            if x is None:
                continue
            if isinstance(x, (int, float)):
                n.inputs[i].default_value = x
            else:
                L(x, n.inputs[i])
        return n.outputs[0]

    y, x, f = sep.outputs["Y"], sep.outputs["X"], t.outputs["Frame"]
    amp = op("MULTIPLY", op("ADD", 0.35, op("MULTIPLY", op("ADD", y, LEN / 2), 0.65 / LEN)), 0.16)    # small at the nose
    wave = op("SINE", op("SUBTRACT", op("MULTIPLY", y, 2 * math.pi / 2.2), op("MULTIPLY", f, rate)))
    roll = op("MULTIPLY", op("SINE", op("SUBTRACT", op("MULTIPLY", y, 2 * math.pi / 3.0), op("MULTIPLY", f, rate * 0.5))), op("MULTIPLY", x, 0.06))
    z = op("ADD", op("MULTIPLY", amp, wave), roll)
    off = N("ShaderNodeCombineXYZ")
    L(z, off.inputs["Z"])
    L(gi.outputs[0], sp.inputs["Geometry"])
    L(off.outputs[0], sp.inputs["Offset"])
    L(sp.outputs[0], go.inputs[0])
    return ng


def build(sc, rate):
    mat, thread = suzani_material()
    me = carpet_mesh()
    ob = stage.link(sc, "Carpet", me, mat, thread)
    gn = ob.modifiers.new("Ripple", "NODES")
    gn.node_group = ripple_group(rate)
    sol = ob.modifiers.new("Thick", "SOLIDIFY")
    sol.thickness = 0.02
    return ob


# ---------------------------------------------------------------- flight
def flight(f):
    """(position, forward, up): straight in along +X, a loop on the tilted plane, straight out."""
    bottom = LOOP_C - V * LOOP_R
    if f <= LOOP:
        p = bottom + Vector((-(LOOP - f) * SPEED, 0.0, -0.012 * (LOOP - f) ** 1.3))
        return p, Vector((1.0, 0.0, 0.0)), V.copy()
    if f <= EXIT:
        th = 2 * math.pi * (f - LOOP) / (EXIT - LOOP)
        X = Vector((1.0, 0.0, 0.0))
        p = LOOP_C + LOOP_R * (math.sin(th) * X - math.cos(th) * V)
        fwd = (math.cos(th) * X + math.sin(th) * V).normalized()
        return p, fwd, (LOOP_C - p).normalized()
    s = (f - EXIT) * SPEED * (1 + 0.012 * (f - EXIT))
    return bottom + Vector((s, 0.0, 0.006 * (f - EXIT) ** 1.6)), Vector((1.0, 0.0, 0.006)).normalized(), V.copy()


def orient(fwd, up):
    """Rotation for the carpet: nose (-Y) along fwd, face (+Z) along up."""
    up = (up - fwd * up.dot(fwd)).normalized()
    right = up.cross(-fwd)
    return Matrix((right, -fwd, up)).transposed().to_quaternion()


def animate(ob):
    ob.rotation_mode = "QUATERNION"                    # through the loop an euler would flip
    prev = None
    for f in range(1, TOTAL + 1):
        p, fwd, up = flight(f)
        q = orient(fwd, up)
        if prev is not None and q.dot(prev) < 0:
            q.negate()
        prev = q
        ob.location = p
        ob.rotation_quaternion = q
        ob.keyframe_insert("location", frame=f)
        ob.keyframe_insert("rotation_quaternion", frame=f)


def trail(sc, ob):
    gold = fx.fade_material("Sparkle", GOLD, 12.0, power=1.4)
    inst = bpy.data.objects.new("SparkleInst", gc.ico_mesh("SparkleInst", 1.0, 1))
    inst.data.materials.append(gold)
    sc.collection.objects.link(inst)
    inst.location = (0, 0, -1000)
    ob.modifiers.new("Sparkles", "PARTICLE_SYSTEM")
    st = ob.particle_systems[0].settings
    st.count, st.frame_start, st.frame_end = 700, 4, 104
    st.lifetime, st.lifetime_random = 26, 0.5
    st.emit_from, st.use_emit_random = "FACE", True
    st.normal_factor, st.factor_random = 0.05, 0.2
    st.effector_weights.gravity = 0.12
    st.render_type, st.instance_object = "OBJECT", inst
    st.particle_size, st.size_random = 0.025, 0.7
    ob.show_instancer_for_render = True


def build_show(sc, opts):
    ob = build(sc, 0.35)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.9, hdri="sunset.exr", follow=ob, lights=0.85, fog=(2.0, 6), streak=10.0)
    animate(ob)
    trail(sc, ob)
    sh.screen_extent(sc, cam, [ob], (LOOP, 42, 55, 68, EXIT))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Hovering three-quarter view, rippling on an exact loop, sparkles drifting off."""
    n = stage.ICON_N
    ob = build(sc, 2 * math.pi / n)
    cam = stage.setup_icon(sc, opts["samples"], world=0.9, hdri="sunset.exr", follow=ob, lights=0.85, fog=(2.0, 6), streak=10.0)
    for f in range(0, n + 1):
        w = 2 * math.pi * f / n
        ob.location = (0.0, 0.0, 0.08 * math.sin(w))
        ob.rotation_euler = (R(38) + R(3) * math.sin(w), R(-6) * math.sin(w + 1), R(-35))
        ob.keyframe_insert("location", frame=f)
        ob.keyframe_insert("rotation_euler", frame=f)
    sc.frame_set(1)
    stage.frame_icon(cam, [ob], pad=1.2)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
