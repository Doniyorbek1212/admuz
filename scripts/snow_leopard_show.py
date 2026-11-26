"""UZARO v2 show: snow leopard (tier 3, 144 f = 6 s).

A snow leopard stalks in low along a snowy rock ledge, stops at its end, crouches with a haunch wiggle and a puff of
breath, then leaps across the screen to the right: the flight hangs in slow motion with the legs stretched and the
long tail streaming, a burst of snow powder at the takeoff, crumbs falling off the ledge, then it leaves frame right.
Model: kenchoo "black panther" (CC BY), stripped of its rig and autorigged; the black coat is replaced by a baked
procedural snow-leopard coat (smoky grey, cream belly, open rosettes, solid head and leg spots, dark tail tip) and
thick particle fur. The ledge is procedural rock with a snow cap; it fades in and out and fades to alpha at its base.

    blender -b --factory-startup -P snow_leopard_show.py -- <show|icon> [f=1,60,100] [s=16]
    SL_NOFUR=1 skips the fur (fast rig tests).
"""
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import animal  # noqa: E402
import gift_common as gc  # noqa: E402
import quadruped as qp  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, env, interp  # noqa: E402

ID = "snow_leopard"
TOTAL = 144
SIZE = 6.0                      # joints below are in this normalised space (nose -Y, paws at z -1.23)
K = 1.0                         # world scale of the rig
GROUND_Z = -2.3                 # ledge top
FOOT = 1.23
HIDE = ("Object_38", "mesh_1", "mesh_3")    # bone-parented bits that float above the head once the rig is stripped
BODY, LEGS, HEAD = "mesh_0.002", "mesh_0.001", "mesh_0.004"
NO_FUR = bool(os.environ.get("SL_NOFUR"))
TEX = os.path.join(gc.TEXTURES, "snow_leopard")
GAIT = qp.Gait(cycle_dist=3.0, duty=0.66, lift=0.26, bob=0.03, hind_flex=25.0, fore_flex=40.0)
STALK = {"LB": 0.0, "LF": 0.25, "RB": 0.5, "RF": 0.75}
HEAD_DEG = 64.0                                  # walk heading: screen right, turned toward the camera
DIR = (math.sin(R(HEAD_DEG)), -math.cos(R(HEAD_DEG)))
TAKEOFF = (-2.3, 0.6)
LIP = 1.6                       # ledge lip, ahead of the body centre along DIR (front paws stand at ~1.5)
STOP_F, LEAP_F = 58, 86
TRAVEL = [(1, (TAKEOFF[0] - 9.5 * DIR[0], TAKEOFF[1] - 9.5 * DIR[1])), (STOP_F, TAKEOFF)]
CROUCH = [(1, 0.22), (STOP_F - 6, 0.28), (STOP_F + 6, 0.5), (LEAP_F - 8, 0.62), (LEAP_F, 0.0)]
WIGGLE = (66, 72, 80, 84)
BREATH_F = 70
# flight: fraction of the arc per frame. Explosive takeoff, a long slow-motion hang over the centre, then it rushes out.
FLIGHT = [(LEAP_F, 0.0), (LEAP_F + 6, 0.13), (124, 0.42), (TOTAL, 1.0)]
ARC = [(TAKEOFF[0], TAKEOFF[1], 0.0), (-0.6, 0.2, 2.0), (1.6, -0.2, 2.6), (5.0, -0.7, 1.6), (10.5, -1.3, -1.4)]
HEADING = [(1, HEAD_DEG), (STOP_F, HEAD_DEG), (LEAP_F - 4, 70.0), (LEAP_F + 8, 86.0), (TOTAL, 92.0)]
PITCH = [(LEAP_F - 2, 0.0), (LEAP_F + 5, -18.0), (110, -4.0), (128, 6.0), (TOTAL, 14.0)]   # nose up < 0
JOINTS = {
    "spine": [(0, 0.7, 0.8), (0, -0.3, 0.85), (0, -1.35, 0.85)],
    "neck": [(0, -1.4, 0.85), (0, -2.05, 1.0)],
    "head": [(0, -2.1, 1.0), (0, -2.98, 0.76)],
    "jaw": [(0, -2.35, 0.7), (0, -2.85, 0.5)],
    "ear": [(0.17, -2.35, 1.1), (0.21, -2.42, 1.26)],
    "tail": [(0, 1.1, 0.8), (0, 1.5, 0.2), (0, 2.0, -0.5), (0, 2.45, -0.88), (0, 2.98, -1.06)],
    "fore": [(0.3, -1.4, 0.7), (0.3, -1.45, -0.15), (0.3, -1.6, -0.8), (0.3, -1.7, -1.08), (0.3, -1.88, -1.2)],
    "hind": [(0.33, 0.6, 0.65), (0.33, 0.3, -0.05), (0.33, 1.05, -0.6), (0.33, 0.9, -1.06), (0.33, 0.7, -1.2)],
}
X, Y, Z = animal.X, animal.Y, animal.Z


def flight(f):
    return interp(FLIGHT, f) if f >= LEAP_F else 0.0


def in_air(f):
    return env(f, LEAP_F - 1, LEAP_F + 6)


# ------------------------------------------------------------------ coat
def coat_group():
    """Shader group: Position (normalised rest space) -> snow-leopard coat colour (linear)."""
    g = bpy.data.node_groups.new("SnowCoat", "ShaderNodeTree")
    g.interface.new_socket("Position", in_out="INPUT", socket_type="NodeSocketVector")
    g.interface.new_socket("Color", in_out="OUTPUT", socket_type="NodeSocketColor")
    nt = g.nodes
    N, L = nt.new, g.links.new
    gi, go = N("NodeGroupInput"), N("NodeGroupOutput")
    sep = N("ShaderNodeSeparateXYZ")
    L(gi.outputs[0], sep.inputs[0])
    px, py, pz = sep.outputs

    def math_(op, a, b=None, clamp=False):
        m = N("ShaderNodeMath")
        m.operation, m.use_clamp = op, clamp
        for i, v in enumerate((a, b)):
            if v is None:
                continue
            if isinstance(v, (int, float)):
                m.inputs[i].default_value = v
            else:
                L(v, m.inputs[i])
        return m.outputs[0]

    def ramp(v, lo, hi):
        mr = N("ShaderNodeMapRange")
        mr.interpolation_type = "SMOOTHSTEP"
        mr.inputs["From Min"].default_value, mr.inputs["From Max"].default_value = lo, hi
        L(v, mr.inputs["Value"])
        return mr.outputs["Result"]

    def mix(fac, a, b):
        m = N("ShaderNodeMix")
        m.data_type = "RGBA"
        L(fac, m.inputs["Factor"])
        for sock, v in ((m.inputs["A"], a), (m.inputs["B"], b)):
            if isinstance(v, tuple):
                sock.default_value = (*v, 1.0)
            else:
                L(v, sock)
        return m.outputs["Result"]

    # organic wobble so the pattern never reads as a grid
    noise = N("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value, noise.inputs["Detail"].default_value = 1.6, 3.0
    L(gi.outputs[0], noise.inputs["Vector"])
    off = N("ShaderNodeVectorMath")
    off.operation = "SUBTRACT"
    L(noise.outputs["Color"], off.inputs[0])
    off.inputs[1].default_value = (0.5, 0.5, 0.5)
    sc_ = N("ShaderNodeVectorMath")
    sc_.operation = "SCALE"
    sc_.inputs["Scale"].default_value = 0.18
    L(off.outputs[0], sc_.inputs[0])
    warped = N("ShaderNodeVectorMath")
    warped.operation = "ADD"
    L(gi.outputs[0], warped.inputs[0])
    L(sc_.outputs[0], warped.inputs[1])
    wp = warped.outputs[0]

    def voronoi(scale, seed_w):
        v = N("ShaderNodeTexVoronoi")
        v.voronoi_dimensions = "4D"
        v.inputs["Scale"].default_value, v.inputs["W"].default_value = scale, seed_w
        v.inputs["Randomness"].default_value = 0.85
        L(wp, v.inputs["Vector"])
        return v.outputs["Distance"]

    breaker = N("ShaderNodeTexNoise")                 # opens the rosette rings into broken arcs
    breaker.inputs["Scale"].default_value, breaker.inputs["Detail"].default_value = 9.0, 2.0
    L(wp, breaker.inputs["Vector"])
    gaps = ramp(breaker.outputs["Fac"], 0.3, 0.42)

    tail = ramp(py, 1.25, 1.45)
    head = ramp(py, -1.95, -2.15)
    low_leg = ramp(pz, 0.15, -0.15)
    body = math_("MULTIPLY", math_("SUBTRACT", 1.0, head, True), math_("SUBTRACT", 1.0, low_leg, True), True)
    body = math_("MULTIPLY", body, math_("SUBTRACT", 1.0, tail, True), True)

    def ring(dist, radius, width):
        return ramp(math_("ABSOLUTE", math_("SUBTRACT", dist, radius)), width, width * 0.35)

    d_body = voronoi(5.6, 0.3)
    rosette = math_("MULTIPLY", ring(d_body, 0.33, 0.16), gaps, True)      # voronoi distances are in cell units
    centre = ramp(d_body, 0.3, 0.18)                 # slightly darker, warmer middle of each rosette
    d_tail = voronoi(3.0, 1.7)
    tail_ring = math_("MULTIPLY", ring(d_tail, 0.4, 0.13), ramp(breaker.outputs["Fac"], 0.36, 0.46), True)
    d_spot = voronoi(9.0, 2.9)
    spot = ramp(d_spot, 0.24, 0.14)
    tip = ramp(py, 2.62, 2.78)

    belly = math_("MULTIPLY", ramp(pz, 0.45, 0.05), math_("SUBTRACT", 1.0, low_leg, True), True)   # pale underside
    throat = math_("MULTIPLY", head, ramp(pz, 0.85, 0.62), True)
    inner = math_("MAXIMUM", belly, throat)

    col = mix(inner, (0.3, 0.295, 0.27), (0.72, 0.70, 0.64))          # smoky grey back, cream underside
    col = mix(math_("MULTIPLY", centre, math_("MULTIPLY", body, 0.55)), col, (0.27, 0.24, 0.19))
    dark = (0.035, 0.035, 0.04)
    col = mix(math_("MULTIPLY", rosette, math_("MULTIPLY", body, math_("SUBTRACT", 1.0, math_("MULTIPLY", inner, 0.6)))), col, dark)
    col = mix(math_("MULTIPLY", tail_ring, tail), col, dark)
    col = mix(math_("MULTIPLY", spot, math_("MAXIMUM", math_("MULTIPLY", head, math_("SUBTRACT", 1.0, throat, True)), math_("MULTIPLY", low_leg, 0.8))), col, dark)
    col = mix(tip, col, (0.05, 0.05, 0.055))
    nose = math_("MULTIPLY", ramp(py, -2.86, -2.93), ramp(pz, 0.8, 0.86), True)
    col = mix(nose, col, (0.42, 0.27, 0.26))
    L(col, go.inputs[0])
    return g


def bake_coat(meshes):
    """Bake the coat into each furred mesh's UV space once (cached PNGs); skin and fur then read the same image."""
    os.makedirs(TEX, exist_ok=True)
    targets = [m for m in meshes if m.name in (BODY, LEGS, HEAD)]
    group = None
    sc = bpy.context.scene
    for ob in targets:
        mat = ob.data.materials[0]
        path = os.path.join(TEX, f"coat_{ob.name}.png")
        nt = mat.node_tree
        bs = stage.bsdf(mat)
        orig = bs.inputs["Base Color"].links[0].from_node if bs.inputs["Base Color"].links else None
        img_node = nt.nodes.new("ShaderNodeTexImage")
        if orig is not None and orig.inputs["Vector"].links:
            nt.links.new(orig.inputs["Vector"].links[0].from_socket, img_node.inputs["Vector"])
        if not os.path.exists(path):
            group = group or coat_group()
            img = bpy.data.images.new(f"coat_{ob.name}", 2048, 2048)
            img_node.image = img
            nt.nodes.active = img_node
            geo = nt.nodes.new("ShaderNodeNewGeometry")
            gn = nt.nodes.new("ShaderNodeGroup")
            gn.node_tree = group
            nt.links.new(geo.outputs["Position"], gn.inputs[0])
            em = nt.nodes.new("ShaderNodeEmission")
            nt.links.new(gn.outputs[0], em.inputs["Color"])
            out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL")
            keep = out.inputs["Surface"].links[0].from_socket
            nt.links.new(em.outputs[0], out.inputs["Surface"])
            eye = None
            if ob.name == HEAD and orig is not None:
                eye = eye_mix(nt, orig, gn, em)
            sc.render.engine = "CYCLES"
            sc.cycles.device, sc.cycles.samples = "CPU", 4
            for o in bpy.context.view_layer.objects:
                o.select_set(o == ob)
            bpy.context.view_layer.objects.active = ob
            bpy.ops.object.bake(type="EMIT", margin=12)
            img.filepath_raw, img.file_format = path, "PNG"
            img.save()
            nt.links.new(keep, out.inputs["Surface"])
            for n in (geo, gn, em) + ((eye,) if eye else ()):
                nt.nodes.remove(n)
        img_node.image = bpy.data.images.load(path, check_existing=True)
        nt.links.new(img_node.outputs["Color"], bs.inputs["Base Color"])
        stage.shiny(mat, roughness=0.62, metallic=0.0)
        bs.inputs["Subsurface Weight"].default_value = 0.08
        bs.inputs["Subsurface Radius"].default_value = (0.4, 0.25, 0.2)


def eye_mix(nt, orig, gn, em):
    """Keep the file's iris (the only saturated, bright texels on the black head), recoloured to a pale grey-green."""
    hsv = nt.nodes.new("ShaderNodeSeparateColor")
    hsv.mode = "HSV"
    nt.links.new(orig.outputs["Color"], hsv.inputs[0])
    mr = nt.nodes.new("ShaderNodeMapRange")
    mr.inputs["From Min"].default_value, mr.inputs["From Max"].default_value = 0.12, 0.3
    nt.links.new(hsv.outputs["Blue"], mr.inputs["Value"])
    tint = nt.nodes.new("ShaderNodeMix")
    tint.data_type, tint.blend_type = "RGBA", "MULTIPLY"
    tint.inputs["Factor"].default_value = 1.0
    tint.inputs["B"].default_value = (0.75, 0.95, 0.8, 1.0)
    nt.links.new(orig.outputs["Color"], tint.inputs["A"])
    mx = nt.nodes.new("ShaderNodeMix")
    mx.data_type = "RGBA"
    nt.links.new(mr.outputs["Result"], mx.inputs["Factor"])
    nt.links.new(gn.outputs[0], mx.inputs["A"])
    nt.links.new(tint.outputs["Result"], mx.inputs["B"])
    nt.links.new(mx.outputs["Result"], em.inputs["Color"])
    return mx


def fur_weights(ob):
    """Length map: short on the face, long belly and very long tail (a snow leopard's tail is a fur boa)."""
    vg = ob.vertex_groups.new(name="FurLen")
    for v in ob.data.vertices:
        x, y, z = v.co
        w = 0.62
        if y < -2.0:
            w = 0.3 if y > -2.6 else 0.18
        elif y > 1.15:
            w = 1.0
        elif z < 0.25 and -1.6 < y < 0.9:
            w = 0.85
        if z < -0.6 and y < 1.15:
            w = min(w, 0.4)
        vg.add([v.index], w, "REPLACE")
    return vg.name


# ------------------------------------------------------------------ rig
def load(sc):
    root, model, objs, meshes = stage.load(ID, SIZE, hide=HIDE, strip_rig=True)
    bake_coat(meshes)
    limits = animal.side_limits(JOINTS)
    limits["jaw"] = lambda c: ((c[:, 1] < -2.3) & (c[:, 2] < 0.68)) * 1.0
    for i in range(4):
        limits[f"tail{i}"] = lambda c: (c[:, 1] > 1.0) * 1.0
    for side, s in (("L", 1.0), ("R", -1.0)):
        limits[f"ear{side}0"] = lambda c, s=s: ((c[:, 2] > 1.06) & (c[:, 1] < -2.15) & (c[:, 0] * s > 0.06)) * 1.0
    arm = animal.build(sc, "SnowLeopard", JOINTS, meshes, power=7.0, limits=limits)
    wrap = bpy.data.objects.new("Heading", None)
    sc.collection.objects.link(wrap)
    wrap.parent = root
    wrap.rotation_mode = "XYZ"
    arm.parent = wrap
    root.scale = (K, K, K)
    for m in meshes:
        if m.name == "mesh_0":
            m.data.materials[0] = stage.pbr("Whisker", (0.85, 0.85, 0.82), roughness=0.35)
    if not NO_FUR:
        for m in meshes:
            if m.name not in (BODY, LEGS, HEAD):
                continue
            count = {BODY: 26000, LEGS: 9000, HEAD: 7000}[m.name]
            animal.fur(m, 0.17, count=count, children=26, radius=0.0042, roughness=0.5, clump=0.25, gamma=0.6,       # hair in COLOR mode reads much darker than skin
                       multiply=(1.0, 1.0, 1.0), length_vg=fur_weights(m))
            m.particle_systems[-1].settings.roughness_endpoint = 0.02
    return root, wrap, arm, meshes


def animate(root, wrap, mover):
    dist, prev = 0.0, interp(TRAVEL, 1)
    for f in range(1, TOTAL + 1):
        px = interp(TRAVEL, f)
        dist += math.hypot(px[0] - prev[0], px[1] - prev[1]) / K
        prev = px
        air, t = in_air(f), flight(f)
        moving = 1 - env(f, STOP_F - 8, STOP_F)
        crouch = interp(CROUCH, f)
        bob = mover.legs_at(f, dist, moving, crouch * (1 - air))
        if air > 0.001:
            reach = env(f, 120, TOTAL)                      # fore paws come down for the landing off screen
            for key, s in (("LF", 1.0), ("RF", -1.0)):
                mover.leg(f, key, paw=(air * (0.95 - 0.2 * reach), air * (0.75 - 0.9 * reach) + 0.08 * s), flex=-0.3 * air)
            for key, s in (("LB", 1.0), ("RB", -1.0)):
                mover.leg(f, key, paw=(-0.85 * air, 0.65 * air + 0.06 * s), flex=-0.25 * air)
        wig = env(f, WIGGLE[0], WIGGLE[1]) * (1 - env(f, WIGGLE[2], WIGGLE[3]))
        wiggle = 0.05 * math.sin(f * 1.4) * wig
        stalk = 1 - air
        focus = env(f, STOP_F - 4, STOP_F + 8) * stalk
        snarl = env(f, LEAP_F - 3, LEAP_F + 2) * (1 - env(f, LEAP_F + 14, LEAP_F + 24))
        spine_pitch = interp(PITCH, f) * air
        tw = math.sin(f / 6.5)
        mover.body(f, {
            "spine0": (X, -0.6 * spine_pitch + 4.0 * stalk * (1 - focus) * math.sin(dist * 4.2) - 6.0 * air * math.sin(math.pi * min(1.0, flight(f) * 2.2))),
            "spine1": (X, 3.0 * crouch * stalk - 4.0 * air),
            "neck0": [(X, 16.0 * stalk - 6.0 * focus - 14.0 * air), (Z, 4.0 * math.sin(f / 9.0) * stalk)],
            "head": [(X, 10.0 * stalk - 4.0 * focus - 10.0 * air), (Y, 3.0 * focus * math.sin(f / 5.0))],
            "jaw": (X, 26.0 * snarl + 2.0 * snarl * math.sin(f / 1.8) + 6.0 * env(f, BREATH_F - 3, BREATH_F) * (1 - env(f, BREATH_F + 4, BREATH_F + 9))),
            "earL0": (X, -30.0 * focus * (1 - air) - 20.0 * air + 6.0 * math.sin(f / 3.0) * env(f, 30, 40) * (1 - env(f, 44, 50))),
            "earR0": (X, -30.0 * focus * (1 - air) - 20.0 * air),
            "tail0": [(X, 4.0 * stalk + 46.0 * air), (Z, 12.0 * tw * stalk + 6.0 * math.sin(f / 4.0) * air)],
            "tail1": [(X, 10.0 * stalk + 20.0 * air), (Z, 16.0 * math.sin(f / 6.5 - 0.9))],
            "tail2": [(X, 16.0 * stalk + 8.0 * air), (Z, 20.0 * math.sin(f / 6.5 - 1.8))],
            "tail3": [(X, 24.0 * stalk - 6.0 * air), (Z, 26.0 * math.sin(f / 6.5 - 2.7) + 22.0 * focus * math.sin(f / 2.2))],
        })
        arc = stage.catmull(ARC, t)
        ground = (px[0] + wiggle * DIR[0], px[1] + wiggle * DIR[1], GROUND_Z + K * (FOOT + bob - crouch * (1 - air)))
        if t > 0 or air > 0:
            root.location = (arc[0], arc[1], ground[2] + arc[2] * K + 0.25 * air)
        else:
            root.location = ground
        root.keyframe_insert("location", frame=f)
        wrap.rotation_euler = (R(interp(PITCH, f) * air), 0.0, R(interp(HEADING, f)))
        wrap.keyframe_insert("rotation_euler", frame=f)


# ------------------------------------------------------------------ set
def ledge(sc):
    """Snow-capped rock spine along the walk line, ending at the takeoff in a ragged lip; fades in, out and at its base."""
    import bmesh
    me = bpy.data.meshes.new("Ledge")
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=(2.6, 15.0, 3.2), verts=bm.verts)
    bmesh.ops.translate(bm, vec=(0, 7.2, -1.6), verts=bm.verts)     # lip at y=-0.3 (local), top at z=0
    bmesh.ops.bevel(bm, geom=list(bm.edges), offset=0.5, segments=4, affect="EDGES")
    bm.to_mesh(me)
    bm.free()
    ob = stage.link(sc, "Ledge", me, ledge_material())
    ob.location = (TAKEOFF[0] + LIP * DIR[0], TAKEOFF[1] + LIP * DIR[1], GROUND_Z)
    ob.rotation_euler = (0, 0, R(HEAD_DEG))     # local +Y runs back along the walk line
    sub = ob.modifiers.new("Sub", "SUBSURF")
    sub.levels = sub.render_levels = 4
    tex = bpy.data.textures.new("LedgeRock", "VORONOI")
    tex.noise_scale, tex.distance_metric = 0.9, "DISTANCE"
    dis = ob.modifiers.new("Rock", "DISPLACE")
    dis.texture, dis.strength, dis.mid_level = tex, 0.3, 0.55
    tex2 = bpy.data.textures.new("LedgeGrain", "CLOUDS")
    tex2.noise_scale, tex2.noise_depth = 0.35, 4
    dis2 = ob.modifiers.new("Grain", "DISPLACE")
    dis2.texture, dis2.strength = tex2, 0.1
    bpy.context.view_layer.update()
    lo, hi = gc.world_bbox([ob])
    ob.location.z -= hi.z - GROUND_Z - 0.12          # displacement peaks poke 0.12 above the walk line, paws rest on the mean
    return ob


def ledge_material():
    """Slate rock, snow where the surface faces up; alpha fades to 0 down the face so the ledge has no bottom edge."""
    m = bpy.data.materials.new("LedgeMat")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out = N("ShaderNodeOutputMaterial")
    geo, tc = N("ShaderNodeNewGeometry"), N("ShaderNodeTexCoord")
    rock = N("ShaderNodeBsdfPrincipled")
    noise = N("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value, noise.inputs["Detail"].default_value = 2.2, 8.0
    L(tc.outputs["Object"], noise.inputs["Vector"])
    cr = N("ShaderNodeValToRGB")
    cr.color_ramp.elements[0].color = (0.03, 0.032, 0.036, 1)
    cr.color_ramp.elements[1].color = (0.14, 0.14, 0.15, 1)
    L(noise.outputs["Fac"], cr.inputs["Fac"])
    L(cr.outputs["Color"], rock.inputs["Base Color"])
    rock.inputs["Roughness"].default_value = 0.85
    bump = N("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.6
    L(noise.outputs["Fac"], bump.inputs["Height"])
    L(bump.outputs["Normal"], rock.inputs["Normal"])
    snow = N("ShaderNodeBsdfPrincipled")
    snow.inputs["Base Color"].default_value = (0.86, 0.9, 0.97, 1)
    snow.inputs["Roughness"].default_value = 0.55
    snow.inputs["Subsurface Weight"].default_value = 0.4
    snow.inputs["Subsurface Radius"].default_value = (0.6, 0.7, 0.9)
    snow.inputs["Coat Weight"].default_value = 0.15       # sparkle on grazing light
    sn = N("ShaderNodeTexNoise")
    sn.inputs["Scale"].default_value, sn.inputs["Detail"].default_value = 30.0, 2.0
    L(tc.outputs["Object"], sn.inputs["Vector"])
    sb = N("ShaderNodeBump")
    sb.inputs["Strength"].default_value = 0.15
    L(sn.outputs["Fac"], sb.inputs["Height"])
    L(sb.outputs["Normal"], snow.inputs["Normal"])
    nz = N("ShaderNodeSeparateXYZ")
    L(geo.outputs["Normal"], nz.inputs[0])
    cover = N("ShaderNodeMath")
    cover.operation = "ADD"
    L(nz.outputs["Z"], cover.inputs[0])
    L(noise.outputs["Fac"], cover.inputs[1])
    cap = N("ShaderNodeMapRange")
    cap.inputs["From Min"].default_value, cap.inputs["From Max"].default_value = 0.95, 1.15
    L(cover.outputs[0], cap.inputs["Value"])
    mix = N("ShaderNodeMixShader")
    L(cap.outputs["Result"], mix.inputs[0])
    L(rock.outputs[0], mix.inputs[1])
    L(snow.outputs[0], mix.inputs[2])
    # base fade: object z 0 (top) .. -2.4 (fully gone), wobbled so it reads as mist, not a cut
    oz = N("ShaderNodeSeparateXYZ")
    L(tc.outputs["Object"], oz.inputs[0])
    wob = N("ShaderNodeMath")
    wob.operation = "MULTIPLY_ADD"
    L(noise.outputs["Fac"], wob.inputs[0])
    wob.inputs[1].default_value = 0.9
    L(oz.outputs["Z"], wob.inputs[2])
    base = N("ShaderNodeMapRange")
    base.inputs["From Min"].default_value, base.inputs["From Max"].default_value = -1.9, -0.4
    L(wob.outputs[0], base.inputs["Value"])
    fade = N("ShaderNodeValue")
    fade.name = "Fade"
    vis = N("ShaderNodeMath")
    vis.operation, vis.use_clamp = "MULTIPLY", True
    L(base.outputs["Result"], vis.inputs[0])
    L(fade.outputs[0], vis.inputs[1])
    tr = N("ShaderNodeBsdfTransparent")
    final = N("ShaderNodeMixShader")
    L(vis.outputs[0], final.inputs[0])
    L(tr.outputs[0], final.inputs[1])
    L(mix.outputs[0], final.inputs[2])
    L(final.outputs[0], out.inputs["Surface"])
    for f, v in ((1, 0.0), (10, 1.0), (118, 1.0), (TOTAL - 4, 0.0)):
        fade.outputs[0].default_value = v
        fade.outputs[0].keyframe_insert("default_value", frame=f)
    return m


def snow_fx(sc, lip):
    """Takeoff powder, crumbs off the lip, paw kicks during the stalk, a breath cloud and a light flurry."""
    powder = fx.fade_material("Powder", (0.82, 0.88, 1.0), 0.8, 0.2, 1.6)
    tx, ty = TAKEOFF
    fx.particle_burst(sc, "Launch", fx.ring_mesh("LaunchR", 0.9, 0.05, 40), powder, 1100, (LEAP_F - 2, LEAP_F + 5), 30, 0.11, 1.8,
                      rand=2.4, damping=0.14, gravity=-0.02, location=(tx, ty, GROUND_Z + 0.05))
    fx.particle_burst(sc, "Plume", fx.point_mesh("PlumeP", 0.6), powder, 400, (LEAP_F, LEAP_F + 10), 34, 0.15, 0.9, rand=1.6,
                      align=(1.2, 0.0, 0.8), damping=0.2, gravity=-0.01, location=(tx + 0.5, ty, GROUND_Z + 0.4))
    crumb = stage.pbr("Crumb", (0.85, 0.9, 0.97), roughness=0.5)
    fx.particle_burst(sc, "Crumbs", fx.point_mesh("CrumbP", 0.5), crumb, 140, (LEAP_F, LEAP_F + 30), 40, 0.045, 0.4, rand=1.0,
                      gravity=1.0, location=(lip[0], lip[1], GROUND_Z - 0.15))
    kick = fx.fade_material("Kick", (0.82, 0.88, 1.0), 0.5, 0.35, 1.5)
    path_em = bpy.data.objects.new("KickPath", None)
    sc.collection.objects.link(path_em)
    for f in range(1, STOP_F + 1):
        p = interp(TRAVEL, f)
        path_em.location = (p[0] + 1.2 * DIR[0], p[1] + 1.2 * DIR[1], GROUND_Z + 0.05)
        path_em.keyframe_insert("location", frame=f)
    k = fx.particle_burst(sc, "Kicks", fx.ring_mesh("KickR", 1.0, 0.05, 24), kick, 160, (2, STOP_F), 20, 0.16, 0.5, rand=1.2,
                          damping=0.2, gravity=-0.01)
    k.parent = path_em
    breath = fx.fade_material("Breath", (0.9, 0.94, 1.0), 0.45, 0.22, 1.2)
    b = fx.particle_burst(sc, "Breath", fx.point_mesh("BreathP", 0.12), breath, 90, (BREATH_F, BREATH_F + 6), 22, 0.1, 0.5,
                          rand=0.6, align=(0.0, 0.6, 0.0), damping=0.25, gravity=-0.005)
    return b


def flurry(sc):
    """Sparse snowflakes drifting down through the middle of the frame (not the corners)."""
    flake = stage.emit("Flake", (0.9, 0.95, 1.0), 1.6)
    me = bpy.data.meshes.new("FlurrySrc")
    me.from_pydata([(-3.2, -2.0, 0), (3.2, -2.0, 0), (3.2, 3.0, 0), (-3.2, 3.0, 0)], [], [(0, 1, 2, 3)])
    em = fx.particle_burst(sc, "Flurry", me, flake, 420, (-100, TOTAL), 200, 0.018, 0.0, rand=0.15,
                           align=(0.3, 0.0, -1.8), gravity=0.0, location=(0, 0, 6.5))
    st = em.particle_systems[0].settings
    st.brownian_factor = 0.4
    return em


def build_show(sc, opts):
    root, wrap, arm, meshes = load(sc)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.55, hdri="forest.exr", follow=root, lights=1.0, fog=(1.8, 6),
                      streak=9.0, shutter=0.35)
    e = R(4)
    cam.location, cam.rotation_euler = (0.0, -gc.CAM_DIST * math.cos(e), gc.CAM_DIST * math.sin(e)), (R(90) - e, 0, 0)
    cam.data.clip_start = 0.3
    rock = ledge(sc)
    animate(root, wrap, animal.Mover(arm, GAIT, STALK))
    lip = (TAKEOFF[0] + (LIP + 0.3) * DIR[0], TAKEOFF[1] + (LIP + 0.3) * DIR[1])
    breath = snow_fx(sc, lip)
    breath.parent, breath.parent_type, breath.parent_bone = arm, "BONE", "head"
    breath.location = (0, 0.04, 0)                    # bone space, child of the bone tail = the nose
    flurry(sc)
    sh.camera_shake(cam, LEAP_F, 12, amp=0.05, rot_deg=0.3, seed=5)
    sh.screen_extent(sc, cam, meshes, (1, 30, STOP_F, LEAP_F, 100, 124, TOTAL))
    sh.screen_extent(sc, cam, [rock], (20,))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Crouched three-quarter view: ears flick, a slow breath, the tail tip twitches on a seamless loop."""
    root, wrap, arm, meshes = load(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=0.55, hdri="forest.exr", follow=root, lights=0.8, fog=(1.8, 6), streak=9.0)
    mover = animal.Mover(arm, GAIT, STALK)
    wrap.rotation_euler = (0, 0, R(28))
    n = stage.ICON_N
    for f in range(0, n + 1):
        w = 2 * math.pi * f / n
        s = 0.5 + 0.5 * math.sin(w)
        mover.legs_at(f, 0.0, 0.0, 0.4)
        mover.body(f, {
            "spine1": (X, 2.0 * s), "neck0": (X, 4.0), "head": [(X, 6.0 + 3.0 * s), (Y, 4.0 * math.sin(w))],
            "jaw": (X, 4.0 * s), "earL0": (X, -10.0 * max(0.0, math.sin(2 * w))), "earR0": (X, -6.0 * s),
            "tail0": [(X, -20.0), (Z, 14.0 * math.sin(w))], "tail1": (Z, 18.0 * math.sin(w - 0.9)),
            "tail2": (Z, 20.0 * math.sin(w - 1.8)), "tail3": (Z, 30.0 * math.sin(w - 2.7)),
        })
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.08)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
