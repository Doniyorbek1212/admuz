"""UZARO v2 show: starship (tier 4, 168 f = 7 s).

An original pearl-and-turquoise craft drops out of warp in a flash of stretched starlight, sweeps toward the lens,
banks across the frame with its engines burning blue, turns away, charges and jumps to light speed in a second flash.
Everything is built here from lathe and polygon meshes: no file model, no real-world design.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, env  # noqa: E402

ID = "starship"
TOTAL = 168
K = 0.95                       # ship scale: built 5.4 long
EXIT_F, JUMP_F = 12, 128
# (frame, position): warp exit far up the lens axis, sweep in, bank left, turn away, hold, jump
PATH = [(EXIT_F, (1.0, 46.0, 3.6)), (20, (0.9, 18.0, 2.6)), (40, (0.5, 3.5, 1.0)), (64, (-0.2, -2.5, -0.9)),
        (90, (-0.3, 1.0, 0.2)), (112, (-0.2, 7.0, 1.6)), (JUMP_F - 1, (0.3, 11.0, 2.0))]
EXIT = Vector(PATH[0][1])
GLOW = (0.45, 0.85, 1.0)
HOT = (0.85, 0.96, 1.0)
STREAKS = 110


# ---------------------------------------------------------------- path
def hermite(keys, f):
    """Non-uniform Catmull-Rom through (frame, point) keys; clamps outside the keyed range."""
    if f <= keys[0][0]:
        return Vector(keys[0][1])
    if f >= keys[-1][0]:
        return Vector(keys[-1][1])
    i = max(j for j in range(len(keys) - 1) if keys[j][0] <= f)
    (f0, p0), (f1, p1) = keys[i], keys[i + 1]
    p0, p1, dt = Vector(p0), Vector(p1), f1 - f0

    def tangent(j):
        a, b = keys[max(j - 1, 0)], keys[min(j + 1, len(keys) - 1)]
        return (Vector(b[1]) - Vector(a[1])) / (b[0] - a[0]) * dt

    m0, m1 = tangent(i), tangent(i + 1)
    s = (f - f0) / dt
    h00, h10, h01, h11 = 2 * s**3 - 3 * s**2 + 1, s**3 - 2 * s**2 + s, -2 * s**3 + 3 * s**2, s**3 - s**2
    return h00 * p0 + h10 * m0 + h01 * p1 + h11 * m1


def heading(f):
    d = hermite(PATH, f + 0.5) - hermite(PATH, f - 0.5)
    return d if d.length > 1e-4 else Vector((0.0, 1.0, 0.0))


# ---------------------------------------------------------------- materials
def hull_material():
    """Pearl enamel with panel seams (brick mortar as bump) and a turquoise band down the spine."""
    m = stage.pbr("Hull", (0.86, 0.87, 0.9), metallic=0.25, roughness=0.24, coat=0.6)
    nt = m.node_tree
    N, L = nt.nodes.new, nt.links.new
    b = stage.bsdf(m)
    tc = N("ShaderNodeTexCoord")
    brick = N("ShaderNodeTexBrick")
    brick.inputs["Scale"].default_value = 1.6
    brick.inputs["Mortar Size"].default_value = 0.012
    brick.inputs["Color1"].default_value = brick.inputs["Color2"].default_value = (1, 1, 1, 1)
    brick.inputs["Mortar"].default_value = (0, 0, 0, 1)
    L(tc.outputs["Object"], brick.inputs["Vector"])
    bump = N("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.35
    L(brick.outputs["Color"], bump.inputs["Height"])
    L(bump.outputs[0], b.inputs["Normal"])
    sep = N("ShaderNodeSeparateXYZ")
    L(tc.outputs["Object"], sep.inputs[0])
    ab = N("ShaderNodeMath")
    ab.operation = "ABSOLUTE"
    L(sep.outputs["X"], ab.inputs[0])
    band = N("ShaderNodeMapRange")                  # spine stripe: |x| < 0.12 on the top half
    band.inputs["From Min"].default_value, band.inputs["From Max"].default_value = 0.1, 0.13
    band.inputs["To Min"].default_value, band.inputs["To Max"].default_value = 1.0, 0.0
    L(ab.outputs[0], band.inputs["Value"])
    top = N("ShaderNodeMapRange")
    top.inputs["From Min"].default_value, top.inputs["From Max"].default_value = 0.15, 0.25
    L(sep.outputs["Z"], top.inputs["Value"])
    mask = N("ShaderNodeMath")
    mask.operation = "MULTIPLY"
    L(band.outputs["Result"], mask.inputs[0])
    L(top.outputs["Result"], mask.inputs[1])
    mix = N("ShaderNodeMix")
    mix.data_type = "RGBA"
    mix.inputs["A"].default_value = (0.86, 0.87, 0.9, 1)
    mix.inputs["B"].default_value = (0.0, 0.42, 0.5, 1)
    L(mask.outputs[0], mix.inputs["Factor"])
    L(mix.outputs["Result"], b.inputs["Base Color"])
    return m


def wing_material():
    """Pearl at the root fading to turquoise at the tips, same seams."""
    m = hull_material()
    m.name = "Wing"
    nt = m.node_tree
    mix = next(n for n in nt.nodes if n.bl_idname == "ShaderNodeMix")
    ab = next(n for n in nt.nodes if n.bl_idname == "ShaderNodeMath" and n.operation == "ABSOLUTE")
    tip = nt.nodes.new("ShaderNodeMapRange")
    tip.inputs["From Min"].default_value, tip.inputs["From Max"].default_value = 1.6, 2.1
    nt.links.new(ab.outputs[0], tip.inputs["Value"])
    nt.links.new(tip.outputs["Result"], mix.inputs["Factor"])
    return m


def glow_material(name, rgb, strength, power=2.0, axis="Z"):
    """Emission that fades to transparent along a generated axis (1 = bright end): engine plumes and streaks."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out, tc, sep = N("ShaderNodeOutputMaterial"), N("ShaderNodeTexCoord"), N("ShaderNodeSeparateXYZ")
    L(tc.outputs["Generated"], sep.inputs[0])
    pw = N("ShaderNodeMath")
    pw.operation = "POWER"
    pw.inputs[1].default_value = power
    L(sep.outputs[axis], pw.inputs[0])
    lw = N("ShaderNodeLayerWeight")                  # soft edges: no polygon rim on the cone
    lw.inputs["Blend"].default_value = 0.5
    soft = N("ShaderNodeMapRange")
    soft.inputs["From Min"].default_value, soft.inputs["From Max"].default_value = 0.85, 0.2
    L(lw.outputs["Facing"], soft.inputs["Value"])
    fade = N("ShaderNodeValue")
    fade.name = "Fade"
    fade.outputs[0].default_value = 1.0
    a = N("ShaderNodeMath")
    a.operation = "MULTIPLY"
    L(pw.outputs[0], a.inputs[0])
    L(soft.outputs["Result"], a.inputs[1])
    b = N("ShaderNodeMath")
    b.operation, b.use_clamp = "MULTIPLY", True
    L(a.outputs[0], b.inputs[0])
    L(fade.outputs[0], b.inputs[1])
    fx._emit_mix(nt, rgb, strength, b.outputs[0], out)
    return m


def disc_material(name, rgb, strength, power=3.0):
    """Radial glow on a unit disc: flashes and lens flares. Key nodes['Fade']."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out, tc = N("ShaderNodeOutputMaterial"), N("ShaderNodeTexCoord")
    ln = N("ShaderNodeVectorMath")
    ln.operation = "LENGTH"
    L(tc.outputs["Object"], ln.inputs[0])
    inv = N("ShaderNodeMath")
    inv.operation, inv.use_clamp = "SUBTRACT", True
    inv.inputs[0].default_value = 1.0
    L(ln.outputs["Value"], inv.inputs[1])
    pw = N("ShaderNodeMath")
    pw.operation = "POWER"
    pw.inputs[1].default_value = power
    L(inv.outputs[0], pw.inputs[0])
    fade = N("ShaderNodeValue")
    fade.name = "Fade"
    mul = N("ShaderNodeMath")
    mul.operation, mul.use_clamp = "MULTIPLY", True
    L(pw.outputs[0], mul.inputs[0])
    L(fade.outputs[0], mul.inputs[1])
    fx._emit_mix(nt, rgb, strength, mul.outputs[0], out)
    return m


# ---------------------------------------------------------------- meshes
def along_y(me):
    """Lathe meshes revolve about Z; turn them so +Z (the nose) points along -Y."""
    me.transform(Matrix.Rotation(R(90), 4, "X"))
    return me


def wing_mesh(name, side):
    """Swept wing with thickness, a dihedral kink and a small up-turned tip fin."""
    plan = [(0.45, -0.7), (2.45, 1.05), (2.7, 1.75), (2.55, 1.95), (0.5, 1.95)]
    t = 0.07
    bm = bmesh.new()
    top = [bm.verts.new((side * x, y, t + 0.08 * max(0.0, x - 0.45))) for x, y in plan]
    bot = [bm.verts.new((side * x, y, -t + 0.08 * max(0.0, x - 0.45))) for x, y in plan]
    n = len(plan)
    bm.faces.new(top if side > 0 else top[::-1])
    bm.faces.new(bot[::-1] if side > 0 else bot)
    for i in range(n):
        j = (i + 1) % n
        q = (top[i], bot[i], bot[j], top[j]) if side > 0 else (top[j], bot[j], bot[i], top[i])
        bm.faces.new(q)
    fin = [(2.45, 1.05, 0.24), (2.7, 1.75, 0.24), (2.62, 1.9, 0.9), (2.52, 1.55, 0.9)]
    fv = [bm.verts.new((side * x, y, z)) for x, y, z in fin]
    fv2 = [bm.verts.new((side * (x + 0.05), y, z)) for x, y, z in fin]
    bm.faces.new(fv)
    bm.faces.new(fv2[::-1])
    for i in range(4):
        j = (i + 1) % 4
        bm.faces.new((fv[i], fv[j], fv2[j], fv2[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return me


def disc_mesh(name, segs=48):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_circle(bm, cap_ends=True, radius=1.0, segments=segs)
    bm.to_mesh(me)
    bm.free()
    return me


def build_ship(sc):
    """Root empty at the centre of mass; children built in ship space, nose to -Y. Returns (root, meshes, plumes)."""
    root = bpy.data.objects.new("Ship", None)
    sc.collection.objects.link(root)
    root.rotation_mode = "YXZ"                      # roll about the nose axis first, then pitch, then heading
    body = bpy.data.objects.new("ShipBody", None)
    sc.collection.objects.link(body)
    body.parent = root
    body.scale = (K, K, K)
    hull, wing = hull_material(), wing_material()
    gold = stage.pbr("Gold", (1.0, 0.72, 0.3), metallic=1.0, roughness=0.22)
    steel = stage.pbr("Steel", (0.25, 0.26, 0.28), metallic=1.0, roughness=0.35)
    glass = stage.pbr("Canopy", (0.01, 0.07, 0.09), roughness=0.04, coat=1.0)
    glass_b = stage.bsdf(glass)
    glass_b.inputs["Emission Color"].default_value = (0.1, 0.6, 0.7, 1)
    glass_b.inputs["Emission Strength"].default_value = 0.4
    fus = along_y(stage.lathe("Fuselage", [(0.0, -2.45), (0.42, -2.45), (0.6, -2.1), (0.7, -1.0), (0.66, 0.4), (0.5, 1.5),
                                           (0.28, 2.3), (0.08, 2.8), (0.0, 2.9)], 64))
    fus.transform(Matrix.Diagonal((1.0, 1.0, 0.62, 1.0)))
    parts = [stage.link(sc, "Fuselage", fus, hull, parent=body)]
    canopy = along_y(stage.lathe("Canopy", [(0.0, -0.9), (0.28, -0.75), (0.36, 0.0), (0.24, 0.8), (0.0, 1.05)], 40))
    canopy.transform(Matrix.Diagonal((1.0, 1.0, 0.55, 1.0)))
    parts.append(stage.link(sc, "Canopy", canopy, glass, parent=body, loc=(0.0, -0.7, 0.3)))
    for name, y in (("TrimA", 0.15), ("TrimB", 1.35)):
        r = 0.68 if y < 1 else 0.53
        ring = along_y(stage.lathe(name, [(r - 0.01, -0.04), (r + 0.025, -0.04), (r + 0.025, 0.04), (r - 0.01, 0.04)], 64))
        ring.transform(Matrix.Diagonal((1.0, 1.0, 0.62, 1.0)))
        parts.append(stage.link(sc, name, ring, gold, parent=body, loc=(0.0, y, 0.0)))
    plumes = []
    for side in (-1, 1):
        w = stage.link(sc, f"Wing{side}", wing_mesh(f"Wing{side}", side), wing, parent=body, loc=(0.0, 0.0, -0.12))
        bev = w.modifiers.new("Bevel", "BEVEL")
        bev.width, bev.segments = 0.025, 2
        parts.append(w)
        nac = along_y(stage.lathe(f"Nacelle{side}", [(0.0, -1.1), (0.2, -1.05), (0.26, -0.7), (0.27, 0.6), (0.22, 1.0), (0.0, 1.0)], 40))
        parts.append(stage.link(sc, f"Nacelle{side}", nac, hull, parent=body, loc=(side * 0.95, 1.05, -0.1)))
        intake = along_y(stage.lathe(f"Intake{side}", [(0.19, -0.03), (0.27, -0.03), (0.27, 0.05), (0.19, 0.05)], 40))
        parts.append(stage.link(sc, f"Intake{side}", intake, gold, parent=body, loc=(side * 0.95, -0.05, -0.1)))
        bell = along_y(stage.lathe(f"Bell{side}", [(0.12, 0.0), (0.22, -0.3), (0.2, -0.3), (0.1, 0.0)], 32))
        parts.append(stage.link(sc, f"Bell{side}", bell, steel, parent=body, loc=(side * 0.95, 2.05, -0.1)))
        plumes.append(plume(sc, body, f"Plume{side}", (side * 0.95, 2.3, -0.1), 0.19, 1.8))
        light = stage.link(sc, f"Tip{side}", gc.ico_mesh(f"Tip{side}", 0.05, 2), stage.emit(f"Tip{side}", (1.0, 0.15, 0.1) if side < 0 else (0.2, 1.0, 0.4), 10.0),
                           parent=body, loc=(side * 2.62, 1.9, 0.92), shadow=False)
        parts.append(light)
    bell = along_y(stage.lathe("BellMain", [(0.2, 0.0), (0.34, -0.36), (0.31, -0.36), (0.17, 0.0)], 40))
    parts.append(stage.link(sc, "BellMain", bell, steel, parent=body, loc=(0.0, 2.45, 0.0)))
    plumes.append(plume(sc, body, "PlumeMain", (0.0, 2.75, 0.0), 0.3, 2.6))
    return root, parts, plumes


def plume(sc, parent, name, loc, r, length):
    """Blue engine flame: a cone along +Y with a white-hot core, keyed through nodes['Fade'] of both materials."""
    cone = stage.lathe(name, [(0.0, 0.0), (r, -0.02), (r * 0.8, -length * 0.3), (r * 0.35, -length * 0.75), (0.0, -length)], 24)
    outer = glow_material(f"{name}Glow", GLOW, 4.0, power=2.2)
    ob = stage.link(sc, name, cone, outer, parent=parent, loc=loc, shadow=False)
    ob.rotation_euler = (R(90), 0, 0)               # local -Z (the cone) -> +Y, behind the ship
    core = stage.lathe(f"{name}Core", [(0.0, 0.0), (r * 0.55, -0.02), (r * 0.3, -length * 0.35), (0.0, -length * 0.55)], 16)
    inner = glow_material(f"{name}CoreGlow", HOT, 10.0, power=1.8)
    c = stage.link(sc, f"{name}Core", core, inner, parent=parent, loc=loc, shadow=False)
    c.rotation_euler = (R(90), 0, 0)
    for o in (ob, c):
        o.cycles.use_motion_blur = False             # the flame already reads as motion; blur turns it to mist
    return ob, c, outer, inner


# ---------------------------------------------------------------- animation
def animate(root, plumes):
    yaws = {}
    for f in range(1, TOTAL + 1):
        d = heading(f)
        yaws[f] = stage.aim(d)
    prev = None
    unwrap = {}
    for f in range(1, TOTAL + 1):                    # continuous yaw for the bank estimate
        y = yaws[f][1]
        if prev is not None:
            while y - prev > math.pi:
                y -= 2 * math.pi
            while y - prev < -math.pi:
                y += 2 * math.pi
        unwrap[f], prev = y, y
    for f in range(1, JUMP_F + 4):
        pos = hermite(PATH, f)
        pitch, _ = yaws[f]
        rate = (unwrap[min(f + 2, TOTAL)] - unwrap[max(f - 2, 1)]) / 4
        roll = max(-R(48), min(R(48), -rate * 14.0))
        stretch = 1.0
        if f < EXIT_F:
            pos = EXIT.copy()
            stretch = 0.0
        elif f < EXIT_F + 8:
            stretch = 1.0 + 7.0 * (1 - env(f, EXIT_F, EXIT_F + 8))
        if f >= JUMP_F:                              # light-speed jump: away up the lens axis in four frames
            k = f - JUMP_F + 1
            pos = hermite(PATH, JUMP_F - 1) + heading(JUMP_F - 1).normalized() * (8.0 * k**2.6)
            stretch = 1.0 + 3.0 * k
        root.location = pos
        root.rotation_euler = (pitch, roll, unwrap[f])
        root.scale = (1.0 if stretch else 0.0, max(stretch, 0.0), 1.0 if stretch else 0.0)
        for path in ("location", "rotation_euler", "scale"):
            root.keyframe_insert(path, frame=f)
    root.scale = (0.0, 0.0, 0.0)
    root.keyframe_insert("scale", frame=JUMP_F + 4)
    for ob, c, outer, inner in plumes:               # idle burn, flicker, charge before the jump
        for f in range(EXIT_F, JUMP_F + 4, 2):
            charge = env(f, 112, JUMP_F - 1)
            base = 0.75 + 0.1 * math.sin(f * 1.7) + 0.06 * math.sin(f * 3.1)
            s = (1.0 + 0.6 * charge) * base
            ob.scale = c.scale = (1.0 + 0.25 * charge, 1.0 + 0.25 * charge, s)
            ob.keyframe_insert("scale", frame=f)
            c.keyframe_insert("scale", frame=f)
        stage.key_socket(inner.node_tree.nodes["Fade"].outputs[0], [(EXIT_F, 0.6), (112, 0.7), (JUMP_F - 1, 1.0)])


def streak_material():
    m = glow_material("Streak", (0.6, 0.85, 1.0), 9.0, power=1.0, axis="Y")
    nt = m.node_tree
    sep = next(n for n in nt.nodes if n.bl_idname == "ShaderNodeSeparateXYZ")
    pw = next(n for n in nt.nodes if n.bl_idname == "ShaderNodeMath" and n.operation == "POWER")
    tri = nt.nodes.new("ShaderNodeMath")             # bright in the middle of the streak, gone at both ends
    tri.operation = "PINGPONG"
    tri.inputs[1].default_value = 0.5
    nt.links.new(sep.outputs["Y"], tri.inputs[0])
    dbl = nt.nodes.new("ShaderNodeMath")
    dbl.operation = "MULTIPLY"
    dbl.inputs[1].default_value = 2.0
    nt.links.new(tri.outputs[0], dbl.inputs[0])
    nt.links.new(dbl.outputs[0], pw.inputs[0])
    soft = next(n for n in nt.nodes if n.bl_idname == "ShaderNodeMapRange")
    soft.inputs["From Min"].default_value, soft.inputs["From Max"].default_value = 2.0, 1.5   # no rim fade: seen end-on
    return m


def streaks(sc):
    """Stretched starlight on rays from the lens through the warp point: rushes in and collapses at the exit, then
    shoots away along the rays through the jump point. t is the distance from the lens along the ray."""
    rng = stage.seeded(21)
    mat = streak_material()
    me = stage.box_mesh("StreakMesh", 0.055, 1.0, 0.055)
    fade = mat.node_tree.nodes["Fade"].outputs[0]
    stage.key_socket(fade, [(1, 0.0), (3, 1.0), (EXIT_F, 1.0), (EXIT_F + 14, 0.0), (JUMP_F - 1, 0.0), (JUMP_F + 1, 1.0), (JUMP_F + 18, 0.0)])
    cam = Vector((0.0, -gc.CAM_DIST, 0.0))

    def frame_for(target):
        d = (target - cam).normalized()
        u = d.cross(Vector((0, 0, 1))).normalized()
        return d, u, u.cross(d), Vector((0, 1, 0)).rotation_difference(d).to_euler()

    d_in, u_in, w_in, rot_in = frame_for(EXIT)
    d_out, u_out, w_out, rot_out = frame_for(hermite(PATH, JUMP_F - 1))
    t_out0 = (hermite(PATH, JUMP_F - 1) - cam).length
    for i in range(STREAKS):
        ob = stage.link(sc, f"Streak{i}", me, parent=None, shadow=False)
        if i == 0:
            me.materials.append(mat)
        ob.cycles.use_motion_blur = False
        a, r = rng.uniform(0, 2 * math.pi), rng.uniform(1.2, 4.2)
        t, speed = rng.uniform(30.0, 90.0), rng.uniform(0.8, 1.2)
        side = math.cos(a) * u_in + math.sin(a) * w_in
        ob.rotation_euler = rot_in
        ob.keyframe_insert("rotation_euler", frame=1)
        for f in range(1, EXIT_F + 16):              # in: long streaks rush at the lens, then shrink to points
            length = 26.0 * (1 - env(f, EXIT_F - 2, EXIT_F + 10)) + 0.15
            t -= 9.0 * speed * (1 - env(f, EXIT_F - 2, EXIT_F + 8)) + 0.3
            if t - length / 2 < 22.0:                # nearer than 22 a streak would reach the frame corners
                t += 70.0
            ob.location = cam + d_in * t + side * r
            ob.scale = (1.0, length, 1.0)
            ob.keyframe_insert("location", frame=f)
            ob.keyframe_insert("scale", frame=f)
        side = math.cos(a) * u_out + math.sin(a) * w_out
        ob.rotation_euler = rot_out
        ob.keyframe_insert("rotation_euler", frame=JUMP_F - 1)
        t = t_out0 + rng.uniform(2.0, 30.0)
        for f in range(JUMP_F - 1, JUMP_F + 20):     # out: points stretch and fly away after the ship
            k = max(0, f - JUMP_F + 1)
            length = 0.15 + 3.0 * k
            t += 1.5 * k * speed
            ob.location = cam + d_out * (t + length / 2) + side * r
            ob.scale = (1.0, length, 1.0)
            ob.keyframe_insert("location", frame=f)
            ob.keyframe_insert("scale", frame=f)


def flash(sc, name, at, frame, size, length):
    """Bright disc plus a thin anamorphic bar, facing the lens."""
    for kind, scale, rgb, strength, power in (("Core", (size, size, 1.0), HOT, 16.0, 4.0), ("Bar", (size * 3.0, size * 0.03, 1.0), GLOW, 12.0, 2.0)):
        mat = disc_material(f"{name}{kind}", rgb, strength, power)
        ob = stage.link(sc, f"{name}{kind}", disc_mesh(f"{name}{kind}"), mat, loc=at, shadow=False)
        ob.rotation_euler = (R(90), 0, 0)
        fade = mat.node_tree.nodes["Fade"].outputs[0]
        stage.key_socket(fade, [(frame - 2, 0.0), (frame, 1.0), (frame + length, 0.0)])
        for f, s in ((frame - 2, 0.2), (frame, 1.0), (frame + length, 1.4)):
            ob.scale = tuple(c * s for c in scale[:2]) + (1.0,)
            ob.keyframe_insert("scale", frame=f)


def sparks(sc, name, at, frames, count, speed, size):
    mat = fx.fade_material(f"{name}Mat", GLOW, 16.0)
    return fx.particle_burst(sc, name, fx.point_mesh(f"{name}Src", 0.3), mat, count, frames, 22, size, speed, rand=1.0,
                             damping=0.06, location=at)


def trail(sc, root):
    """Blue sparkle left behind the engines while the ship flies."""
    mat = fx.fade_material("TrailMat", GLOW, 10.0, power=2.0)
    em = fx.particle_burst(sc, "Trail", fx.point_mesh("TrailSrc", 0.15), mat, 420, (EXIT_F + 4, JUMP_F), 20, 0.022, 0.25, rand=0.6)
    em.parent = root
    em.location = (0.0, 2.6 * K, 0.0)
    return em


def engine_light(sc, root):
    ld = bpy.data.lights.new("EngineLight", "POINT")
    ld.color, ld.shadow_soft_size, ld.energy = GLOW, 0.6, 600.0
    ob = bpy.data.objects.new("EngineLight", ld)
    sc.collection.objects.link(ob)
    ob.parent = root
    ob.location = (0.0, 3.4 * K, 0.4)


# ---------------------------------------------------------------- shows
def build_show(sc, opts):
    root, meshes, plumes = build_ship(sc)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.7, hdri="studio.exr", follow=root, lights=0.8, fog=(2.0, 7), streak=6.0, shutter=0.4)
    animate(root, plumes)
    engine_light(sc, root)
    streaks(sc)
    flash(sc, "ExitFlash", EXIT, EXIT_F, 1.6, 12)
    flash(sc, "JumpFlash", hermite(PATH, JUMP_F - 1), JUMP_F + 1, 1.3, 18)
    ring = fx.shock_ring(sc, "JumpRing", tuple(hermite(PATH, JUMP_F - 1)), (JUMP_F + 1, JUMP_F + 20), 3.2, GLOW, 5.0, width=0.1)
    ring.rotation_euler = (R(90), 0, 0)
    sparks(sc, "ExitSparks", tuple(EXIT - Vector((0, 2, 0))), (EXIT_F, EXIT_F + 2), 140, 5.0, 0.09)
    sparks(sc, "JumpSparks", tuple(hermite(PATH, JUMP_F - 1)), (JUMP_F, JUMP_F + 2), 160, 3.5, 0.06)
    trail(sc, root)
    sh.camera_shake(cam, JUMP_F, 14, amp=0.05, rot_deg=0.3, seed=5)
    sh.screen_extent(sc, cam, meshes, (20, 40, 64, 80, 90, 112, JUMP_F - 1))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Three-quarter front view, hovering: a gentle bob and bank, engines pulse; every curve closes on the loop."""
    root, meshes, plumes = build_ship(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=0.7, hdri="studio.exr", follow=root, lights=0.8, fog=(2.0, 7), streak=6.0)
    pitch, yaw = stage.aim((-0.75, -0.55, -0.12))
    n = stage.ICON_N
    for f in range(0, n + 1):
        w = 2 * math.pi * f / n
        root.location = (0.0, 0.0, 0.08 * math.sin(w))
        root.rotation_euler = (pitch + R(3) * math.sin(w + 1.0), R(-14) + R(6) * math.sin(w), yaw)
        root.keyframe_insert("location", frame=f)
        root.keyframe_insert("rotation_euler", frame=f)
        for ob, c, _, _ in plumes:
            s = 0.8 + 0.1 * math.sin(3 * w) + 0.05 * math.sin(5 * w)
            ob.scale = c.scale = (1.0, 1.0, s)
            ob.keyframe_insert("scale", frame=f)
            c.keyframe_insert("scale", frame=f)
    engine_light(sc, root)
    sc.frame_set(1)
    stage.frame_icon(cam, meshes + [p[0] for p in plumes], pad=1.08)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
