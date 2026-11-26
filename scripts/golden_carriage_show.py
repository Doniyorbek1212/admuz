"""UZARO v2 show: golden carriage (tier 4, 168 f = 7 s).

Two white horses gallop out of the distance pulling a golden carriage along a road of light that is laid under the
wheels as they come. The team sweeps toward the camera in a 3/4 front view, the wheels turning with the ground they
cover, then curves away and leaves frame right in a wake of gold dust and sparkles.

Carriage: "Royal carriage" by akiprensky (CC BY); its state emblems are deleted (they are separate relief islands) and
it is re-skinned in gold from its own texture masks. Horses: the batch 1 horse with a pearl-white coat, mane and tail
hair.

    blender -b --factory-startup -P golden_carriage_show.py -- <show|icon> [f=1,60,100] [s=16]
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import animal  # noqa: E402
import gift_common as gc  # noqa: E402
import horse_show as hs  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, env, interp  # noqa: E402

ID = "golden_carriage"
TOTAL = 168
K = 0.6                      # whole team scale (horse joints are measured at horse size 6)
HORSE = 6.0
CARRIAGE = 6.6
STRIDE = 1.45                # gallop strides run a little faster than the ground (reads as speed, slip hidden by blur)
FOOT = 2.33                  # horse centre above its hooves at size 6
GROUND_Z = -2.6
TEX = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "textures", "golden_carriage")
X, Z = animal.X, animal.Z
GOLD = (1.0, 0.7, 0.28)
# team path on the ground (world x, y): out of the distance on the right, sweeping toward the camera, out frame left
PATH = [(12.5, 20.0), (6.5, 13.5), (1.8, 8.6), (-1.8, 5.0), (-5.8, 1.8), (-13.0, -2.0)]
PACE = [(1, 0.02), (56, 0.36), (112, 0.6), (TOTAL, 1.0)]   # share of the path: lingers through the middle
EMBLEM_VERTS = 379           # the emblem fill island; its relief walls are the small islands inside its box
# carriage file space (import world): wheel axles at (x, z) with radius, front is +X
WHEELS = (("Front", 2.52, -0.24, 0.79), ("Rear", -2.45, 0.025, 1.06))
TEAM_GAP = 1.25              # pole length between the horses' rumps and the carriage front (team space, size 6)


# ------------------------------------------------------------------ path
def path_samples(n=600):
    pts = [Vector((*stage.catmull(PATH, i / n), 0.0)) for i in range(n + 1)]
    acc = [0.0]
    for a, b in zip(pts, pts[1:]):
        acc.append(acc[-1] + (b - a).length)
    return pts, acc


PTS, ACC = None, None


def at_dist(d):
    """Point and unit tangent at arc length d along the path."""
    d = max(0.0, min(ACC[-1] - 1e-4, d))
    lo, hi = 0, len(ACC) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if ACC[mid] <= d:
            lo = mid
        else:
            hi = mid
    t = (d - ACC[lo]) / max(ACC[hi] - ACC[lo], 1e-9)
    p = PTS[lo].lerp(PTS[hi], t)
    tan = (PTS[hi] - PTS[lo]).normalized()
    return p, tan


def team_dist(f):
    """Arc length of the team (carriage centre) at frame f."""
    return ACC[-1] * pace(f)


def pace(f):
    """Smooth through the PACE keys (monotone: catmull through keys spaced in frames)."""
    for (f0, v0), (f1, v1) in zip(PACE, PACE[1:]):
        if f <= f1:
            t = (f - f0) / (f1 - f0)
            # cubic Hermite with slopes from neighbours keeps the speed continuous
            i = PACE.index((f0, v0))
            def slope(j):
                a = PACE[max(j - 1, 0)]
                b = PACE[min(j + 1, len(PACE) - 1)]
                return (b[1] - a[1]) / (b[0] - a[0])
            m0, m1 = slope(i) * (f1 - f0), slope(i + 1) * (f1 - f0)
            h00, h10, h01, h11 = 2 * t ** 3 - 3 * t ** 2 + 1, t ** 3 - 2 * t ** 2 + t, -2 * t ** 3 + 3 * t ** 2, t ** 3 - t ** 2
            return h00 * v0 + h10 * m0 + h01 * v1 + h11 * m1
    return PACE[-1][1]


# ------------------------------------------------------------------ carriage
def kill_emblems(meshes):
    """Delete each emblem: the fill island and every small island inside its box (the relief walls)."""
    for o in meshes:
        bm = bmesh.new()
        bm.from_mesh(o.data)
        seen, comps = set(), []
        for v in bm.verts:
            if v.index in seen:
                continue
            stack, comp = [v], []
            seen.add(v.index)
            while stack:
                x = stack.pop()
                comp.append(x)
                for e in x.link_edges:
                    w = e.other_vert(x)
                    if w.index not in seen:
                        seen.add(w.index)
                        stack.append(w)
            comps.append(comp)
        boxes = []
        for comp in comps:
            if len(comp) == EMBLEM_VERTS:
                lo = Vector([min(x.co[i] for x in comp) for i in range(3)])
                hi = Vector([max(x.co[i] for x in comp) for i in range(3)])
                pad = 0.03 * max(hi - lo)
                boxes.append((lo - Vector((pad,) * 3), hi + Vector((pad,) * 3)))
        kill = []
        for comp in comps:
            if len(comp) > EMBLEM_VERTS:
                continue
            for lo, hi in boxes:
                if all(all(lo[i] <= x.co[i] <= hi[i] for i in range(3)) for x in comp):
                    kill += comp
                    break
        print("EMBLEM", o.name, len(boxes), "boxes,", len(kill), "verts removed")
        bmesh.ops.delete(bm, geom=kill, context="VERTS")
        bm.to_mesh(o.data)
        bm.free()


def gold_material(mat):
    """Gold carriage from the file's own texture: gold trim stays polished gold, black lacquer becomes satin gold with
    an engraved pattern, red velvet stays red, grey glass becomes dark glass."""
    nt = mat.node_tree
    b = stage.bsdf(mat)
    base = next(n for n in nt.nodes if n.type == "TEX_IMAGE" and b.inputs["Base Color"].links and n == b.inputs["Base Color"].links[0].from_node)
    base.image = bpy.data.images.load(os.path.join(TEX, "base_clean.png"))
    for n in nt.nodes:
        if n.type == "NORMAL_MAP" and n.inputs["Color"].links:
            n.inputs["Color"].links[0].from_node.image = bpy.data.images.load(os.path.join(TEX, "normal_clean.png"))
            n.inputs["Color"].links[0].from_node.image.colorspace_settings.name = "Non-Color"
    for name in ("Base Color", "Metallic", "Roughness"):
        for lk in list(b.inputs[name].links):
            nt.links.remove(lk)
    N, L = nt.nodes.new, nt.links.new
    hsv = N("ShaderNodeSeparateColor")
    hsv.mode = "HSV"
    L(base.outputs["Color"], hsv.inputs["Color"])

    def ramp(sock, a, b_, invert=False):
        m = N("ShaderNodeMapRange")
        m.interpolation_type = "SMOOTHSTEP"
        m.inputs["From Min"].default_value, m.inputs["From Max"].default_value = a, b_
        if invert:
            m.inputs["To Min"].default_value, m.inputs["To Max"].default_value = 1.0, 0.0
        L(sock, m.inputs["Value"])
        return m.outputs["Result"]

    def mul(a, b_):
        m = N("ShaderNodeMath")
        m.operation = "MULTIPLY"
        L(a, m.inputs[0])
        L(b_, m.inputs[1])
        return m.outputs[0]
    sat = ramp(hsv.outputs["Green"], 0.3, 0.5)
    hue_gold = mul(ramp(hsv.outputs["Red"], 0.04, 0.07), ramp(hsv.outputs["Red"], 0.14, 0.18, invert=True))
    trim = mul(sat, hue_gold)
    red_hue = N("ShaderNodeMath")                 # red wraps round hue 0
    red_hue.operation, red_hue.use_clamp = "ADD", True
    L(ramp(hsv.outputs["Red"], 0.03, 0.01), red_hue.inputs[0])
    L(ramp(hsv.outputs["Red"], 0.86, 0.9), red_hue.inputs[1])
    red = mul(sat, red_hue.outputs[0])
    glass = mul(ramp(hsv.outputs["Green"], 0.15, 0.05), ramp(hsv.outputs["Blue"], 0.15, 0.25))
    # engraved arabesque on the lacquer: two crossed wave bands (original pattern)
    tc = N("ShaderNodeTexCoord")
    w1, w2 = N("ShaderNodeTexWave"), N("ShaderNodeTexWave")
    for w, sc_, rot in ((w1, 22.0, "X"), (w2, 22.0, "Y")):
        w.wave_type, w.rings_direction = "RINGS", "SPHERICAL"
        w.inputs["Scale"].default_value = sc_
        w.inputs["Distortion"].default_value = 6.0
        w.inputs["Detail"].default_value = 1.0
        L(tc.outputs["Object"], w.inputs["Vector"])
    w2.wave_profile = "SAW"
    eng = N("ShaderNodeMath")
    eng.operation = "MINIMUM"
    L(w1.outputs["Fac"], eng.inputs[0])
    L(w2.outputs["Fac"], eng.inputs[1])
    col = N("ShaderNodeMix")
    col.data_type = "RGBA"
    col.inputs["A"].default_value = (0.7, 0.38, 0.07, 1)        # satin body gold
    col.inputs["B"].default_value = (1.0, 0.72, 0.26, 1)        # polished trim gold
    L(trim, col.inputs["Factor"])
    col2 = N("ShaderNodeMix")
    col2.data_type = "RGBA"
    L(col.outputs["Result"], col2.inputs["A"])
    col2.inputs["B"].default_value = (0.42, 0.03, 0.06, 1)
    L(red, col2.inputs["Factor"])
    col3 = N("ShaderNodeMix")
    col3.data_type = "RGBA"
    L(col2.outputs["Result"], col3.inputs["A"])
    col3.inputs["B"].default_value = (0.25, 0.1, 0.03, 1)
    L(glass, col3.inputs["Factor"])
    L(col3.outputs["Result"], b.inputs["Base Color"])
    metal = N("ShaderNodeMath")
    metal.operation = "SUBTRACT"
    metal.inputs[0].default_value = 1.0
    nonmetal = N("ShaderNodeMath")
    nonmetal.operation, nonmetal.use_clamp = "ADD", True
    L(red, nonmetal.inputs[0])
    L(glass, nonmetal.inputs[1])
    L(nonmetal.outputs[0], metal.inputs[1])
    L(metal.outputs[0], b.inputs["Metallic"])
    rough = N("ShaderNodeMapRange")
    rough.inputs["To Min"].default_value, rough.inputs["To Max"].default_value = 0.34, 0.18
    L(trim, rough.inputs["Value"])
    rough2 = N("ShaderNodeMath")
    rough2.operation = "ADD"
    L(rough.outputs["Result"], rough2.inputs[0])
    rr = N("ShaderNodeMath")
    rr.operation = "MULTIPLY"
    rr.inputs[1].default_value = 0.5
    L(red, rr.inputs[0])
    L(rr.outputs[0], rough2.inputs[1])
    L(rough2.outputs[0], b.inputs["Roughness"])
    bump = N("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.25
    bump.inputs["Distance"].default_value = 0.02
    lac = N("ShaderNodeMath")
    lac.operation = "MULTIPLY"
    L(eng.outputs[0], lac.inputs[0])
    inv = N("ShaderNodeMath")
    inv.operation = "SUBTRACT"
    inv.inputs[0].default_value = 1.0
    L(trim, inv.inputs[1])
    L(inv.outputs[0], lac.inputs[1])
    L(lac.outputs[0], bump.inputs["Height"])
    if b.inputs["Normal"].links:
        L(b.inputs["Normal"].links[0].from_socket, bump.inputs["Normal"])
    L(bump.outputs["Normal"], b.inputs["Normal"])
    b.inputs["Coat Weight"].default_value = 0.12        # a sharp coat threw a sun glare across the flat panels
    b.inputs["Coat Roughness"].default_value = 0.2
    b.inputs["Emission Color"].default_value = (1.0, 0.55, 0.2, 1)
    lamp = N("ShaderNodeMath")                    # windows glow warm from inside instead of mirroring the sky
    lamp.operation = "MULTIPLY"
    lamp.inputs[1].default_value = 2.5
    L(glass, lamp.inputs[0])
    L(lamp.outputs[0], b.inputs["Emission Strength"])
    b.inputs["Specular IOR Level"].default_value = 0.3


def split_wheels(model, meshes):
    """Wheel vertices (outer planes, inside the rim radius) become one object per wheel, pivoting on its axle."""
    src = next(o for o in meshes if o.name.startswith("Object003"))
    mw = src.matrix_world.copy()
    inv = mw.inverted()
    out = []
    file_to_world = model.matrix_world    # import world -> normalised world
    for name, cx, cz, r in WHEELS:
        for side, sgn in (("L", -1.0), ("R", 1.0)):
            bm = bmesh.new()
            bm.from_mesh(src.data)
            keep = set()
            for v in bm.verts:
                p = mw @ v.co
                q = file_to_world.inverted() @ p
                if (q.x - cx) ** 2 + (q.z - cz) ** 2 <= (r + 0.04) ** 2 and q.y * sgn > 1.0:
                    keep.add(v.index)
            other = [v for v in bm.verts if v.index not in keep]
            bmesh.ops.delete(bm, geom=other, context="VERTS")
            me = bpy.data.meshes.new(f"Wheel{name}{side}")
            bm.to_mesh(me)
            bm.free()
            for m in src.data.materials:
                me.materials.append(m)
            ob = bpy.data.objects.new(f"Wheel{name}{side}", me)
            bpy.context.scene.collection.objects.link(ob)
            axle = file_to_world @ Vector((cx, 0.0, cz))
            ob.data.transform(Matrix.Translation(-(inv @ axle)))
            ob.parent = src.parent
            ob.matrix_parent_inverse = src.matrix_parent_inverse.copy()
            ob.matrix_basis = src.matrix_basis @ Matrix.Translation(inv @ axle)
            ob.rotation_mode = "AXIS_ANGLE"
            axis = (inv.to_3x3() @ file_to_world.to_3x3() @ Vector((0.0, 1.0, 0.0))).normalized()   # file +Y in mesh space
            ob.rotation_axis_angle = (0.0, *axis)
            ob["world_axle"] = tuple(axle)
            out.append((ob, r * file_to_world.to_scale()[0]))
        # remove the same vertices from the source mesh
    bm = bmesh.new()
    bm.from_mesh(src.data)
    gone = []
    for v in bm.verts:
        q = file_to_world.inverted() @ (mw @ v.co)
        for _, cx, cz, r in WHEELS:
            if (q.x - cx) ** 2 + (q.z - cz) ** 2 <= (r + 0.04) ** 2 and abs(q.y) > 1.0:
                gone.append(v)
                break
    bmesh.ops.delete(bm, geom=gone, context="VERTS")
    bm.to_mesh(src.data)
    bm.free()
    return out


def load_carriage(sc, team):
    root, model, objs, meshes = stage.load("golden_carriage", CARRIAGE, rot=(0.0, 0.0, R(-90)))
    file_space = model.matrix_world.copy()
    kill_emblems(meshes)
    for m in meshes:
        for s in m.data.materials:
            if s and s.use_nodes and "Gilded" not in s:
                gold_material(s)
                s["Gilded"] = True
    bpy.context.view_layer.update()
    wheels = split_wheels(model, meshes)
    lo, hi = gc.world_bbox(meshes + [w for w, _ in wheels])
    root.parent = team
    root.location = (0.0, 0.0, -lo.z)          # wheels on the ground (team z = 0)
    _ = file_space
    return root, meshes, wheels, (lo, hi)


# ------------------------------------------------------------------ horses
def whiten(mat):
    """Pearl-white coat that keeps the texture's light and shade."""
    b, nt = stage.bsdf(mat), mat.node_tree
    if b.inputs["Base Color"].links:
        src = b.inputs["Base Color"].links[0].from_socket
        bw = nt.nodes.new("ShaderNodeRGBToBW")
        nt.links.new(src, bw.inputs[0])
        rng = nt.nodes.new("ShaderNodeMapRange")
        rng.inputs["From Min"].default_value, rng.inputs["From Max"].default_value = 0.0, 0.5
        rng.inputs["To Min"].default_value, rng.inputs["To Max"].default_value = 0.62, 0.9
        nt.links.new(bw.outputs[0], rng.inputs["Value"])
        mix = nt.nodes.new("ShaderNodeMix")
        mix.data_type, mix.blend_type = "RGBA", "MULTIPLY"
        mix.inputs["Factor"].default_value = 1.0
        mix.inputs["B"].default_value = (1.0, 0.97, 0.92, 1.0)
        nt.links.new(rng.outputs["Result"], mix.inputs["A"])
        nt.links.new(mix.outputs["Result"], b.inputs["Base Color"])
    stage.shiny(mat, roughness=0.45, sheen=0.6)
    b.inputs["Subsurface Weight"].default_value = 0.05


TAIL_DOCK = (Vector((0, 2.3, 1.1)), Vector((0, 2.65, 0.3)))     # hs.JOINTS tail[0] -> tail[1]


def tail_dist(co):
    a, b = TAIL_DOCK
    t = max(0.0, min(1.0, (co - a).dot(b - a) / (b - a).length_squared))
    return (co - a.lerp(b, t)).length


def mane_and_tail(m, seed):
    """White hair: a mane along the crest of the neck and a long tail, each combed back and down (horse size 6,
    crest positions from pegasus_show). On 4.2 a strand is 4x its start velocity long, so the comb is the velocity."""
    mane, tail = m.vertex_groups.new(name="Mane"), m.vertex_groups.new(name="Tail")
    a, c = Vector((-1.0, 1.05)), Vector((-2.3, 2.3))
    span = (c - a).length
    for v in m.data.vertices:
        p = Vector((v.co.y, v.co.z))
        u = (p - a).dot(c - a) / span ** 2
        off = (p - a.lerp(c, max(0.0, min(1.0, u)))).length
        crest = 0.0 <= u <= 1.05 and abs(v.co.x) < 0.14 and off < 0.2
        on_tail = tail_dist(v.co) < 0.3 and v.co.z > 0.4       # tail root dock only, not the rump
        mane.add([v.index], 1.0 if crest else 0.0, "REPLACE")
        tail.add([v.index], 1.0 if on_tail else 0.0, "REPLACE")
    out = []
    for vg, length, comb, count, sd in (("Mane", 0.38, (0.0, 0.7, -0.5), 260, seed),
                                        ("Tail", 1.5, (0.0, 0.4, -0.92), 160, seed + 1)):
        ps = animal.fur(m, length, count=count, children=12, radius=0.0022, density_vg=vg, length_vg=vg, clump=0.85,
                        multiply=(1.0, 0.98, 0.94), gamma=0.7, seed=sd)
        st = ps.settings
        d = Vector(comb).normalized() * length / 4.0
        st.normal_factor = 0.08 * length / 4.0
        st.object_align_factor = tuple(d)
        st.factor_random = 0.05 * length / 4.0
        st.kink, st.kink_amplitude, st.kink_frequency = "WAVE", 0.03, 1.6
        st.roughness_endpoint = 0.03
        out.append(ps)
    return out


def load_horse(sc, team, name, offset, seed):
    root, model, objs, meshes = stage.load("horse", HORSE)
    arm = animal.build(sc, name, hs.JOINTS, meshes, power=7.0)
    arm.parent = root
    root.parent = team
    root.location = offset
    for m in meshes:
        for s in m.data.materials:
            if s and "White" not in s:
                whiten(s)
                s["White"] = True
        mane_and_tail(m, seed)
    return root, arm, meshes


def harness(sc, team, horse_y, carriage_front):
    """Gold pole between the horses to the carriage, a cross bar and two traces to each horse's chest."""
    mat = stage.pbr("Harness", (1.0, 0.75, 0.34), metallic=1.0, roughness=0.2)
    leather = stage.pbr("Leather", (0.32, 0.08, 0.05), roughness=0.5, coat=0.3)
    parts = []

    def rod(name, a, b, r, m):
        a, b = Vector(a), Vector(b)
        me = stage.lathe(name, [(0, 0), (r, 0), (r, 1), (0, 1)], 12)
        ob = stage.link(sc, name, me, m, parent=team)
        d = b - a
        ob.matrix_basis = Matrix.Translation(a) @ d.to_track_quat("Z", "Y").to_matrix().to_4x4() @ Matrix.Diagonal((1, 1, d.length, 1))
        parts.append(ob)
    chest_z = 2.45
    rod("Pole", (0, carriage_front, 1.4), (0, horse_y - 1.6, chest_z), 0.07, mat)
    rod("Bar", (-1.35, horse_y + 2.6, 1.9), (1.35, horse_y + 2.6, 1.9), 0.06, mat)
    for x in (-1.0, 1.0):
        for dx in (-0.42, 0.42):
            rod(f"Trace{x}{dx}", (x * 1.0 + dx * 0.4, horse_y + 2.6, 1.9), (x * 1.0 + dx, horse_y - 1.3, chest_z), 0.035, leather)
    return parts


# ------------------------------------------------------------------ light road and dust
def light_road(sc, width=3.4):
    """A ribbon on the ground along the whole path; a keyed Head value reveals it just behind the front wheels."""
    verts, faces, uvs = [], [], []
    n = len(PTS) - 1
    for i, p in enumerate(PTS):
        tan = (PTS[min(i + 1, n)] - PTS[max(i - 1, 0)]).normalized()
        side = Vector((tan.y, -tan.x, 0.0))
        for k in (-1.0, 1.0):
            verts.append(tuple(p + side * width * 0.5 * k + Vector((0, 0, GROUND_Z + 0.01))))
            uvs.append((ACC[i], (k + 1) / 2))
    for i in range(n):
        faces.append((2 * i, 2 * i + 2, 2 * i + 3, 2 * i + 1))
    me = bpy.data.meshes.new("Road")
    me.from_pydata(verts, [], faces)
    uv = me.uv_layers.new(name="UVMap")
    for poly in me.polygons:
        for li in poly.loop_indices:
            uv.data[li].uv = uvs[me.loops[li].vertex_index]
    m = bpy.data.materials.new("RoadLight")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out = N("ShaderNodeOutputMaterial")
    uvn = N("ShaderNodeUVMap")
    sep = N("ShaderNodeSeparateXYZ")
    L(uvn.outputs[0], sep.inputs[0])
    head = N("ShaderNodeValue")
    head.name = "Head"
    behind = N("ShaderNodeMath")                  # metres behind the head
    behind.operation = "SUBTRACT"
    L(head.outputs[0], behind.inputs[0])
    L(sep.outputs["X"], behind.inputs[1])
    edge = N("ShaderNodeMapRange")                # 0 ahead of the head, 1 just behind
    edge.inputs["From Min"].default_value, edge.inputs["From Max"].default_value = -0.3, 0.6
    L(behind.outputs[0], edge.inputs["Value"])
    trail = N("ShaderNodeMapRange")               # fades over 14 m behind
    trail.inputs["From Min"].default_value, trail.inputs["From Max"].default_value = 0.0, 14.0
    trail.inputs["To Min"].default_value, trail.inputs["To Max"].default_value = 1.0, 0.0
    trail.interpolation_type = "SMOOTHSTEP"
    L(behind.outputs[0], trail.inputs["Value"])
    across = N("ShaderNodeMath")
    across.operation = "PINGPONG"
    across.inputs[1].default_value = 0.5
    L(sep.outputs["Y"], across.inputs[0])
    soft = N("ShaderNodeMapRange")
    soft.inputs["From Min"].default_value, soft.inputs["From Max"].default_value = 0.0, 0.35
    soft.interpolation_type = "SMOOTHSTEP"
    L(across.outputs[0], soft.inputs["Value"])
    noise = N("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 3.0
    noise.inputs["Detail"].default_value = 4.0
    L(uvn.outputs[0], noise.inputs["Vector"])
    shimmer = N("ShaderNodeMapRange")
    shimmer.inputs["From Min"].default_value, shimmer.inputs["From Max"].default_value = 0.35, 0.7
    shimmer.inputs["To Min"].default_value, shimmer.inputs["To Max"].default_value = 0.45, 1.0
    L(noise.outputs["Fac"], shimmer.inputs["Value"])
    a = None
    for s in (edge.outputs["Result"], trail.outputs["Result"], soft.outputs["Result"], shimmer.outputs["Result"]):
        if a is None:
            a = s
            continue
        mm = N("ShaderNodeMath")
        mm.operation, mm.use_clamp = "MULTIPLY", True
        L(a, mm.inputs[0])
        L(s, mm.inputs[1])
        a = mm.outputs[0]
    fade = N("ShaderNodeValue")
    fade.name = "Fade"
    mm = N("ShaderNodeMath")
    mm.operation, mm.use_clamp = "MULTIPLY", True
    L(a, mm.inputs[0])
    L(fade.outputs[0], mm.inputs[1])
    a = mm.outputs[0]
    em = N("ShaderNodeEmission")
    em.inputs["Color"].default_value = (1.0, 0.66, 0.24, 1)
    em.inputs["Strength"].default_value = 2.2
    tr = N("ShaderNodeBsdfTransparent")
    mix = N("ShaderNodeMixShader")
    L(a, mix.inputs[0])
    L(tr.outputs[0], mix.inputs[1])
    L(em.outputs[0], mix.inputs[2])
    L(mix.outputs[0], out.inputs["Surface"])
    m.surface_render_method = "BLENDED"
    ob = stage.link(sc, "Road", me, m, shadow=False)
    ob.visible_diffuse = ob.visible_glossy = False
    stage.key_socket(head.outputs[0], [(f, team_dist(f) - 0.6) for f in range(1, TOTAL + 1)])
    stage.key_socket(fade.outputs[0], [(1, 0.0), (8, 1.0), (TOTAL - 20, 1.0), (TOTAL, 0.0)])
    return ob


def ride(em, team, world_pos):
    """Emitter rides with the team at a point given in world space at load time (team at the origin)."""
    em.parent = team
    em.matrix_parent_inverse = Matrix(team["load_inv"])
    em.location = world_pos


def dust(sc, team, wheels_of):
    """Gold dust thrown off the back wheels and the hooves, and a few big star glints."""
    spark = fx.fade_material("GoldDust", (1.0, 0.76, 0.36), 9.0, 1.0, 1.5)
    out = []
    for i, (w, _) in enumerate(wheels_of):
        if "Rear" not in w.name:
            continue
        em = fx.particle_burst(sc, f"Dust{i}", fx.point_mesh(f"DustP{i}", 0.45), spark, 700, (1, TOTAL - 16), 30, 0.018, 0.25,
                               rand=1.0, damping=0.4, gravity=0.05, emit_from="VOLUME", align=(0.0, 0.0, 0.25))
        ride(em, team, Vector(w["load_pos"]))
        out.append(em)
    glint = fx.fade_material("Glint", (1.0, 0.9, 0.7), 22.0, 1.0, 2.2)
    for i, (w, _) in enumerate(wheels_of):
        if "Front" not in w.name:
            continue
        em = fx.particle_burst(sc, f"Glint{i}", fx.point_mesh(f"GlintP{i}", 0.3), glint, 60, (1, TOTAL - 16), 18, 0.035, 0.1,
                               rand=0.6, damping=0.5, gravity=0.0, emit_from="VOLUME")
        ride(em, team, Vector(w["load_pos"]))
        out.append(em)
    return out


# ------------------------------------------------------------------ animation
def animate(team, horses, wheels):
    frames = range(1, TOTAL + 1)
    movers = [(animal.Mover(arm, hs.GAIT, animal.GALLOP_PHASES), arm, ph) for _, arm, _, ph in horses]
    for f in frames:
        d = team_dist(f)
        p, tan = at_dist(d)
        heading = math.atan2(tan.x, -tan.y)
        team.location = (p.x, p.y, GROUND_Z)
        team.rotation_euler = (0.0, 0.0, heading)
        team.keyframe_insert("location", frame=f)
        team.keyframe_insert("rotation_euler", frame=f)
        gd = STRIDE * d / K                        # ground covered in horse space
        for mover, arm, ph in movers:
            bob = mover.legs_at(f, gd + ph, 1.0)
            c = math.cos(2 * math.pi * (gd + ph) / hs.CYCLE_DIST)
            mover.body(f, {
                "spine0": (X, 2.5 * c), "spine1": (X, -3.0 * c),
                "neck0": (X, 5.0 * c - 6.0), "neck1": (X, -4.0 * c - 4.0), "head": (X, 3.0 * c + 8.0),
                "earL0": (X, -12.0), "earR0": (X, -12.0),
                "tail0": (X, -22 + 6 * math.sin(f / 3.4 + ph)), "tail1": (X, -16 + 8 * math.sin(f / 3.4 - 0.9 + ph)),
                "tail2": (X, -10 + 9 * math.sin(f / 3.4 - 1.8 + ph)),
            })
            arm.location = (0.0, 0.0, bob + 0.12 * abs(math.sin(math.pi * (gd + ph) / hs.CYCLE_DIST)))
            arm.keyframe_insert("location", frame=f)
        for w, r in wheels:
            w.rotation_axis_angle[0] = d / (r * K)      # + about file +Y rolls the top toward the front (+X file)
            w.keyframe_insert("rotation_axis_angle", frame=f)
    for ob in [team] + [w for w, _ in wheels]:
        if ob.animation_data and ob.animation_data.action:
            for fc in ob.animation_data.action.fcurves:
                for kp in fc.keyframe_points:
                    kp.interpolation = "LINEAR"


def load(sc):
    global PTS, ACC
    PTS, ACC = path_samples()
    team = bpy.data.objects.new("Team", None)
    sc.collection.objects.link(team)
    team.rotation_mode = "XYZ"
    team.scale = (K, K, K)
    croot, cmeshes, wheels, (lo, hi) = load_carriage(sc, team)
    front = lo.y                                    # carriage front (nose toward -Y)
    horse_y = front - TEAM_GAP - HORSE * 0.45
    horses = []
    for name, x, seed, ph in (("HorseL", 0.95, 3, 0.0), ("HorseR", -0.95, 7, 1.3)):
        root, arm, meshes = load_horse(sc, team, name, (x, horse_y, FOOT), seed)
        horses.append((root, arm, meshes, ph))
    harness(sc, team, horse_y, front)
    bpy.context.view_layer.update()
    team["load_inv"] = [list(r) for r in team.matrix_world.inverted()]
    for w, _ in wheels:
        w["load_pos"] = tuple(w.matrix_world.translation)
    return team, horses, croot, cmeshes, wheels


def all_meshes(horses, cmeshes, wheels):
    return [m for _, _, ms, _ in horses for m in ms] + cmeshes + [w for w, _ in wheels]


def build_show(sc, opts):
    team, horses, croot, cmeshes, wheels = load(sc)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.6, hdri="sunset.exr", follow=None, lights=0.5, fog=(2.2, 6),
                      streak=9.0, shutter=0.45)
    e = R(9)
    cam.location, cam.rotation_euler = (0.0, -gc.CAM_DIST * math.cos(e), gc.CAM_DIST * math.sin(e)), (R(90) - e, 0, 0)
    sh.shadow_catcher(sc, GROUND_Z, 80)
    animate(team, horses, wheels)
    light_road(sc)
    dust(sc, team, wheels)
    sh.screen_extent(sc, cam, all_meshes(horses, cmeshes, wheels), (1, 30, 60, 84, 100, 120, 140, TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Team galloping in place in a 3/4 front view; legs, wheels and tails on whole cycles of the 2 s loop."""
    global PTS, ACC
    team, horses, croot, cmeshes, wheels = load(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=0.8, hdri="sunset.exr", follow=None, lights=1.0, fog=(1.7, 6), streak=7.0)
    n = stage.ICON_N
    team.location = (0.0, 0.0, 0.0)
    team.rotation_euler = (0.0, 0.0, R(-38))
    movers = [(animal.Mover(arm, hs.GAIT, animal.GALLOP_PHASES), arm, ph) for _, arm, _, ph in horses]
    loop = 2 * hs.CYCLE_DIST                     # two strides per loop
    for f in range(0, n + 1):
        gd = loop * f / n
        for mover, arm, ph in movers:
            bob = mover.legs_at(f, gd + ph, 1.0)
            c = math.cos(2 * math.pi * (gd + ph) / hs.CYCLE_DIST)
            w = 2 * math.pi * f / n
            mover.body(f, {"spine0": (X, 2.5 * c), "spine1": (X, -3.0 * c), "neck0": (X, 5.0 * c - 6.0), "neck1": (X, -4.0 * c - 4.0),
                           "head": (X, 3.0 * c + 8.0), "tail0": (X, -22 + 6 * math.sin(w + ph)), "tail1": (X, -16 + 8 * math.sin(w - 0.9 + ph)),
                           "tail2": (X, -10 + 9 * math.sin(w - 1.8 + ph))})
            arm.location = (0.0, 0.0, bob)
            arm.keyframe_insert("location", frame=f)
        for wo, r in wheels:
            wo.rotation_axis_angle[0] = 2 * math.pi / 12 * 2 * f / n     # two spoke steps per loop: seamless
            wo.keyframe_insert("rotation_axis_angle", frame=f)
    sc.frame_set(1)
    stage.frame_icon(cam, all_meshes(horses, cmeshes, wheels), pad=1.08)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
