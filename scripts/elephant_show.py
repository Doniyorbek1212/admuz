"""UZARO v2 show: elephant (tier 3, 144 f = 6 s).

An elephant in an original gold-embroidered festive cloth walks in, stops, raises its trunk and trumpets, and a spray of
glittering water arcs up from the trunk; then it walks on and out. The file's Walk and Attack takes are mixed in the
NLA; the walk speed is measured from the feet so they do not slide. The cloth is draped on the body by ray casts and
skinned with the body's own weights, so it moves with the walk.
"""
import math
import os
import statistics
import sys

import bpy
from mathutils import Vector, kdtree
from mathutils.bvhtree import BVHTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, env  # noqa: E402

ID = "elephant"
TOTAL = 144
SIZE = 4.6
GROUND_Z = -3.6
YAW = R(70)                              # head (-Y) turned to walk right and a little toward the lens
WALK, ACT = "02_Walk", "05_Attack"
STOP, GO = 48, 104                       # walk ends / resumes; the trunk take plays in between
ACT_FRAMES = (6, 66)                     # trunk up around 36-48 of the take
BLEND = 8
SPRAY = (80, 98)
FOOT = "DEF-pad_fore.L_60"
TIP = "DEF-trunk_finger_up_0"
CRIMSON, GOLD = (0.32, 0.015, 0.05), (1.0, 0.7, 0.28)


def load():
    objs = gc.import_glb(os.path.join(gc.MODELS, f"{ID}.glb"), hide=("Icosphere",))
    objs = [o for o in objs if "Icosphere" not in o.name]
    root, _ = gc.normalize(objs, SIZE, name="Elephant")
    arm = next(o for o in objs if o.type == "ARMATURE")
    meshes = [o for o in objs if o.type == "MESH"]
    body = max(meshes, key=lambda o: len(o.data.vertices))
    for m in body.data.materials:
        stage.shiny(m, coat=0.0, sheen=0.25)
    return root, arm, meshes, body


def action(name):
    return next(a for a in bpy.data.actions if a.name.startswith(name))


def walk_speed(sc, arm):
    """World units per frame: how fast a planted forefoot slides back in the in-place walk take."""
    arm.animation_data.action = action(WALK)
    lo, hi = map(int, action(WALK).frame_range)
    pts = []
    for f in range(lo, hi + 1):
        sc.frame_set(f)
        pts.append((arm.matrix_world @ arm.pose.bones[FOOT].head).copy())
    floor = min(p.z for p in pts)
    span = max(p.z for p in pts) - floor
    steps = [b.y - a.y for a, b in zip(pts, pts[1:]) if a.z < floor + 0.08 * span and b.z < floor + 0.08 * span]
    arm.animation_data.action = None
    v = statistics.median([s for s in steps if s > 0]) if steps else 0.02
    print("WALK SPEED", round(v, 4), "per frame over", hi - lo, "frames;", len(steps), "stance samples")
    return v, hi - lo


def nla(arm, cycle):
    """Walk on a loop underneath; the trunk take on top, blended in and out."""
    ad = arm.animation_data or arm.animation_data_create()
    ad.action = None
    walk = ad.nla_tracks.new()
    walk.name = "Walk"
    s = walk.strips.new("Walk", 1, action(WALK))
    s.repeat = math.ceil(TOTAL / cycle) + 1
    top = ad.nla_tracks.new()
    top.name = "Trunk"
    a = top.strips.new("Trunk", STOP - BLEND // 2, action(ACT))
    a.action_frame_start, a.action_frame_end = ACT_FRAMES
    a.frame_end = a.frame_start + (ACT_FRAMES[1] - ACT_FRAMES[0])
    a.blend_in = a.blend_out = BLEND
    a.blend_type = "REPLACE"
    a.extrapolation = "NOTHING"
    return a.frame_start, a.frame_end


def trunk_weight(f, start, end):
    """Influence of the trunk take at f, as the NLA blends it (linear ramps)."""
    if f <= start or f >= end:
        return 0.0
    return min(1.0, (f - start) / BLEND, (end - f) / BLEND)


def animate(root, v, start, end):
    d = Vector((math.sin(YAW), -math.cos(YAW), 0.0))
    dist, travel = 0.0, {}
    for f in range(1, TOTAL + 1):
        travel[f] = dist
        dist += v * (1.0 - trunk_weight(f + 0.5, start, end))
    stop = Vector((-0.4, 0.6, 0.0))                           # ground lift is added on the keys afterwards
    for f in range(1, TOTAL + 1):
        root.location = stop + d * (travel[f] - travel[STOP + 2])
        root.keyframe_insert("location", frame=f)
    root.rotation_euler = (0.0, 0.0, YAW)


def ground(root, meshes):
    """Lift the root so the feet stand on GROUND_Z at the walk's lowest point."""
    bpy.context.view_layer.update()
    lo, _ = gc.world_bbox(meshes)
    return GROUND_Z - lo.z


# ---------------------------------------------------------------- festive cloth
def cloth_material():
    """Original design: crimson velvet, a gold border band with a running zigzag, gold rosettes in a lattice."""
    m = stage.pbr("Caparison", CRIMSON, roughness=0.6)
    b = stage.bsdf(m)
    b.inputs["Sheen Weight"].default_value = 0.8
    b.inputs["Sheen Roughness"].default_value = 0.35
    nt = m.node_tree
    N, L = nt.nodes.new, nt.links.new

    def math_node(op, a, bb=None, clamp=False):
        n = N("ShaderNodeMath")
        n.operation, n.use_clamp = op, clamp
        for i, x in enumerate((a, bb)):
            if x is None:
                continue
            if isinstance(x, (int, float)):
                n.inputs[i].default_value = x
            else:
                L(x, n.inputs[i])
        return n.outputs[0]

    uv = N("ShaderNodeUVMap")
    sep = N("ShaderNodeSeparateXYZ")
    L(uv.outputs[0], sep.inputs[0])
    u, w = sep.outputs["X"], sep.outputs["Y"]               # u along the body 0..1, w from hem to hem 0..1
    # border: within 0.09 of either hem, and of the front and back edges
    edge = math_node("MINIMUM", math_node("MINIMUM", w, math_node("SUBTRACT", 1.0, w)),
                     math_node("MULTIPLY", math_node("MINIMUM", u, math_node("SUBTRACT", 1.0, u)), 1.6))
    band = math_node("LESS_THAN", edge, 0.09)
    inner = math_node("LESS_THAN", edge, 0.06)
    zig = math_node("ABSOLUTE", math_node("SUBTRACT", math_node("PINGPONG", math_node("MULTIPLY", math_node("ADD", u, w), 14.0), 1.0), 0.5))
    zigline = math_node("LESS_THAN", math_node("ABSOLUTE", math_node("SUBTRACT", math_node("MULTIPLY", edge, 11.0), math_node("ADD", zig, 0.12))), 0.08)
    border = math_node("MAXIMUM", math_node("MULTIPLY", band, math_node("SUBTRACT", 1.0, inner)), math_node("MULTIPLY", inner, zigline))
    # rosettes: 8 petals in each lattice cell
    cu = math_node("SUBTRACT", math_node("FRACT", math_node("MULTIPLY", u, 4.0)), 0.5)
    cw = math_node("SUBTRACT", math_node("FRACT", math_node("MULTIPLY", w, 3.0)), 0.5)
    r = math_node("SQRT", math_node("ADD", math_node("MULTIPLY", cu, cu), math_node("MULTIPLY", cw, cw)))
    ang = math_node("ARCTAN2", cw, cu)
    petal = math_node("ADD", 0.22, math_node("MULTIPLY", math_node("COSINE", math_node("MULTIPLY", ang, 8.0)), 0.07))
    outline = math_node("LESS_THAN", math_node("ABSOLUTE", math_node("SUBTRACT", r, petal)), 0.025)
    dot = math_node("LESS_THAN", r, 0.07)
    ring = math_node("LESS_THAN", math_node("ABSOLUTE", math_node("SUBTRACT", r, 0.4)), 0.012)
    rose = math_node("MULTIPLY", math_node("MAXIMUM", math_node("MAXIMUM", outline, dot), ring), math_node("SUBTRACT", 1.0, band))
    gold = math_node("MAXIMUM", border, rose, clamp=True)
    mix = N("ShaderNodeMix")
    mix.data_type = "RGBA"
    mix.inputs["A"].default_value = (*CRIMSON, 1)
    mix.inputs["B"].default_value = (*GOLD, 1)
    L(gold, mix.inputs["Factor"])
    L(mix.outputs["Result"], b.inputs["Base Color"])
    L(gold, b.inputs["Metallic"])
    rough = N("ShaderNodeMapRange")
    rough.inputs["To Min"].default_value, rough.inputs["To Max"].default_value = 0.6, 0.28
    L(gold, rough.inputs["Value"])
    L(rough.outputs["Result"], b.inputs["Roughness"])
    bump = N("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.5
    bump.inputs["Distance"].default_value = 0.01
    L(gold, bump.inputs["Height"])
    L(bump.outputs[0], b.inputs["Normal"])
    return m


def drape(sc, arm, body):
    """Saddle cloth: cast rays at the spine from a fan of directions over the back; hit + offset, then skin it."""
    arm.data.pose_position = "REST"                         # build on the bind shape, the rig poses it afterwards
    bpy.context.view_layer.update()
    mw = body.matrix_world
    bvh = BVHTree.FromPolygons([mw @ v.co for v in body.data.vertices], [p.vertices[:] for p in body.data.polygons])
    spine = [arm.matrix_world @ arm.data.bones[n].head_local for n in ("DEF-spine_01_81", "DEF-spine_02_79", "DEF-spine_03_78", "DEF-spine_04_59")]
    back, front = spine[0], spine[-1]
    side = (front - back).cross(Vector((0.0, 0.0, 1.0))).normalized()   # the body is already yawed: fan across it
    nu, nw, reach = 22, 30, R(108)
    rows = []
    for i in range(nu + 1):
        t = i / nu
        c = back.lerp(front, -0.12 + 1.2 * t)
        row = []
        for j in range(nw + 1):
            a = -reach + 2 * reach * j / nw
            out = side * math.sin(a) + Vector((0.0, 0.0, math.cos(a)))
            hit = bvh.ray_cast(c + out * 3.0, -out)
            p = hit[0] if hit[0] is not None else c + out * 0.5
            row.append(p + out * 0.04 * SIZE / 4.6)
        rows.append(row)
    for row in rows:                                          # hems hang straight down a little below the hits
        for j in (0, nw):
            row[j] = row[j] + Vector((0, 0, -0.12))
    verts = [p for row in rows for p in row]
    faces = [(i * (nw + 1) + j, i * (nw + 1) + j + 1, (i + 1) * (nw + 1) + j + 1, (i + 1) * (nw + 1) + j) for i in range(nu) for j in range(nw)]
    me = bpy.data.meshes.new("Caparison")
    me.from_pydata([tuple(v) for v in verts], [], faces)
    uvl = me.uv_layers.new()
    for poly in me.polygons:
        for li, vi in zip(poly.loop_indices, poly.vertices):
            uvl.data[li].uv = ((vi // (nw + 1)) / nu, (vi % (nw + 1)) / nw)
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    ob = stage.link(sc, "Caparison", me, cloth_material())
    sol = ob.modifiers.new("Thick", "SOLIDIFY")
    sol.thickness, sol.offset = 0.012, -1.0
    skin_like(ob, body, arm)
    arm.data.pose_position = "POSE"
    return ob


def skin_like(ob, body, arm):
    """Copy the nearest body vertex's weights to each cloth vertex; same armature."""
    mw = body.matrix_world
    kd = kdtree.KDTree(len(body.data.vertices))
    for v in body.data.vertices:
        kd.insert(mw @ v.co, v.index)
    kd.balance()
    names = {g.index: g.name for g in body.vertex_groups}
    groups = {}
    for v in ob.data.vertices:
        _, idx, _ = kd.find(ob.matrix_world @ v.co)
        for g in body.data.vertices[idx].groups:
            name = names[g.group]
            if name not in groups:
                groups[name] = ob.vertex_groups.new(name=name)
            groups[name].add([v.index], g.weight, "REPLACE")
    ob.data.transform(arm.matrix_world.inverted())            # world -> armature space; the object then sits on the armature
    ob.parent = arm
    mod = ob.modifiers.new("Rig", "ARMATURE")
    mod.object = arm
    bpy.context.view_layer.update()


# ---------------------------------------------------------------- water spray
def tip_empty(sc, arm):
    e = bpy.data.objects.new("TrunkTip", None)
    sc.collection.objects.link(e)
    c = e.constraints.new("COPY_LOCATION")
    c.target, c.subtarget = arm, TIP
    return e


def spray(sc, tip):
    d = Vector((math.sin(YAW), -math.cos(YAW), 0.0))
    drop = stage.pbr("Spray", (0.85, 0.93, 1.0), roughness=0.05, coat=1.0, emission=(0.65, 0.8, 0.95), strength=0.9)
    jet = d * 1.4 + Vector((0, 0, 4.2))
    em = fx.particle_burst(sc, "Spray", gc.ico_mesh("SprayE", 0.05, 1), drop, 900, SPRAY, 30, 0.03, 0.3, rand=0.5,
                           align=tuple(jet), gravity=0.9)
    em.parent = tip
    glit = fx.fade_material("Glitter", (1.0, 0.82, 0.45), 14.0, power=1.2)
    g = fx.particle_burst(sc, "Glitter", gc.ico_mesh("GlitterE", 0.05, 1), glit, 260, SPRAY, 30, 0.022, 0.3, rand=0.6,
                          align=tuple(jet * 0.95), gravity=0.85)
    g.parent = tip
    mist = fx.fade_material("SprayMist", (0.92, 0.96, 1.0), 0.8, 0.04, 1.2)
    m = fx.particle_burst(sc, "SprayMist", gc.ico_mesh("SprayMistE", 0.05, 1), mist, 70, (SPRAY[0] + 4, SPRAY[1]), 26, 0.3, 0.2, rand=0.5,
                          align=tuple(jet * 0.8), damping=0.15, gravity=0.3)
    m.parent = tip


def build_show(sc, opts):
    root, arm, meshes, body = load()
    v, cycle = walk_speed(sc, arm)
    start, end = nla(arm, cycle)
    root.rotation_euler = (0.0, 0.0, YAW)
    sc.frame_set(STOP)
    lift = ground(root, meshes)
    animate(root, v, start, end)
    for fc in root.animation_data.action.fcurves:
        if fc.array_index == 2:
            for kp in fc.keyframe_points:      # handles too: left behind they swing the curve between keys
                kp.co.y += lift
                kp.handle_left.y += lift
                kp.handle_right.y += lift
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.85, hdri="sunrise.exr", follow=None, lights=0.8, fog=(2.0, 6), streak=10.0)
    sh.shadow_catcher(sc, GROUND_Z, 50)
    sc.frame_set(1)
    drape(sc, arm, body)
    tip = tip_empty(sc, arm)
    spray(sc, tip)
    sh.screen_extent(sc, cam, meshes, (1, 30, STOP + 30, 90, GO + 20, TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Standing elephant, trunk raised, a small fountain from the trunk: the take loops on its trunk-up hold."""
    root, arm, meshes, body = load()
    cam = stage.setup_icon(sc, opts["samples"], world=0.9, hdri="sunrise.exr", lights=0.85, fog=(2.0, 6), streak=8.0)
    root.rotation_euler = (0.0, 0.0, R(40))
    ad = arm.animation_data or arm.animation_data_create()
    tr = ad.nla_tracks.new()
    n = stage.ICON_N
    s = tr.strips.new("Hold", 0, action(ACT))
    s.action_frame_start, s.action_frame_end = 38, 46                 # trunk-up hold: forward then back = seamless
    s.frame_end = n / 2
    s2 = tr.strips.new("HoldBack", int(n / 2), action(ACT))
    s2.action_frame_start, s2.action_frame_end = 38, 46
    s2.frame_end = n
    s2.use_reverse = True
    sc.frame_set(1)
    drape(sc, arm, body)
    stage.frame_icon(cam, meshes, pad=1.08)
    sh.shadow_catcher(sc, gc.world_bbox(meshes)[0].z, 30)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
