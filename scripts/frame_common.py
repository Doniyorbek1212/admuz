"""Building blocks for the UZARO animated avatar frames (run inside Blender, see frames.py).

Contract: square canvas, orthographic camera looking along +Y, the frame lies in the XZ plane, canvas spans
-1..1 in X and Z. The avatar photo covers radius PHOTO_R; everything inside HOLE_R is cut to alpha 0 by
encode_frames.py. Every animation is a function of the loop phase t = (frame - 1) / N in [0, 1), so frame N + 1
equals frame 1 and the loop is seamless.
"""
import math
import os
import random

import bmesh
import bpy
from mathutils import Vector

import gift_common as gc
import show_common as sh
import stage as st

R = math.radians
TAU = 2 * math.pi
N = 30                 # frames in the loop: 2 s at 15 fps
FPS = 15
RES = 384
PHOTO_R = 0.76         # the app draws the photo at 76 % of the canvas
HOLE_R = 0.74          # cut to alpha 0 (a hair inside the photo so no seam shows)
BAND_R = 0.80          # centre line of the main ring
WORLD_SWAY = R(30)     # how far the reflections swing each way in a loop
OUT = os.path.join(gc.UZARO, "frame_renders")


def phase(f):
    return (f - 1) / N


def frames():
    return range(1, N + 2)


# ---------------------------------------------------------------- scene
def setup(sc, samples=32, world=1.3, hdri="studio.exr", glow=(1.6, 6), streak=8.0, lights=1.0, spin_world=True):
    """Cycles, ortho camera, lights, glow comp. The world (reflections) sways WORLD_SWAY each way once per loop: a
    seamless shimmer. A full turn per loop changed every metal pixel by ~43/255 a frame: it flickered and no frame
    compressed as a delta, so gold_laurel stayed over 550 KB even at q50."""
    sh.setup_cycles(sc, (1, N), samples=samples, res=(RES, RES))
    sc.render.fps = FPS
    sc.render.use_motion_blur = False
    sc.cycles.film_transparent_glass = False   # cut stones refract the studio, not the empty film (which reads black)
    gc.setup_world(sc, strength=world, hdri=hdri)
    if spin_world:
        mapping = next(n for n in sc.world.node_tree.nodes if n.type == "MAPPING")
        loop_key(mapping.inputs["Rotation"], lambda t: (0.0, 0.0, WORLD_SWAY * math.sin(TAU * t)))
    cam = gc.setup_camera(sc)
    cam.location, cam.rotation_euler = (0.0, -10.0, 0.0), (R(90), 0.0, 0.0)
    cam.data.type, cam.data.ortho_scale = "ORTHO", 2.0
    if lights:
        gc.setup_lights(sc, scale=lights)
    sh.setup_comp(sc, fog_threshold=glow[0], fog_size=glow[1], streak_threshold=streak)
    return cam


def linear(id_data):
    ad = id_data.animation_data
    if ad and ad.action:
        for fc in ad.action.fcurves:
            for kp in fc.keyframe_points:
                kp.interpolation = "LINEAR"


def loop_key(sock, fn):
    """Key a node socket for every frame of the loop with fn(t)."""
    for f in frames():
        sock.default_value = fn(phase(f))
        sock.keyframe_insert("default_value", frame=f)
    linear(sock.id_data)


def animate(ob, fn, path="location"):
    """Key ob.<path> = fn(t) on every frame of the loop."""
    for f in frames():
        setattr(ob, path, fn(phase(f)))
        ob.keyframe_insert(path, frame=f)
    linear(ob)


def spin(ob, turns=1.0):
    """Rotate about the view axis (Y) by turns * 360 degrees per loop: a whole number of symmetric repeats."""
    base = ob.rotation_euler.copy()
    animate(ob, lambda t: (base.x, base.y + TAU * turns * t, base.z), "rotation_euler")


def pulse(ob, lo=0.85, hi=1.15, offset=0.0, cycles=1):
    base = ob.scale.copy()
    animate(ob, lambda t: base * (lo + (hi - lo) * (0.5 - 0.5 * math.cos(TAU * (cycles * t + offset)))), "scale")


# ---------------------------------------------------------------- materials
def metal(name, rgb, roughness=0.18, coat=0.3):
    return st.pbr(name, rgb, metallic=1.0, roughness=roughness, coat=coat)


GOLD = (1.0, 0.70, 0.26)
SILVER = (0.92, 0.94, 0.98)


def glass(name, rgb, roughness=0.02, ior=2.0, glow=None, strength=0.0):
    return st.pbr(name, rgb, roughness=roughness, transmission=1.0, ior=ior, emission=glow, strength=strength)


def gem(name, rgb, glow=0.15, ior=2.4):
    """Cut stone: clear, high IOR with a little dispersion and inner light, so facets flash as the studio turns."""
    m = st.pbr(name, rgb, roughness=0.0, transmission=1.0, ior=ior, emission=rgb, strength=glow)
    b = st.bsdf(m)
    if "Dispersion" in b.inputs:
        b.inputs["Dispersion"].default_value = 0.25
    return m


def label(rgb, strength=1.4):
    """Plate text: emission, so it reads at any size and against any reflection."""
    return st.emit("Label", rgb, strength)


def enamel(name, rgb, roughness=0.25, coat=1.0):
    return st.pbr(name, rgb, roughness=roughness, coat=coat)


def neon(name, rgb, strength=8.0, cycles=1, lo=0.7, hi=1.2, offset=0.0):
    """Emission that breathes `cycles` times per loop."""
    m = st.emit(name, rgb, strength)
    loop_key(m.node_tree.nodes["Emission"].inputs["Strength"],
             lambda t: strength * (lo + (hi - lo) * (0.5 - 0.5 * math.cos(TAU * (cycles * t + offset)))))
    return m


def comet(name, rgb, strength=10.0, tail=0.35, turns=1, base=0.25, tint=None):
    """Emission that runs round the ring: brightest at an angle that turns `turns` times per loop, fading behind it."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N_, L = nt.nodes.new, nt.links.new
    tc = N_("ShaderNodeTexCoord")
    sep = N_("ShaderNodeSeparateXYZ")
    L(tc.outputs["Object"], sep.inputs[0])
    ang = N_("ShaderNodeMath")
    ang.operation = "ARCTAN2"
    L(sep.outputs["Z"], ang.inputs[0])
    L(sep.outputs["X"], ang.inputs[1])
    norm = N_("ShaderNodeMath")                   # angle 0..1
    norm.operation = "MULTIPLY_ADD"
    L(ang.outputs[0], norm.inputs[0])
    norm.inputs[1].default_value = 1 / TAU
    norm.inputs[2].default_value = 0.5
    shift = N_("ShaderNodeMath")
    shift.operation = "ADD"
    L(norm.outputs[0], shift.inputs[0])
    loop_key(shift.inputs[1], lambda t: -turns * t)
    frac = N_("ShaderNodeMath")
    frac.operation = "FRACT"
    L(shift.outputs[0], frac.inputs[0])
    ramp = N_("ShaderNodeValToRGB")
    L(frac.outputs[0], ramp.inputs["Fac"])
    e = ramp.color_ramp.elements
    e[0].position, e[0].color = 0.0, (base, base, base, 1)
    e[1].position, e[1].color = 1.0 - 0.002, (1, 1, 1, 1)
    e.new(1.0 - tail).color = (base, base, base, 1)
    end = e.new(1.0)
    end.color = (base, base, base, 1)
    mix = N_("ShaderNodeMix")
    mix.data_type = "RGBA"
    L(frac.outputs[0], mix.inputs["Factor"])
    mix.inputs[6].default_value = (*rgb, 1)
    mix.inputs[7].default_value = (*(tint or rgb), 1)
    mul = N_("ShaderNodeVectorMath")
    mul.operation = "MULTIPLY"
    L(mix.outputs[2], mul.inputs[0])
    L(ramp.outputs["Color"], mul.inputs[1])
    em = N_("ShaderNodeEmission")
    L(mul.outputs[0], em.inputs["Color"])
    em.inputs["Strength"].default_value = strength
    L(em.outputs[0], N_("ShaderNodeOutputMaterial").inputs["Surface"])
    return m


def flow(name, stops, scale=4.0, drift=(0.0, 0.0, -1.0), strength=6.0, r0=0.70, r1=1.0, falloff=1.6, detail=6.0,
         stretch=(1.0, 1.0, 1.0)):
    """Animated emissive noise in an annulus: fire, nebula, aurora. Two noise samples cross-fade over the loop
    (N(p + v t) and N(p + v (t - 1))), so the last frame flows into the first. Alpha fades out towards r1."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    m.blend_method = "BLEND"
    nt = m.node_tree
    nt.nodes.clear()
    N_, L = nt.nodes.new, nt.links.new
    tc = N_("ShaderNodeTexCoord")
    t = N_("ShaderNodeValue")
    loop_key(t.outputs[0], lambda x: x)
    tm1 = N_("ShaderNodeMath")
    tm1.operation = "SUBTRACT"
    L(t.outputs[0], tm1.inputs[0])
    tm1.inputs[1].default_value = 1.0
    noises = []
    for src in (t, tm1):
        off = N_("ShaderNodeVectorMath")
        off.operation = "SCALE"
        off.inputs[0].default_value = drift
        L(src.outputs[0], off.inputs["Scale"])
        sq = N_("ShaderNodeVectorMath")
        sq.operation = "MULTIPLY"
        L(tc.outputs["Object"], sq.inputs[0])
        sq.inputs[1].default_value = stretch
        add = N_("ShaderNodeVectorMath")
        L(sq.outputs[0], add.inputs[0])
        L(off.outputs[0], add.inputs[1])
        nz = N_("ShaderNodeTexNoise")
        nz.inputs["Scale"].default_value = scale
        nz.inputs["Detail"].default_value = detail
        nz.inputs["Roughness"].default_value = 0.6
        L(add.outputs[0], nz.inputs["Vector"])
        noises.append(nz)
    mix = N_("ShaderNodeMix")
    L(t.outputs[0], mix.inputs["Factor"])
    L(noises[0].outputs["Fac"], mix.inputs[2])
    L(noises[1].outputs["Fac"], mix.inputs[3])
    # contrast back up: the cross-fade flattens the middle of the loop a little
    con = N_("ShaderNodeMapRange")
    L(mix.outputs[0], con.inputs[0])
    con.inputs[1].default_value, con.inputs[2].default_value = 0.3, 0.7
    # radial mask: 1 at r0, 0 at r1
    ln = N_("ShaderNodeVectorMath")
    ln.operation = "LENGTH"
    L(tc.outputs["Object"], ln.inputs[0])
    rad = N_("ShaderNodeMapRange")
    L(ln.outputs["Value"], rad.inputs[0])
    rad.inputs[1].default_value, rad.inputs[2].default_value = r0, r1
    rad.inputs[3].default_value, rad.inputs[4].default_value = 1.0, 0.0
    pw = N_("ShaderNodeMath")
    pw.operation = "POWER"
    L(rad.outputs[0], pw.inputs[0])
    pw.inputs[1].default_value = falloff
    heat = N_("ShaderNodeMath")
    heat.operation = "MULTIPLY"
    heat.use_clamp = True
    L(con.outputs[0], heat.inputs[0])
    L(pw.outputs[0], heat.inputs[1])
    boost = N_("ShaderNodeMath")
    boost.operation = "MULTIPLY"
    boost.use_clamp = True
    L(heat.outputs[0], boost.inputs[0])
    boost.inputs[1].default_value = 1.8
    ramp = N_("ShaderNodeValToRGB")
    L(boost.outputs[0], ramp.inputs["Fac"])
    el = ramp.color_ramp.elements
    el[0].position, el[0].color = stops[0][0], (*stops[0][1], 1)
    el[1].position, el[1].color = stops[-1][0], (*stops[-1][1], 1)
    for pos, rgb in stops[1:-1]:
        el.new(pos).color = (*rgb, 1)
    alpha = N_("ShaderNodeMapRange")
    L(boost.outputs[0], alpha.inputs[0])
    alpha.inputs[1].default_value, alpha.inputs[2].default_value = stops[0][0], stops[1][0] + 0.05
    em = N_("ShaderNodeEmission")
    L(ramp.outputs["Color"], em.inputs["Color"])
    em.inputs["Strength"].default_value = strength
    tr = N_("ShaderNodeBsdfTransparent")
    mx = N_("ShaderNodeMixShader")
    L(alpha.outputs[0], mx.inputs[0])
    L(tr.outputs[0], mx.inputs[1])
    L(em.outputs[0], mx.inputs[2])
    L(mx.outputs[0], N_("ShaderNodeOutputMaterial").inputs["Surface"])
    return m


# ---------------------------------------------------------------- meshes
def _finish(me, smooth=True):
    me.update()
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    me.polygons.foreach_set("use_smooth", [smooth] * len(me.polygons))
    return me


def sweep(name, profile, a0=0.0, a1=TAU, segs=192, smooth=True):
    """Closed cross-section [(r, y), ...] swept round the view axis from angle a0 to a1 (radians, 0 = +X, CCW
    seen by the camera). Partial arcs get flat caps."""
    full = abs(a1 - a0 - TAU) < 1e-6
    n = segs if full else max(2, int(segs * abs(a1 - a0) / TAU) + 1)
    verts, faces = [], []
    k = len(profile)
    for i in range(n):
        a = a0 + (a1 - a0) * i / (n if full else n - 1)
        c, s = math.cos(a), math.sin(a)
        verts += [(r * c, y, r * s) for r, y in profile]
    rows = n if full else n - 1
    for i in range(rows):
        j = (i + 1) % n
        for p in range(k):
            q = (p + 1) % k
            faces.append((i * k + p, j * k + p, j * k + q, i * k + q))
    if not full:
        faces.append(tuple(range(k)))
        faces.append(tuple((n - 1) * k + p for p in reversed(range(k))))
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    return _finish(me, smooth)


def rounded_section(width, depth, r=None, steps=4):
    """Rounded-rectangle cross-section centred on (0, 0): width along the radius, depth along Y."""
    r = min(width, depth) * 0.45 if r is None else r
    hw, hd = width / 2 - r, depth / 2 - r
    pts = []
    for cx, cy, a in ((hw, hd, 0), (-hw, hd, 90), (-hw, -hd, 180), (hw, -hd, 270)):
        for i in range(steps + 1):
            ang = R(a + 90 * i / steps)
            pts.append((cx + r * math.cos(ang), cy + r * math.sin(ang)))
    return pts


def band(name, radius, width, depth, a0=0.0, a1=TAU, segs=192, round_r=None):
    sec = rounded_section(width, depth, round_r)
    return sweep(name, [(radius + x, y) for x, y in sec], a0, a1, segs)


def tube(name, radius, thick, a0=0.0, a1=TAU, segs=192, ring=12):
    sec = [(radius + thick * math.cos(TAU * i / ring), thick * math.sin(TAU * i / ring)) for i in range(ring)]
    return sweep(name, sec, a0, a1, segs)


def slab(name, outline, depth, bevel=0.0, smooth=False):
    """2D outline [(x, z), ...] (CCW seen from the camera) extruded along Y, centred; optional bevel modifier
    is added by the caller via bevel()."""
    bm = bmesh.new()
    vs = [bm.verts.new((x, -depth / 2, z)) for x, z in outline]
    face = bm.faces.new(vs)
    ext = bmesh.ops.extrude_face_region(bm, geom=[face])
    moved = [g for g in ext["geom"] if isinstance(g, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, verts=moved, vec=(0, depth, 0))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    me.polygons.foreach_set("use_smooth", [smooth] * len(me.polygons))
    return me


def bevel(ob, width=0.01, segments=3):
    mod = ob.modifiers.new("Bevel", "BEVEL")
    mod.width, mod.segments, mod.limit_method = width, segments, "ANGLE"
    mod.harden_normals = False
    return ob


def faceted_star(name, points=5, r_out=1.0, r_in=0.45, height=0.35, back=0.1):
    """Gem-cut star: outline at y=0, apex towards the camera, flat facets that catch the turning light."""
    verts = [(0.0, -height, 0.0), (0.0, back, 0.0)]
    for i in range(points * 2):
        a = R(90) + math.pi * i / points
        r = r_out if i % 2 == 0 else r_in
        verts.append((r * math.cos(a), 0.0, r * math.sin(a)))
    n = points * 2
    faces = []
    for i in range(n):
        a, b = 2 + i, 2 + (i + 1) % n
        faces.append((0, b, a))
        faces.append((1, a, b))
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    return _finish(me, smooth=False)


def brilliant(name, r=1.0, segs=8):
    """Brilliant-cut diamond, table up (+Z) as seen from the side; turn it with rotation_euler."""
    me = st.lathe(name, [(0.0, 0.62), (0.56, 0.62), (1.0, 0.25), (1.0, 0.18), (0.0, -0.95)], segs=segs,
                  smooth_shade=False)
    for v in me.vertices:
        v.co *= r
    me.update()
    return me


def gem_round(name, r=1.0, segs=8):
    """Brilliant facing the camera (table towards -Y): the gems set into bands."""
    me = brilliant(name, r, segs)
    me.transform(__import__("mathutils").Matrix.Rotation(R(90), 4, "X"))
    me.update()
    return me


def leaf_outline(length=1.0, width=0.36, n=12):
    """Pointed leaf along +X from the origin (stem end)."""
    top, bot = [], []
    for i in range(n + 1):
        u = i / n
        w = width * math.sin(math.pi * u) ** 0.8 * (1 - 0.25 * u)
        top.append((u * length, w / 2))
        bot.append((u * length, -w / 2))
    return bot + top[::-1][1:-1]


def petal_outline(length=1.0, width=0.7, notch=0.14, n=16):
    """Sakura petal along +X: narrow at the stem, broad rounded tip with a small V notch."""
    side = []
    for i in range(n + 1):
        u = 0.97 * i / n
        if u <= 0.7:
            w = width / 2 * math.sin(math.pi / 2 * u / 0.7) ** 0.75
        else:
            w = width / 2 * math.sqrt(max(0.0, 1 - ((u - 0.7) / 0.3) ** 2))
        side.append((u * length, w))
    lower = [(x, -w) for x, w in side]
    upper = [(x, w) for x, w in reversed(side)]
    return lower + [(length - notch, 0.0)] + upper[:-1]


def heart_outline(size=1.0, n=48):
    pts = []
    for i in range(n):
        a = TAU * i / n
        x = 16 * math.sin(a) ** 3
        z = 13 * math.cos(a) - 5 * math.cos(2 * a) - 2 * math.cos(3 * a) - math.cos(4 * a)
        pts.append((x * size / 17, z * size / 17))
    return pts[::-1]


def bolt_outline(h=1.0):
    pts = [(0.18, 0.5), (-0.28, -0.04), (-0.02, -0.04), (-0.18, -0.5), (0.3, 0.08), (0.04, 0.08)]
    return [(x * h, z * h) for x, z in pts][::-1]


def crown_outline(w=1.0, h=0.62):
    """Five-point crown: base band and peaks, centred on the base middle."""
    pts = [(-0.5, 0.0), (0.5, 0.0), (0.52, 0.62), (0.32, 0.34), (0.18, 0.82), (0.0, 0.42),
           (-0.18, 0.82), (-0.32, 0.34), (-0.52, 0.62)]
    return [(x * w, z * h / 0.82) for x, z in pts]


def snowflake(name, size=1.0, thick=0.05, depth=0.04):
    """Six arms with two pairs of side branches: one mesh of overlapping thin slabs."""
    bm = bmesh.new()

    def bar(x0, z0, x1, z1, w):
        dx, dz = x1 - x0, z1 - z0
        ln = math.hypot(dx, dz)
        nx, nz = -dz / ln * w / 2, dx / ln * w / 2
        outline = [(x0 + nx, z0 + nz), (x0 - nx, z0 - nz), (x1 - nx, z1 - nz), (x1 + nx, z1 + nz)]
        geom = bmesh.ops.create_cube(bm, size=1.0)
        # map the unit cube's corners onto the bar outline, depth along Y
        for v in geom["verts"]:
            ix = 0 if v.co.x < 0 else 1
            iz = 0 if v.co.z < 0 else 1
            px, pz = outline[{(0, 0): 1, (0, 1): 0, (1, 0): 2, (1, 1): 3}[(ix, iz)]]
            v.co = Vector((px, v.co.y * depth, pz))

    for k in range(6):
        a = TAU * k / 6 + R(90)
        c, s = math.cos(a), math.sin(a)
        bar(0, 0, c * size, s * size, thick * size)
        for u, ln in ((0.45, 0.32), (0.72, 0.22)):
            bx, bz = c * size * u, s * size * u
            for side in (-1, 1):
                b = a + side * R(50)
                bar(bx, bz, bx + math.cos(b) * size * ln, bz + math.sin(b) * size * ln, thick * size * 0.8)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    me.polygons.foreach_set("use_smooth", [False] * len(me.polygons))
    return me


def sphere(name, r=1.0, subdiv=3):
    me = gc.ico_mesh(name, radius=r, subdiv=subdiv)
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    return me


def glint_mesh(name, size=1.0):
    """Four-point sparkle, thin, for twinkles."""
    return faceted_star(name, points=4, r_out=size, r_in=size * 0.16, height=size * 0.1, back=0.0)


# ---------------------------------------------------------------- objects
def put(sc, name, mesh, mat, loc=(0.0, 0.0, 0.0), rot=(0.0, 0.0, 0.0), scale=1.0, parent=None):
    ob = bpy.data.objects.new(name, mesh)
    sc.collection.objects.link(ob)
    if mat is not None and mat.name not in mesh.materials:  # meshes are shared: one slot, not one per object
        mesh.materials.append(mat)
    ob.parent, ob.location, ob.rotation_euler = parent, loc, rot
    ob.scale = (scale, scale, scale) if isinstance(scale, (int, float)) else scale
    return ob


def polar(r, deg, y=0.0):
    a = R(deg)
    return (r * math.cos(a), y, r * math.sin(a))


def laurel(sc, mat, side, r=BAND_R + 0.09, a_from=-70, a_to=50, count=10, size=0.2, y=-0.04, stem=None, splay=32):
    """A laurel branch on one side (side=-1 left, +1 right): leaves in pairs growing from a stem along the arc,
    pointing up the branch and splayed out and in, shrinking towards the tip."""
    leaf = slab("Leaf", leaf_outline(1.0, 0.36), 0.045, smooth=True)
    obs = []
    for i in range(count):
        u = i / max(1, count - 1)
        deg = a_from + (a_to - a_from) * u
        ang = 180 - deg if side < 0 else deg
        tangent = ang + (90 if side > 0 else -90)          # up the branch
        sz = size * (1.0 - 0.4 * u)
        for k in (0, 1):                                   # 0 = outer leaf, 1 = inner leaf
            direction = tangent + (-1 if k == 0 else 1) * side * splay
            ob = put(sc, f"Leaf{side}_{i}_{k}", leaf, mat, polar(r, ang, y - 0.006 * k), (0, -R(direction), 0), sz)
            bevel(ob, 0.003, 2)
            obs.append(ob)
    lo, hi = (180 - a_to, 180 - a_from + 6) if side < 0 else (a_from - 6, a_to)
    obs.append(put(sc, f"Stem{side}", tube("Stem", r, 0.008, R(lo), R(hi), 96, 8), stem or mat, (0, y + 0.01, 0)))
    return obs


def ring_of(sc, name, mesh, mat, count, r, y=0.0, a0=90.0, scale=1.0, face_out=False):
    obs = []
    for i in range(count):
        deg = a0 + 360.0 * i / count
        rot = (0.0, -R(deg - 90) if face_out else 0.0, 0.0)
        obs.append(put(sc, f"{name}{i}", mesh, mat, polar(r, deg, y), rot, scale))
    return obs


def twinkles(sc, mat, count, r_lo, r_hi, size=0.05, seed=1, y=-0.12, a_range=(0, 360)):
    """Four-point glints that flare and vanish at their own phase."""
    rnd = random.Random(seed)
    g = glint_mesh("Glint", 1.0)
    obs = []
    for i in range(count):
        deg = rnd.uniform(*a_range)
        ob = put(sc, f"Glint{i}", g, mat, polar(rnd.uniform(r_lo, r_hi), deg, y), (0, R(rnd.uniform(-10, 10)), 0), size)
        off, s = rnd.random(), size * rnd.uniform(0.7, 1.3)
        cyc = rnd.choice((1, 2))
        animate(ob, lambda t, off=off, s=s, cyc=cyc: Vector([s * max(0.0, math.sin(math.pi * ((cyc * t + off) % 1.0))) ** 3] * 3), "scale")
        obs.append(ob)
    return obs


def orbit(sc, name, mesh, mat, count, r, size, turns=1, y=-0.1, start=0.0, wobble=0.0):
    """Objects travelling round the ring: count evenly spaced, so after 1/count of a turn the picture repeats."""
    obs = []
    for i in range(count):
        a0 = start + TAU * i / count
        ob = put(sc, f"{name}{i}", mesh, mat, (0, y, 0), scale=size)
        animate(ob, lambda t, a0=a0: Vector((r * math.cos(a0 - TAU * turns * t), y,
                                              r * math.sin(a0 - TAU * turns * t) + wobble * math.sin(TAU * 3 * t + a0))))
        obs.append(ob)
    return obs


def falling(sc, name, mesh, mat, count, size, seed=3, x=(-1.0, 1.0), top=1.05, bottom=-1.05, y=-0.2, spin_turns=1,
            sway=0.06, inside=None):
    """Petals or snow drifting down: each item falls the canvas height once per loop at its own phase and fades
    in/out by scale at the ends, so the loop has no pop. `inside`: keep items out of the photo (r < inside)."""
    rnd = random.Random(seed)
    obs = []
    for i in range(count):
        px, off = rnd.uniform(*x), (i + rnd.uniform(0, 0.6)) / count
        s = size * rnd.uniform(0.7, 1.2)
        tilt = (R(rnd.uniform(0, 360)), R(rnd.uniform(0, 360)), R(rnd.uniform(0, 360)))
        ob = put(sc, f"{name}{i}", mesh, mat, (px, y, top), tilt, s)

        def pos(t, px=px, off=off):
            u = (t + off) % 1.0
            z = top + (bottom - top) * u
            xx = px + sway * math.sin(TAU * (u * 2 + off))
            if inside and xx * xx + z * z < inside * inside:  # keep the face clear: push out to the rim
                k = inside / max(1e-3, math.hypot(xx, z))
                xx, z = xx * k, z * k
            return Vector((xx, y, z))

        def scl(t, off=off, s=s):
            u = (t + off) % 1.0
            return Vector([s * min(1.0, u / 0.12, (1 - u) / 0.12)] * 3)

        animate(ob, pos)
        animate(ob, scl, "scale")
        animate(ob, lambda t, tilt=tilt, off=off: (tilt[0] + TAU * spin_turns * t, tilt[1] + TAU * t, tilt[2]),
                "rotation_euler")
        obs.append(ob)
    return obs


def text(sc, name, body, mat, size=0.14, loc=(0.0, -0.2, -0.80), extrude=0.01, bold=0.004, spacing=1.1):
    cu = bpy.data.curves.new(name, "FONT")
    cu.body = body
    cu.align_x, cu.align_y = "CENTER", "CENTER"
    cu.size, cu.extrude, cu.bevel_depth, cu.bevel_resolution = size, extrude, bold, 2
    cu.space_character = spacing
    ob = bpy.data.objects.new(name, cu)
    sc.collection.objects.link(ob)
    ob.data.materials.append(mat)
    ob.location, ob.rotation_euler = loc, (R(90), 0, 0)
    return ob


def pill(name, w=0.62, h=0.17, depth=0.06, n=10):
    r = h / 2
    pts = []
    for cx, a0 in ((w / 2 - r, -90), (-w / 2 + r, 90)):
        for i in range(n + 1):
            a = R(a0 + 180 * i / n)
            pts.append((cx + r * math.cos(a), r * math.sin(a)))
    return slab(name, pts, depth)


def banner(name, w=0.9, h=0.17, arch=0.06, depth=0.025, n=24):
    """Ribbon banner across the bottom, its ends lifted by `arch` (a gentle smile)."""
    top, bot = [], []
    for i in range(n + 1):
        u = -1 + 2 * i / n
        lift = arch * u * u
        top.append((u * w / 2, h / 2 + lift))
        bot.append((u * w / 2, -h / 2 + lift))
    return slab(name, bot + top[::-1], depth, smooth=True)


def banner_tails(name, w=0.9, h=0.17, arch=0.06, tail=0.16, depth=0.02):
    """The two folded tails behind the banner ends, with a V notch."""
    meshes = []
    for side in (-1, 1):
        x0 = side * (w / 2 - 0.04)
        z0 = arch + 0.035
        pts = [(x0, z0 + h / 2 - 0.02), (x0 + side * tail, z0 + h / 2 - 0.05), (x0 + side * (tail - 0.06), z0),
               (x0 + side * tail, z0 - h / 2 + 0.01), (x0, z0 - h / 2 + 0.04)]
        if side < 0:
            pts = pts[::-1]
        meshes.append(slab(f"{name}{side}", pts, depth))
    return meshes


def emblem(sc, kind, mat, loc, size=0.07):
    """Small original UZARO icons for the label plates (no brand marks)."""
    rot = (0.0, 0.0, 0.0)
    if kind == "star":
        me = faceted_star("EmStar", 5, 1.0, 0.45, 0.3)
    elif kind == "heart":
        me = slab("EmHeart", heart_outline(1.0), 0.3)
    elif kind == "leaf":
        me = slab("EmLeaf", [(x - 0.5, z) for x, z in leaf_outline(1.0, 0.5)], 0.25)
        rot = (0.0, -R(45), 0.0)
    elif kind == "flame":
        me = slab("EmFlame", [(0.5 * math.sin(a) * (1 - 0.15 * math.cos(a)) * (0.4 + 0.6 * (1 - (math.cos(a) + 1) / 2) ** 0.4),
                               -0.6 * math.cos(a)) for a in [TAU * i / 32 for i in range(32)]][::-1], 0.25)
    elif kind == "bolt":
        me = slab("EmBolt", bolt_outline(1.6), 0.25)
    elif kind == "gem":
        me = brilliant("EmGem", 0.7, 8)
    elif kind == "crown":
        me = slab("EmCrown", [(x, z - 0.35) for x, z in crown_outline(1.3, 0.9)], 0.25)
    elif kind == "snow":
        me = snowflake("EmSnow", 0.8, 0.12, 0.25)
    elif kind == "shield":
        pts = [(0.0, -0.62), (0.46, -0.25), (0.48, 0.42), (0.0, 0.58), (-0.48, 0.42), (-0.46, -0.25)]
        me = slab("EmShield", pts, 0.25)
    else:  # "u": the UZARO monogram, a rounded U
        outer = [(0.5 * math.cos(R(a)), -0.1 + 0.5 * math.sin(R(a))) for a in range(180, 361, 15)]
        inner = [(0.26 * math.cos(R(a)), -0.1 + 0.26 * math.sin(R(a))) for a in range(360, 179, -15)]
        me = slab("EmU", outer + [(0.5, 0.55), (0.26, 0.55)] + inner + [(-0.26, 0.55), (-0.5, 0.55)], 0.25)
    ob = put(sc, f"Emblem_{kind}", me, mat, loc, rot, size)
    bevel(ob, 0.04, 2)
    return ob


def plate(sc, style, label_mat, text_mat, accent_mat, icon=None, z=-0.80, w=0.64, h=0.18, icon_mat=None):
    """The UZARO label plate. style: 'pill' (rounded tag), 'banner' (ribbon), 'gem' (faceted slab)."""
    obs = []
    y = -0.25
    w = w + (0.12 if icon else 0.0)
    if style == "banner":
        obs.append(put(sc, "Banner", banner("Banner", w, h), label_mat, (0, y, z)))
        for me in banner_tails("Tail", w, h):
            obs.append(put(sc, "Tail", me, accent_mat, (0, y + 0.03, z - 0.02)))
    else:
        obs.append(bevel(put(sc, "Pill", pill("Pill", w, h), label_mat, (0, y, z)), 0.015, 3))
        obs.append(put(sc, "PillRim", pill("PillRim", w + 0.03, h + 0.03, 0.04), accent_mat, (0, y + 0.02, z)))
    x_text = 0.06 if icon else 0.0
    lift = 0.06 * 0.25 if style == "banner" else 0.0     # the banner's middle sits a little low
    obs.append(text(sc, "Label", "UZARO", text_mat, size=h * 0.74, loc=(x_text, y - 0.045, z - h * 0.02 + lift)))
    if icon:
        obs.append(emblem(sc, icon, icon_mat or accent_mat, (-w / 2 + h * 0.7, y - 0.05, z + lift), size=h * 0.32))
    return obs
