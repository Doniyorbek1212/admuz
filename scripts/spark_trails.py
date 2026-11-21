"""Firework-style trails: every spark is a thin static tube along its own simulated path; a shader reveals it by age.

UV.x = frame this ring was reached, UV.y = spark random. "Now" is keyed per frame, the mesh never moves, so one
mesh holds thousands of long-lived trails, renders fast and needs no particle cache. Used by fireworks and castle.
"""
import math

import bpy
from mathutils import Vector

import show_common as sh
import show_fx as fx
import stage

DT = 1.0 / sh.FPS


def simulate(p0, v0, frames, gravity=9.0, drag=2.2, turbulence=0.0, rnd=None):
    """Point per frame: ballistic with air drag; slow sparks hang and sag, like real stars."""
    pts, p, v = [], Vector(p0), Vector(v0)
    for _ in range(frames):
        pts.append(p.copy())
        v = v * max(0.0, 1.0 - drag * DT) + Vector((0, 0, -gravity * DT))
        if turbulence and rnd:
            v += Vector((rnd.uniform(-1, 1), rnd.uniform(-1, 1), rnd.uniform(-1, 1))) * turbulence * DT
        p = p + v * DT
    return pts


def tube_mesh(name, tracks, radius, sides=3):
    """tracks: [(first_frame, [Vector, ...], random 0..1)]. Triangular section is enough at this thickness."""
    verts, faces, uvs = [], [], []
    up = Vector((0.13, 0.27, 0.95)).normalized()
    for first, pts, rand in tracks:
        base = len(verts)
        n = len(pts)
        for i, c in enumerate(pts):
            d = (pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)])
            d = d.normalized() if d.length > 1e-6 else Vector((0, 0, 1))
            a = d.cross(up)
            a = a.normalized() if a.length > 1e-6 else Vector((1, 0, 0))
            b = d.cross(a)
            taper = radius * (1.0 - 0.6 * i / max(1, n - 1))
            for k in range(sides):
                t = 2 * math.pi * k / sides
                verts.append(c + (a * math.cos(t) + b * math.sin(t)) * taper)
                uvs.append((first + i, rand))
        for i in range(n - 1):
            for k in range(sides):
                j = (k + 1) % sides
                faces.append((base + i * sides + k, base + i * sides + j, base + (i + 1) * sides + j, base + (i + 1) * sides + k))
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    uv = me.uv_layers.new(name="age")
    for loop in me.loops:
        uv.data[loop.index].uv = uvs[loop.vertex_index]
    return me


def material(name, rgb, strength, trail, total, hot=(1.0, 0.95, 0.8), ember=(1.0, 0.25, 0.04), life=None, twinkle=0.0):
    """Trail: only rings younger than `trail` frames show; the head is hot white, the tail takes rgb, then ember.
    life: optional whole-spark fade: ring frame beyond birth is unknown here, so the fade uses the ring's own age only."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out = N("ShaderNodeOutputMaterial")
    tc, sep, now = N("ShaderNodeTexCoord"), N("ShaderNodeSeparateXYZ"), N("ShaderNodeValue")
    now.name = "Now"
    L(tc.outputs["UV"], sep.inputs[0])
    age = N("ShaderNodeMath")
    age.operation = "SUBTRACT"
    L(now.outputs[0], age.inputs[0])
    L(sep.outputs["X"], age.inputs[1])
    # age is smeared by each spark's random so the burst does not vanish as one sharp shell
    jit = N("ShaderNodeMath")
    jit.operation = "MULTIPLY"
    jit.inputs[1].default_value = (life or trail) * 0.6
    L(sep.outputs["Y"], jit.inputs[0])
    lifespan = N("ShaderNodeMath")
    lifespan.operation = "ADD"
    lifespan.inputs[1].default_value = trail * 0.4
    L(jit.outputs[0], lifespan.inputs[0])
    ramp = N("ShaderNodeMapRange")
    ramp.inputs["From Min"].default_value = 0.0
    ramp.inputs["To Min"].default_value, ramp.inputs["To Max"].default_value = 1.0, 0.0
    L(age.outputs[0], ramp.inputs["Value"])
    L(lifespan.outputs[0], ramp.inputs["From Max"])
    flown = N("ShaderNodeMath")
    flown.operation = "GREATER_THAN"
    flown.inputs[1].default_value = 0.0
    L(age.outputs[0], flown.inputs[0])
    fac = N("ShaderNodeMath")
    fac.operation = "MULTIPLY"
    L(ramp.outputs[0], fac.inputs[0])
    L(flown.outputs[0], fac.inputs[1])
    cr = N("ShaderNodeValToRGB")
    cr.color_ramp.elements[0].position, cr.color_ramp.elements[0].color = 0.05, (*ember, 1)
    cr.color_ramp.elements[1].position, cr.color_ramp.elements[1].color = 0.95, (*hot, 1)
    mid = cr.color_ramp.elements.new(0.5)
    mid.color = (*rgb, 1)
    L(fac.outputs[0], cr.inputs[0])
    em, tr, mix = N("ShaderNodeEmission"), N("ShaderNodeBsdfTransparent"), N("ShaderNodeMixShader")
    L(cr.outputs[0], em.inputs["Color"])
    em.inputs["Strength"].default_value = strength
    if twinkle:   # crackle: strands blink late in their life
        wave = N("ShaderNodeMath")
        wave.operation = "SINE"
        scale = N("ShaderNodeMath")
        scale.operation = "MULTIPLY"
        scale.inputs[1].default_value = twinkle
        L(age.outputs[0], scale.inputs[0])
        L(scale.outputs[0], wave.inputs[0])
        pos = N("ShaderNodeMapRange")
        pos.inputs["From Min"].default_value, pos.inputs["To Min"].default_value = -1.0, 0.25
        L(wave.outputs[0], pos.inputs["Value"])
        ms = N("ShaderNodeMath")
        ms.operation = "MULTIPLY"
        ms.inputs[1].default_value = strength
        L(pos.outputs["Result"], ms.inputs[0])
        L(ms.outputs[0], em.inputs["Strength"])
    L(fac.outputs[0], mix.inputs[0])
    L(tr.outputs[0], mix.inputs[1])
    L(em.outputs[0], mix.inputs[2])
    L(mix.outputs[0], out.inputs["Surface"])
    stage.key_socket(now.outputs[0], [(f, float(f)) for f in range(-total, 2 * total + 1, total)], interpolation="LINEAR")
    return m


def shell(sc, name, burst_f, burst_at, launch_from, rise, rgb, total, count=220, speed=7.0, seed=1, trail=11, life=26,
          radius=0.018, strength=9.0, twinkle=2.4):
    """Rising comet from launch_from, a burst flash, then count stars with trails and falling embers."""
    rnd = stage.seeded(seed)
    at = Vector(burst_at)
    tracks = []
    for _ in range(count):
        d = Vector((rnd.gauss(0, 1), rnd.gauss(0, 1), rnd.gauss(0, 1))).normalized()
        sp = speed * rnd.uniform(0.82, 1.0) if rnd.random() < 0.75 else speed * rnd.uniform(0.25, 0.8)
        n = min(total - burst_f + 1, rnd.randint(int(life * 0.7), int(life * 1.5)))
        if n > 4:
            # start 2 frames out: hundreds of tubes through one point exhaust transparent bounces and render a black dot
            tracks.append((burst_f + 2, simulate(at, d * sp, n, turbulence=1.6, rnd=rnd)[2:], rnd.random()))
    star = stage.link(sc, name, tube_mesh(name, tracks, radius),
                      material(f"{name}Mat", rgb, strength, trail, total, life=life, twinkle=twinkle), shadow=False)
    # rising comet: a thicker single trail that dies at the burst
    n = burst_f - rise + 1
    start = Vector(launch_from)
    pts = [start.lerp(at, 1 - (1 - i / (n - 1)) ** 2) for i in range(n)]
    comet = stage.link(sc, f"{name}Comet", tube_mesh(f"{name}Comet", [(rise, pts, 0.3)], radius * 1.6),
                       material(f"{name}CometMat", (1.0, 0.7, 0.35), strength, 8, total), shadow=False)
    flash(sc, name, burst_f, at, rgb, speed)
    return star, comet


def flash(sc, name, burst_f, at, rgb, speed):
    """Short hot core and a light that throws colour on anything nearby."""
    core = stage.link(sc, f"{name}Flash", stage.gc.ico_mesh(f"{name}Flash", 0.14, 2),
                      stage.emit(f"{name}FlashMat", (1.0, 0.92, 0.75), 60.0), loc=at, shadow=False)
    stage.key_path(core, (burst_f - 1, burst_f, burst_f + 2, burst_f + 5), lambda f: {
        burst_f - 1: (0.001,) * 3, burst_f: (1.0,) * 3, burst_f + 2: (1.6,) * 3, burst_f + 5: (0.001,) * 3}[f], path="scale")
    ld = bpy.data.lights.new(f"{name}Light", "POINT")
    ld.color, ld.shadow_soft_size = rgb, 1.0
    stage.link(sc, f"{name}Light", ld, loc=at)
    for f, e in ((burst_f - 1, 0.0), (burst_f, 2500.0 * speed / 7), (burst_f + 14, 0.0)):
        ld.energy = e
        ld.keyframe_insert("energy", frame=f)


__all__ = ["fx", "shell", "simulate"]
