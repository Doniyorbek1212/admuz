"""UZARO v2 show: universe (tier 4, 168 f = 7 s).

A point of light opens into a swirling nebula; Earth and two more worlds orbit the star at its heart; a ringed giant
sails past close to the lens; the star collapses and goes supernova, the flash clears everything, and fading stars
are all that remain. Everything sits inside a disc well short of the frame corners: corner alpha stays 0.
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gas  # noqa: E402
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, env, interp  # noqa: E402

ID = "universe"
MODEL = "earth"
TOTAL = 168
OPEN = (1, 44)
NOVA = 124
PASS = (62, 118)
STARS_R = 6.3


def nebula_material(name, a, b, density, strength, scale, seed, static=False):
    """Two-colour noise cloud: glow and a little density, so it holds alpha; falls off to nothing inside the cube."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out, vol, tc = N("ShaderNodeOutputMaterial"), N("ShaderNodeVolumePrincipled"), N("ShaderNodeTexCoord")
    n1, n2, n3 = N("ShaderNodeTexNoise"), N("ShaderNodeTexNoise"), N("ShaderNodeValToRGB")
    for n, s in ((n1, scale), (n2, scale * 0.6)):
        n.inputs["Scale"].default_value, n.inputs["Detail"].default_value, n.inputs["Roughness"].default_value = s, 8.0, 0.6
        n.noise_dimensions = "4D"
        n.inputs["W"].default_value = seed
        L(tc.outputs["Object"], n.inputs["Vector"])
    ln = N("ShaderNodeVectorMath")
    ln.operation = "LENGTH"
    L(tc.outputs["Object"], ln.inputs[0])
    fall = N("ShaderNodeMapRange")
    fall.interpolation_type = "SMOOTHSTEP"
    fall.inputs["From Min"].default_value, fall.inputs["From Max"].default_value = 0.1, 0.95
    fall.inputs["To Min"].default_value, fall.inputs["To Max"].default_value = 1.0, 0.0
    L(ln.outputs["Value"], fall.inputs["Value"])
    cut = N("ShaderNodeMapRange")
    cut.inputs["From Min"].default_value, cut.inputs["From Max"].default_value = 0.42, 0.72
    cut.clamp = True
    L(n1.outputs["Fac"], cut.inputs["Value"])
    mask = N("ShaderNodeMath")
    mask.operation = "MULTIPLY"
    L(cut.outputs[0], mask.inputs[0])
    L(fall.outputs["Result"], mask.inputs[1])
    els = n3.color_ramp.elements
    els[0].position, els[0].color = 0.35, (*a, 1)
    els[1].position, els[1].color = 0.68, (*b, 1)
    L(n2.outputs["Fac"], n3.inputs["Fac"])
    vol.inputs["Color"].default_value = (0.0, 0.0, 0.0, 1.0)
    L(n3.outputs["Color"], vol.inputs["Emission Color"])
    fade = N("ShaderNodeValue")
    fade.name = "Fade"
    fade.outputs[0].default_value = 1.0
    if not static:
        stage.key_socket(fade.outputs[0], [(1, 0.0), (OPEN[1], 1.0), (NOVA - 2, 1.0), (NOVA + 6, 0.0)])
    d, e = N("ShaderNodeMath"), N("ShaderNodeMath")
    d.operation = e.operation = "MULTIPLY"
    L(mask.outputs[0], d.inputs[0])
    L(fade.outputs[0], d.inputs[1])
    dg, eg = N("ShaderNodeMath"), N("ShaderNodeMath")
    dg.operation = eg.operation = "MULTIPLY"
    dg.inputs[1].default_value, eg.inputs[1].default_value = density, strength
    L(d.outputs[0], dg.inputs[0])
    L(d.outputs[0], eg.inputs[0])
    L(dg.outputs[0], vol.inputs["Density"])
    L(eg.outputs[0], vol.inputs["Emission Strength"])
    _ = e
    L(vol.outputs[0], out.inputs["Volume"])
    return m


def nebula(sc, spin=True):
    """Layers turn at different speeds and open from a point: inner fast, outer slow, which reads as a swirl."""
    out = []
    for name, a, b, dens, stren, scale, half, turn in (("Outer", (0.02, 0.05, 0.8), (0.5, 0.02, 0.55), 0.5, 0.9, 2.6, 6.0, 55.0), ("Inner", (0.8, 0.03, 0.25), (1.0, 0.4, 0.05), 0.6, 1.1, 3.4, 3.8, 130.0)):
        bpy.ops.mesh.primitive_cube_add(size=2.0, location=(0, 0, 0))
        ob = bpy.context.active_object
        ob.name = name
        ob.data.materials.append(nebula_material(name, a, b, dens, stren, scale, len(out) * 3.3, static=not spin))
        ob.cycles.use_motion_blur = False
        ob.rotation_mode = "XYZ"
        if spin:
            stage.key_path(ob, range(1, TOTAL + 1, 4), lambda f, h=half: (h * max(0.02, env(f, *OPEN)),) * 3, path="scale")
            stage.key_path(ob, range(1, TOTAL + 1, 4), lambda f, t=turn: (R(68), R(-t * (1 - 0.0) * f / TOTAL - 120 * (1 - env(f, *OPEN))), 0.0), path="rotation_euler")
        else:
            ob.scale = (half * 0.6, half * 0.6, half * 0.6)    # the icon frame is 3.6 wide: stay inside it
        out.append((ob, turn))
    return out


def star_field(sc, seed=2):
    """One mesh of many tiny diamonds in a disc: small, cheap, no particles to bake."""
    rnd = stage.seeded(seed)
    verts, faces, heat = [], [], []
    for i in range(620):
        a = rnd.uniform(0, 2 * math.pi)
        r = STARS_R * math.sqrt(rnd.random())
        c = Vector((r * math.cos(a), rnd.uniform(0.0, 4.0), r * math.sin(a)))
        s = rnd.uniform(0.008, 0.02) * (2.4 if rnd.random() < 0.04 else 1.0)
        b = len(verts)
        for p in ((s, 0, 0), (-s, 0, 0), (0, s, 0), (0, -s, 0), (0, 0, s), (0, 0, -s)):
            verts.append(c + Vector(p))
        faces += [(b, b + 2, b + 4), (b + 2, b + 1, b + 4), (b + 1, b + 3, b + 4), (b + 3, b, b + 4), (b + 2, b, b + 5), (b + 1, b + 2, b + 5), (b + 3, b + 1, b + 5), (b, b + 3, b + 5)]
        heat += [rnd.random()] * 6
    me = bpy.data.meshes.new("Stars")
    me.from_pydata(verts, [], faces)
    attr = me.attributes.new("heat", "FLOAT", "POINT")
    attr.data.foreach_set("value", heat)
    m = bpy.data.materials.new("Stars")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    a_n, ramp, em, out = N("ShaderNodeAttribute"), N("ShaderNodeValToRGB"), N("ShaderNodeEmission"), N("ShaderNodeOutputMaterial")
    a_n.attribute_name = "heat"
    els = ramp.color_ramp.elements
    els[0].color, els[1].color = (0.65, 0.78, 1.0, 1), (1.0, 0.86, 0.68, 1)
    L(a_n.outputs["Fac"], ramp.inputs["Fac"])
    L(ramp.outputs["Color"], em.inputs["Color"])
    L(em.outputs[0], out.inputs["Surface"])
    ob = stage.link(sc, "Stars", me, m, shadow=False)
    return ob, em


def planet_material(name, a, b, bands=0.0, scale=4.0):
    m = stage.pbr(name, a, roughness=0.55)
    nt = m.node_tree
    tc, map_, noise, ramp = nt.nodes.new("ShaderNodeTexCoord"), nt.nodes.new("ShaderNodeMapping"), nt.nodes.new("ShaderNodeTexNoise"), nt.nodes.new("ShaderNodeValToRGB")
    map_.inputs["Scale"].default_value = (1.0, 1.0, 1.0 + bands)
    noise.inputs["Scale"].default_value, noise.inputs["Detail"].default_value = scale, 8.0
    nt.links.new(tc.outputs["Object"], map_.inputs["Vector"])
    nt.links.new(map_.outputs[0], noise.inputs["Vector"])
    els = ramp.color_ramp.elements
    els[0].position, els[0].color = 0.36, (*a, 1)
    els[1].position, els[1].color = 0.66, (*b, 1)
    nt.links.new(noise.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], stage.bsdf(m).inputs["Base Color"])
    return m


def sphere(sc, name, r, mat):
    me = gc.ico_mesh(name, r, 5)
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    return stage.link(sc, name, me, mat)


def ring_material():
    """Banded translucent ring: radial stripes from object-space radius."""
    m = bpy.data.materials.new("Rings")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out, tc, ln, wave, ramp, b, tr, mix = N("ShaderNodeOutputMaterial"), N("ShaderNodeTexCoord"), N("ShaderNodeVectorMath"), N("ShaderNodeTexNoise"), N("ShaderNodeValToRGB"), N("ShaderNodeBsdfPrincipled"), N("ShaderNodeBsdfTransparent"), N("ShaderNodeMixShader")
    ln.operation = "LENGTH"
    L(tc.outputs["Object"], ln.inputs[0])
    wave.noise_dimensions = "1D"
    wave.inputs["Scale"].default_value, wave.inputs["Detail"].default_value = 9.0, 6.0
    L(ln.outputs["Value"], wave.inputs["W"])
    els = ramp.color_ramp.elements
    els[0].position, els[0].color = 0.38, (0, 0, 0, 1)
    els[1].position, els[1].color = 0.6, (1, 1, 1, 1)
    L(wave.outputs["Fac"], ramp.inputs["Fac"])
    b.inputs["Base Color"].default_value = (0.86, 0.72, 0.52, 1)
    b.inputs["Roughness"].default_value = 0.7
    L(ramp.outputs["Color"], mix.inputs[0])
    L(tr.outputs[0], mix.inputs[1])
    L(b.outputs[0], mix.inputs[2])
    L(mix.outputs[0], out.inputs["Surface"])
    return m


def ringed(sc, r=1.45):
    ball = sphere(sc, "Ringed", r, planet_material("Giant", (0.72, 0.5, 0.26), (0.95, 0.82, 0.56), bands=9.0, scale=2.2))
    verts, faces, n = [], [], 128
    for i in range(n):
        a = 2 * math.pi * i / n
        for q in (1.35, 2.25):
            verts.append((q * r * math.cos(a), q * r * math.sin(a), 0.0))
    faces = [(2 * i, 2 * ((i + 1) % n), 2 * ((i + 1) % n) + 1, 2 * i + 1) for i in range(n)]
    me = bpy.data.meshes.new("RingsM")
    me.from_pydata(verts, [], faces)
    stage.link(sc, "RingsM", me, ring_material(), parent=ball)
    ball.rotation_mode = "XYZ"
    return ball


def soften_edge(mat, power=16.0):
    """Emission fades to transparent toward the silhouette: at nova scale a plain sphere rendered as a flat white disc."""
    nt = mat.node_tree
    emission = nt.nodes["Emission"]
    out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL")
    weight = nt.nodes.new("ShaderNodeLayerWeight")
    centre = nt.nodes.new("ShaderNodeMath")
    centre.operation, centre.inputs[0].default_value = "SUBTRACT", 1.0
    nt.links.new(weight.outputs["Facing"], centre.inputs[1])
    falloff = nt.nodes.new("ShaderNodeMath")
    falloff.operation, falloff.inputs[1].default_value = "POWER", power
    nt.links.new(centre.outputs[0], falloff.inputs[0])
    mix = nt.nodes.new("ShaderNodeMixShader")
    nt.links.new(falloff.outputs[0], mix.inputs[0])
    nt.links.new(nt.nodes.new("ShaderNodeBsdfTransparent").outputs[0], mix.inputs[1])
    nt.links.new(emission.outputs[0], mix.inputs[2])
    nt.links.new(mix.outputs[0], out.inputs["Surface"])


def core_star(sc):
    """The heart of the nebula: grows, then snaps inward just before it blows."""
    mat = stage.emit("Core", (1.0, 0.93, 0.8), 60.0)
    soften_edge(mat)
    core = stage.link(sc, "Core", gc.ico_mesh("Core", 0.18, 3), mat, shadow=False)
    stage.key_path(core, range(1, TOTAL + 1), lambda f: (interp([(1, 0.2), (OPEN[1], 1.5), (NOVA - 8, 2.2), (NOVA - 2, 0.3), (NOVA, 2.0), (NOVA + 7, 6.0), (NOVA + 20, 0.001), (TOTAL, 0.001)], f),) * 3, path="scale")
    stage.key_socket(mat.node_tree.nodes["Emission"].inputs["Strength"], [(1, 60.0), (NOVA - 2, 60.0), (NOVA + 2, 140.0), (NOVA + 7, 40.0), (NOVA + 20, 0.0)])
    ld = bpy.data.lights.new("CoreLight", "POINT")
    ld.color, ld.shadow_soft_size = (1.0, 0.88, 0.75), 0.3
    stage.link(sc, "CoreL", ld)
    for f, e in ((1, 60.0), (OPEN[1], 900.0), (NOVA - 2, 900.0), (NOVA + 2, 26000.0), (NOVA + 18, 0.0)):
        ld.energy = e
        ld.keyframe_insert("energy", frame=f)


def supernova(sc):
    """Blast shell and sparks. Sparks stop inside the corner-safe disc thanks to their drag."""
    for name, rgb, n in (("NovaA", (1.0, 0.85, 0.6), 900), ("NovaB", (0.55, 0.72, 1.0), 700), ("NovaC", (1.0, 0.35, 0.3), 400)):
        fx.particle_burst(sc, name, gc.ico_mesh(f"{name}E", 0.3, 2), fx.fade_material(name, rgb, 9.0, 1.0, 1.0), n // 2, (NOVA, NOVA + 4), 26, 0.016, 6.0, rand=1.3, damping=0.1, gravity=0.0)


def worlds(sc):
    """Earth from the file and a red and a blue world, on tilted orbits round the core."""
    root, model, objs, earth_meshes = stage.load(MODEL, 1.4)
    root.rotation_mode = "XYZ"
    mars = sphere(sc, "Mars", 0.42, planet_material("Mars", (0.5, 0.13, 0.04), (0.85, 0.42, 0.18), scale=6.0))
    ice = sphere(sc, "Ice", 0.55, planet_material("Ice", (0.05, 0.25, 0.65), (0.6, 0.85, 0.95), bands=3.0, scale=4.0))
    tilt = Matrix.Rotation(R(68), 3, "X") @ Matrix.Rotation(R(14), 3, "Y")
    for ob, radius, speed, phase in ((root, 2.8, 1.3, 0.3), (mars, 1.8, 2.2, 2.4), (ice, 3.6, 0.9, 4.2)):
        ob.rotation_mode = "XYZ"
        for f in range(1, NOVA + 8):
            a = phase + speed * f / 24.0
            # swallowed by the star before the flash: lit by the nova they blew out into white slabs
            grow = env(f, 14, 46) * (1 - env(f, NOVA - 5, NOVA))
            p = tilt @ Vector((radius * grow * math.cos(a), radius * grow * math.sin(a), 0.0))
            ob.location = p
            ob.scale = (max(0.001, grow),) * 3
            ob.rotation_euler = (R(15), 0, R(f * 2.0))
            ob.keyframe_insert("location", frame=f)
            ob.keyframe_insert("scale", frame=f)
            ob.keyframe_insert("rotation_euler", frame=f)
    return earth_meshes + [mars, ice]


def fly_by(sc):
    giant = ringed(sc)
    for f in range(PASS[0] - 2, PASS[1] + 3, 2):
        t = (f - PASS[0]) / (PASS[1] - PASS[0])
        giant.location = (6.4 - 12.8 * t, -7.5, -3.0 + 4.4 * t)
        giant.rotation_euler = (R(14), R(18), R(f * 0.8))
        giant.keyframe_insert("location", frame=f)
        giant.keyframe_insert("rotation_euler", frame=f)
    giant.location = (6.4 * 3, -7.5, -3.0)
    giant.keyframe_insert("location", frame=PASS[0] - 3)
    giant.location = (-6.4 * 3, -7.5, 1.4)
    giant.keyframe_insert("location", frame=PASS[1] + 3)
    return giant


def build_show(sc, opts):
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.0, lights=0.0, fog=(1.8, 7), streak=9.0)
    gas.filmic(sc)
    sc.cycles.volume_step_rate = 2.0
    nebula(sc)
    stars, em = star_field(sc)
    stage.key_socket(em.inputs["Strength"], [(1, 0.0), (20, 3.5), (NOVA, 3.5), (NOVA + 10, 7.0), (146, 4.0), (TOTAL - 2, 0.0)])
    core_star(sc)
    moving = worlds(sc)
    fly_by(sc)
    supernova(sc)
    fill = bpy.data.lights.new("Fill", "SUN")     # the core alone leaves the near side of the giant black
    fill.color = (1.0, 0.92, 0.82)
    sun = stage.link(sc, "Fill", fill)
    sun.rotation_euler = (R(90), 0, R(-62))
    for f, e in ((1, 4.0), (NOVA, 4.0), (NOVA + 4, 0.0)):
        fill.energy = e
        fill.keyframe_insert("energy", frame=f)
    sh.camera_shake(cam, NOVA, 16, amp=0.08, rot_deg=0.5, seed=3)
    sh.screen_extent(sc, cam, moving, (60, 110))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Ringed planet turning in a turning nebula: whole turns only, so the seam is exact."""
    cam = stage.setup_icon(sc, opts["samples"], world=0.0, lights=0.0, fog=(1.6, 7), streak=2.6)
    gas.filmic(sc)
    n = stage.ICON_N
    layers = nebula(sc, spin=False)
    for ob, _turn in layers:
        for f in range(0, n + 1):
            ob.rotation_euler = (R(68), R(-360.0 * f / n), 0.0)
            ob.keyframe_insert("rotation_euler", frame=f)
    giant = ringed(sc, r=1.3)
    for f in range(0, n + 1):
        giant.rotation_euler = (R(14), R(18), R(360.0 * f / n))
        giant.keyframe_insert("rotation_euler", frame=f)
    ld = bpy.data.lights.new("Sun", "POINT")
    ld.energy, ld.color = 2600.0, (1.0, 0.9, 0.8)
    stage.link(sc, "SunL", ld, loc=(-5.0, -6.0, 3.0))
    cam.location, cam.rotation_euler = (0.0, -gc.CAM_DIST, 0.0), (R(90), 0, 0)
    cam.data.lens = gc.CAM_DIST * 18.0 / 3.6


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
