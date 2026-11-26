"""UZARO v2 show: steam_train (tier 2, 120 f = 5 s).

An original vintage tank locomotive rushes across on a short patch of track that fades out at both ends. Its wheels
roll without slipping; crank pins, coupling rods, main rods and crossheads are solved from the wheel angle every frame.
Smoke is a Mantaflow plume from the chimney, sparks fly from the stack, and a whistle throws a white burst of steam.
Everything is built here; livery is generic (green, red, brass), not any real engine.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gas  # noqa: E402
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, env  # noqa: E402

ID = "steam_train"
TOTAL = 120
GROUND_Z = -3.0
YAW = R(-18)                            # front (+X) runs right and a little toward the lens
SPEED = 0.17                            # units per frame
K = 0.95
WR, AX = 0.55, (-1.3, -0.1, 1.1)        # drive wheel radius and axle x (local, before K)
LEAD_R, LEAD_X = 0.3, 2.25
CRANK, ROD_L = 0.28, 1.55
SIDE_Y = 0.64                           # wheel plane
WHISTLE = 64
GREEN, RED, BRASS, BLACK = (0.02, 0.12, 0.06), (0.45, 0.03, 0.02), (0.95, 0.68, 0.3), (0.02, 0.02, 0.022)


def dist(f):
    return SPEED * (f - 1)


def cyl_x(name, r, x0, x1, segs=40):
    """Cylinder along local X."""
    me = stage.lathe(name, [(0.0, x0), (r, x0), (r, x1), (0.0, x1)], segs)
    me.transform(Matrix.Rotation(R(90), 4, "Y"))
    return me


def wheel_mesh(name, r, spokes=12):
    """Tyre, rim, hub, spokes and a counterweight crescent, in the XZ plane (axle along Y)."""
    bm = bmesh.new()
    me = stage.lathe(f"{name}Rim", [(r * 0.8, -0.06), (r, -0.06), (r, 0.06), (r * 0.8, 0.06), (r * 0.8, -0.06)], 48, smooth_shade=False)
    me.transform(Matrix.Rotation(R(90), 4, "X"))
    bm.from_mesh(me)
    hub = stage.lathe(f"{name}Hub", [(0.0, -0.08), (r * 0.2, -0.08), (r * 0.2, 0.08), (0.0, 0.08)], 24)
    hub.transform(Matrix.Rotation(R(90), 4, "X"))
    bm.from_mesh(hub)
    for k in range(spokes):
        a = 2 * math.pi * k / spokes
        sp = stage.box_mesh("Spoke", 0.05, 0.05, r * 0.65)
        sp.transform(Matrix.Translation((0, 0, r * 0.5)))
        sp.transform(Matrix.Rotation(a, 4, "Y"))
        bm.from_mesh(sp)
    out = bpy.data.meshes.new(name)
    bm.to_mesh(out)
    bm.free()
    return out


def build(sc):
    root = bpy.data.objects.new("Loco", None)
    sc.collection.objects.link(root)
    body = bpy.data.objects.new("LocoBody", None)
    sc.collection.objects.link(body)
    body.parent = root
    body.scale = (K, K, K)
    green = stage.pbr("Green", GREEN, roughness=0.3, coat=0.6)
    red = stage.pbr("Red", RED, roughness=0.35, coat=0.4)
    brass = stage.pbr("Brass", BRASS, metallic=1.0, roughness=0.22)
    black = stage.pbr("Black", BLACK, roughness=0.5)
    steel = stage.pbr("Steel", (0.55, 0.56, 0.58), metallic=1.0, roughness=0.3)
    glass = stage.pbr("Window", (0.02, 0.03, 0.03), roughness=0.05, emission=(1.0, 0.6, 0.25), strength=0.8)
    parts = []

    def add(name, me, mat, loc=(0, 0, 0)):
        ob = stage.link(sc, name, me, mat, parent=body, loc=loc)
        parts.append(ob)
        return ob

    add("Frame", stage.box_mesh("Frame", 5.3, 1.25, 0.18), red, (0.25, 0, 0.98))
    add("Boiler", cyl_x("Boiler", 0.56, -0.7, 2.45, 48), green, (0, 0, 1.65))
    add("Smokebox", cyl_x("Smokebox", 0.6, 1.9, 2.6, 48), black, (0, 0, 1.65))
    for x in (-0.2, 0.7, 1.6):
        add(f"Band{x}", cyl_x(f"Band{x}", 0.575, x - 0.03, x + 0.03), brass, (0, 0, 1.65))
    add("Door", cyl_x("Door", 0.42, 2.6, 2.66), steel, (0, 0, 1.65))
    add("Stack", stage.lathe("Stack", [(0.0, 0.0), (0.2, 0.0), (0.17, 0.5), (0.22, 0.8), (0.3, 0.92), (0.28, 0.98), (0.0, 0.98)], 32), black, (2.15, 0, 2.1))
    add("StackRim", stage.lathe("StackRim", [(0.26, 0.0), (0.32, 0.0), (0.32, 0.07), (0.26, 0.07)], 32), brass, (2.15, 0, 3.0))
    add("Dome", stage.lathe("Dome", [(0.0, 0.0), (0.3, 0.0), (0.28, 0.2), (0.2, 0.38), (0.0, 0.45)], 32), brass, (0.85, 0, 2.12))
    add("Cab", stage.box_mesh("Cab", 1.7, 1.35, 1.75), green, (-1.55, 0, 1.95))
    add("Roof", stage.box_mesh("Roof", 1.95, 1.5, 0.08), black, (-1.55, 0, 2.86))
    for y in (-0.68, 0.68):
        add(f"CabWin{y}", stage.box_mesh(f"CabWin{y}", 0.7, 0.02, 0.55), glass, (-1.45, y, 2.3))
    add("Whistle", stage.lathe("Whistle", [(0.0, 0.0), (0.05, 0.0), (0.05, 0.25), (0.08, 0.3), (0.0, 0.34)], 16), brass, (-0.55, 0, 2.2))
    lamp = add("Lamp", stage.lathe("Lamp", [(0.0, 0.0), (0.14, 0.0), (0.16, 0.22), (0.0, 0.22)], 24), brass, (2.45, 0, 2.3))
    lamp.rotation_euler = (0, R(90), 0)
    add("LampGlow", cyl_x("LampGlow", 0.13, 2.67, 2.69), stage.emit("LampGlow", (1.0, 0.85, 0.6), 12.0), (0, 0, 2.3))
    pilot = bmesh.new()                                                        # cowcatcher wedge
    vs = [pilot.verts.new(p) for p in ((2.85, -0.62, 1.0), (2.85, 0.62, 1.0), (3.35, 0.0, 0.28), (2.85, -0.62, 0.28), (2.85, 0.62, 0.28))]
    pilot.faces.new((vs[0], vs[3], vs[2]))
    pilot.faces.new((vs[1], vs[2], vs[4]))
    pilot.faces.new((vs[0], vs[2], vs[1]))
    pilot.faces.new((vs[3], vs[4], vs[2]))
    pm = bpy.data.meshes.new("Pilot")
    pilot.to_mesh(pm)
    pilot.free()
    add("Pilot", pm, red)
    rig = {"wheels": [], "pins": [], "rods": [], "main": [], "cross": []}
    wm, lm = wheel_mesh("DriveWheel", WR), wheel_mesh("LeadWheel", LEAD_R, 8)
    wm.materials.append(red)
    lm.materials.append(red)
    for side, phase in ((-1, 0.0), (1, math.pi / 2)):                       # quartered: one side 90 degrees ahead
        for x in AX:
            w = stage.link(sc, f"W{side}{x}", wm, parent=body, loc=(x, side * SIDE_Y, WR))
            rig["wheels"].append((w, WR, 0.0))
            parts.append(w)
        lw = stage.link(sc, f"L{side}", lm, parent=body, loc=(LEAD_X, side * SIDE_Y, LEAD_R))
        rig["wheels"].append((lw, LEAD_R, 0.0))
        parts.append(lw)
        rod = stage.link(sc, f"Coupling{side}", stage.box_mesh("Coupling", AX[2] - AX[0] + 0.16, 0.05, 0.08), steel, parent=body)
        rig["rods"].append((rod, side, phase))
        main = stage.link(sc, f"Main{side}", stage.box_mesh("Main", ROD_L, 0.05, 0.09), steel, parent=body)
        main.data.transform(Matrix.Translation((ROD_L / 2, 0, 0)))
        rig["main"].append((main, side, phase))
        cross = stage.link(sc, f"Cross{side}", stage.box_mesh("Cross", 0.18, 0.08, 0.14), brass, parent=body)
        prod = stage.link(sc, f"PistonRod{side}", cyl_x("PistonRod", 0.025, 0.0, 0.9, 12), steel, parent=cross)
        rig["cross"].append((cross, side, phase))
        cyl = stage.link(sc, f"Cylinder{side}", cyl_x("Cylinder", 0.2, 1.75, 2.45, 32), black, parent=body, loc=(0, side * (SIDE_Y + 0.3), WR))
        parts += [rod, main, cross, prod, cyl]
    for ob, _, _ in rig["wheels"]:
        ob.rotation_mode = "XYZ"
    return root, body, parts, rig


def solve(rig, theta):
    """Pose every moving part for drive-wheel angle theta (radians, about +Y)."""
    for w, r, _ in rig["wheels"]:
        w.rotation_euler = (0.0, theta * WR / r, 0.0)
    mid = Vector((AX[1], 0.0, WR))
    for (rod, side, ph), (main, _, _), (cross, _, _) in zip(rig["rods"], rig["main"], rig["cross"]):
        a = theta + ph
        crank = Vector((CRANK * math.sin(a), 0.0, CRANK * math.cos(a)))
        rod.location = (mid.x + crank.x, side * (SIDE_Y + 0.11), WR + crank.z)
        pin = mid + crank
        cx = pin.x + math.sqrt(ROD_L ** 2 - crank.z ** 2)                  # crosshead runs on the axle line
        main.location = (pin.x, side * (SIDE_Y + 0.17), pin.z)
        main.rotation_euler = (0.0, math.atan2(crank.z, cx - pin.x), 0.0)
        cross.location = (cx, side * (SIDE_Y + 0.3), WR)


def animate(root, rig):
    d = Vector((math.cos(YAW), math.sin(YAW), 0.0))
    start = Vector((0.0, 0.0, GROUND_Z)) - d * (dist(TOTAL) / 2 + 0.6)
    root.rotation_euler = (0.0, 0.0, YAW)
    for f in range(1, TOTAL + 1):
        root.location = start + d * dist(f)
        root.keyframe_insert("location", frame=f)
        solve(rig, dist(f) / (WR * K))
        for w, _, _ in rig["wheels"]:
            w.keyframe_insert("rotation_euler", frame=f)
        for group in ("rods", "main", "cross"):
            for ob, _, _ in rig[group]:
                ob.keyframe_insert("location", frame=f)
                ob.keyframe_insert("rotation_euler", frame=f)


def fade_ends(m):
    """Mix the material's BSDF to transparent with XY distance from the track centre (3.0 -> 5.5)."""
    nt = m.node_tree
    N, L = nt.nodes.new, nt.links.new
    b = stage.bsdf(m)
    out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL")
    geo, sep, comb, ln = N("ShaderNodeNewGeometry"), N("ShaderNodeSeparateXYZ"), N("ShaderNodeCombineXYZ"), N("ShaderNodeVectorMath")
    ln.operation = "LENGTH"
    L(geo.outputs["Position"], sep.inputs[0])
    L(sep.outputs["X"], comb.inputs["X"])
    L(sep.outputs["Y"], comb.inputs["Y"])
    L(comb.outputs[0], ln.inputs[0])
    fade = N("ShaderNodeMapRange")
    fade.inputs["From Min"].default_value, fade.inputs["From Max"].default_value = 3.0, 5.5
    fade.inputs["To Min"].default_value, fade.inputs["To Max"].default_value = 1.0, 0.0
    L(ln.outputs["Value"], fade.inputs["Value"])
    vis = N("ShaderNodeMath")                      # the track also fades in and out in time: empty first and last frames
    vis.operation = "MULTIPLY"
    L(fade.outputs["Result"], vis.inputs[0])
    stage.key_socket(vis.inputs[1], [(1, 0.0), (10, 1.0), (106, 1.0), (TOTAL - 1, 0.0)])
    tr, mix = N("ShaderNodeBsdfTransparent"), N("ShaderNodeMixShader")
    L(vis.outputs[0], mix.inputs[0])
    L(tr.outputs[0], mix.inputs[1])
    L(b.outputs[0], mix.inputs[2])
    L(mix.outputs[0], out.inputs["Surface"])
    return m


def track(sc):
    """Two rails on sleepers along the line of travel; both ends fade out, so there is no visible floor edge."""
    holder = bpy.data.objects.new("Track", None)
    sc.collection.objects.link(holder)
    holder.location = (0.0, 0.0, GROUND_Z)
    holder.rotation_euler = (0.0, 0.0, YAW)
    wood = fade_ends(stage.pbr("Sleeper", (0.2, 0.14, 0.09), roughness=0.7))
    rail = fade_ends(stage.pbr("Rail", (0.5, 0.5, 0.52), metallic=1.0, roughness=0.3))
    rm = stage.box_mesh("Rail", 14.0, 0.07, 0.1)
    rm.materials.append(rail)
    for y in (-SIDE_Y * K, SIDE_Y * K):
        stage.link(sc, f"Rail{y}", rm, parent=holder, loc=(0.0, y, 0.05))
    sl = stage.box_mesh("Sleeper", 0.22, 1.9, 0.08)
    sl.materials.append(wood)
    for i in range(-28, 29):
        stage.link(sc, f"Sleeper{i}", sl, parent=holder, loc=(i * 0.5, 0.0, -0.02))


def smoke(sc, body, test):
    mat = gas.material("Smoke", smoke_rgb=(0.55, 0.53, 0.52), density=4.0, edge_fade=(0.12, 0.2, 0.12))
    dom = gas.domain(sc, ID, (0.0, 0.0, GROUND_Z + 6.0), (5.6, 3.6, 4.4), TOTAL, mat, res=48 if test else 128, vorticity=0.5,
                     dissolve=50, alpha=0.4, beta=0.6)
    src = gas.flow(sc, "Chimney", 0.2, (2.15, 0.0, 3.0), velocity=(0.0, 0.0, 3.0), behavior="SMOKE", parent=body)
    puffs = [(f, 0.0, 1.0 + 0.8 * (f % 6 < 3)) for f in range(1, TOTAL + 1, 1)]   # chuffs: density pulses with the strokes
    gas.key_flow(src, puffs)
    return dom


def sparks(sc, body):
    mat = fx.fade_material("Spark", (1.0, 0.55, 0.15), 18.0)
    em = fx.particle_burst(sc, "Sparks", fx.point_mesh("SparkSrc", 0.12), mat, 220, (4, TOTAL - 10), 14, 0.02, 2.0, rand=1.0,
                           align=(0.0, 0.0, 3.0), gravity=0.6)
    em.parent = body
    em.location = (2.15, 0.0, 3.05)


def whistle(sc, body):
    mat = fx.fade_material("Steam", (1.0, 1.0, 1.0), 1.2, 0.35, 1.2)
    em = fx.particle_burst(sc, "Whistle", fx.point_mesh("WhistleSrc", 0.06), mat, 120, (WHISTLE, WHISTLE + 14), 26, 0.22, 0.6, rand=0.5,
                           align=(-0.6, 0.0, 3.4), damping=0.12, gravity=-0.05)
    em.parent = body
    em.location = (-0.55, 0.0, 2.55)


def build_show(sc, opts):
    root, body, parts, rig = build(sc)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.85, hdri="sunset.exr", lights=0.8, fog=(2.0, 6), streak=10.0)
    gas.filmic(sc)
    sh.shadow_catcher(sc, GROUND_Z, 60)
    animate(root, rig)
    track(sc)
    sparks(sc, body)
    whistle(sc, body)
    dom = smoke(sc, body, bool(opts["test"]))
    sh.screen_extent(sc, cam, parts, (30, 60, 90))
    gas.bake(sc, dom)
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Three-quarter front view; wheels and rods turn one full revolution per loop, so it closes exactly."""
    root, body, parts, rig = build(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=0.85, hdri="sunset.exr", lights=0.8, fog=(2.0, 6), streak=10.0)
    root.rotation_euler = (0.0, 0.0, R(-35))
    n = stage.ICON_N
    for f in range(0, n + 1):
        solve(rig, 2 * math.pi * f / n)
        for w, _, _ in rig["wheels"]:
            w.keyframe_insert("rotation_euler", frame=f)
        for group in ("rods", "main", "cross"):
            for ob, _, _ in rig[group]:
                ob.keyframe_insert("location", frame=f)
                ob.keyframe_insert("rotation_euler", frame=f)
        root.location = (0.0, 0.0, 0.015 * math.sin(4 * 2 * math.pi * f / n))
        root.keyframe_insert("location", frame=f)
    sh.shadow_catcher(sc, 0.0, 30)
    sc.frame_set(1)
    stage.frame_icon(cam, parts, pad=1.08)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
