"""UZARO v2 show: rocket (tier 2, 120 f = 5 s).

The rocket stands on the pad; ignition at the nozzle, Mantaflow smoke billows out along the ground, liftoff accelerates
it out of the top with shake, exhaust fire, heat haze and flying debris. Plume stays inside the safe width via a soft
domain border, so no hard box edge shows.
"""
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gas  # noqa: E402
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, env  # noqa: E402

ID = "rocket"
TOTAL = 120
SIZE = 7.0
GROUND_Z = -5.2
IGNITE, LIFTOFF, GONE = 14, 40, 108
RISE = 15.5                  # units above the pad when leaving the top of the frame


def hull_material():
    """White enamel; red nose and belly band by height; thin panel seams from a bump on height."""
    m = stage.pbr("Hull", (0.82, 0.82, 0.8), metallic=0.1, roughness=0.3, coat=0.5)
    nt = m.node_tree
    N, L = nt.nodes.new, nt.links.new
    tc, sep = N("ShaderNodeTexCoord"), N("ShaderNodeSeparateXYZ")
    L(tc.outputs["Object"], sep.inputs[0])
    ramp = N("ShaderNodeValToRGB")
    ramp.color_ramp.interpolation = "CONSTANT"
    els = ramp.color_ramp.elements
    els[0].position, els[0].color = 0.0, (0.82, 0.82, 0.8, 1)
    els[1].position, els[1].color = (2.1 + 3.5) / 7.0, (0.5, 0.012, 0.012, 1)
    els.new((-1.9 + 3.5) / 7.0).color = (0.5, 0.012, 0.012, 1)
    els.new((-1.45 + 3.5) / 7.0).color = (0.82, 0.82, 0.8, 1)
    remap = N("ShaderNodeMapRange")
    remap.inputs["From Min"].default_value, remap.inputs["From Max"].default_value = -3.5, 3.5
    L(sep.outputs["Z"], remap.inputs["Value"])
    L(remap.outputs["Result"], ramp.inputs["Fac"])
    L(ramp.outputs["Color"], stage.bsdf(m).inputs["Base Color"])
    wave = N("ShaderNodeTexWave")
    wave.wave_type, wave.bands_direction = "BANDS", "Z"
    wave.inputs["Scale"].default_value, wave.inputs["Distortion"].default_value = 0.42, 0.0
    L(tc.outputs["Object"], wave.inputs["Vector"])
    seam = N("ShaderNodeMapRange")
    seam.inputs["From Min"].default_value, seam.inputs["From Max"].default_value = 0.0, 0.03
    L(wave.outputs["Fac"], seam.inputs["Value"])
    bump = N("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.4
    L(seam.outputs["Result"], bump.inputs["Height"])
    L(bump.outputs[0], stage.bsdf(m).inputs["Normal"])
    return m


def fin_mesh(name):
    """Swept fin on +X, with thickness."""
    out = [(0.6, -2.0), (1.55, -3.1), (1.6, -3.55), (0.58, -2.85)]
    t = 0.05
    verts = [(x, -t, z) for x, z in out] + [(x, t, z) for x, z in out]
    faces = [(0, 1, 2, 3), (7, 6, 5, 4), (0, 4, 5, 1), (1, 5, 6, 2), (2, 6, 7, 3), (3, 7, 4, 0)]
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    return me


def load(sc):
    """A generic rocket from lathe profiles: no file model, no brand."""
    root = bpy.data.objects.new("RocketRoot", None)
    sc.collection.objects.link(root)
    hull_mat, red, steel, glass, brass = hull_material(), stage.pbr("Fin", (0.5, 0.012, 0.012), roughness=0.3, coat=0.5), stage.pbr("Steel", (0.3, 0.3, 0.32), metallic=1.0, roughness=0.35), stage.pbr("Port", (0.02, 0.1, 0.25), roughness=0.05, coat=1.0), stage.pbr("Brass", (0.8, 0.55, 0.22), metallic=1.0, roughness=0.3)
    body = stage.link(sc, "Hull", stage.lathe("Hull", [(0.0, -3.0), (0.56, -3.0), (0.64, -2.5), (0.74, -1.5), (0.78, -0.3), (0.74, 0.9), (0.62, 2.0), (0.4, 2.8), (0.17, 3.3), (0.0, 3.5)], 64), hull_mat, parent=root)
    nozzle = stage.link(sc, "Nozzle", stage.lathe("Nozzle", [(0.0, -3.0), (0.26, -3.0), (0.2, -3.1), (0.42, -3.5), (0.38, -3.5), (0.18, -3.12), (0.0, -3.1)], 40), steel, parent=root)
    parts = [body, nozzle]
    fin = fin_mesh("Fin")
    for i in range(4):
        ob = stage.link(sc, f"Fin{i}", fin, red, parent=root)
        ob.rotation_euler = (0, 0, math.radians(45 + 90 * i))
        parts.append(ob)
    fin.materials.clear()
    fin.materials.append(red)
    ring = stage.link(sc, "PortRing", stage.lathe("PortRing", [(0.17, -0.03), (0.26, -0.03), (0.26, 0.03), (0.17, 0.03), (0.17, -0.03)], 40), brass, parent=root, loc=(0.0, -0.76, 1.0))
    ring.rotation_euler = (math.radians(90), 0, 0)
    port = stage.link(sc, "Port", stage.lathe("Port", [(0.0, 0.0), (0.18, 0.0), (0.0, 0.05)], 32), glass, parent=root, loc=(0.0, -0.76, 1.0))
    port.rotation_euler = (math.radians(90), 0, 0)
    parts += [ring, port]
    return root, parts


def height(f):
    t = max(0.0, f - LIFTOFF) / (GONE - LIFTOFF)
    return RISE * t ** 2.2


def animate(root):
    for f in range(1, TOTAL + 1):
        rumble = env(f, IGNITE, LIFTOFF) * (1 - env(f, GONE - 20, GONE))
        root.location = (0.012 * rumble * math.sin(f * 2.7), 0.0, GROUND_Z + SIZE / 2 + 0.25 + height(f))
        root.keyframe_insert("location", frame=f)


def exhaust(sc, root, res=150):
    ramp = ((0.1, (0.9, 0.12, 0.01, 1.0)), (0.4, (1.0, 0.36, 0.02, 1.0)), (0.75, (1.0, 0.72, 0.18, 1.0)))
    mat = gas.material("RocketPlume", smoke_rgb=(0.85, 0.83, 0.8), density=9.0, ramp=ramp, edge_fade=(0.16, 0.0, 0.0), smoke_glow=0.1)
    dom = gas.domain(sc, ID, (0.0, 0.0, GROUND_Z + 7.0), (5.2, 4.0, 7.0), TOTAL, mat, res=res, vorticity=0.9, burn=0.8, flame_smoke=1.6, flame_vort=1.0,
                     dissolve=60, alpha=0.12, beta=0.5)
    dom.modifiers["Fluid"].domain_settings.use_collision_border_bottom = True
    src = gas.flow(sc, "Nozzle", 0.42, (0.0, 0.0, -SIZE / 2 + 0.1), velocity=(0.0, 0.0, -9.0), parent=root)
    gas.key_flow(src, ((IGNITE - 1, 0.0, 0.0), (IGNITE + 3, 2.0, 1.0), (GONE, 2.0, 1.0), (GONE + 2, 0.0, 0.0)))
    return dom


def core_flame(sc, root):
    """Solid white-hot exhaust core under the nozzle: the volume alone reads too soft."""
    me = stage.lathe("Core", [(0.0, 0.0), (0.26, -0.15), (0.2, -0.9), (0.08, -1.9), (0.0, -2.6)], segs=24)
    mat = stage.emit("Core", (1.0, 0.82, 0.5), 0.0)
    ob = stage.link(sc, "Core", me, mat, parent=root, loc=(0.0, 0.0, -SIZE / 2), shadow=False)
    sock = mat.node_tree.nodes["Emission"].inputs["Strength"]
    stage.key_socket(sock, [(IGNITE - 1, 0.0), (IGNITE + 4, 34.0), (GONE, 34.0), (GONE + 2, 0.0)])
    ob.scale = (1, 1, 0.01)
    ob.keyframe_insert("scale", frame=IGNITE - 1)
    for f in range(IGNITE + 3, GONE + 2, 2):
        ob.scale = (1.0 + 0.07 * math.sin(f * 1.9), 1.0 + 0.07 * math.sin(f * 1.9), 0.9 + 0.2 * math.sin(f * 2.7) + 0.5 * env(f, LIFTOFF, LIFTOFF + 30))
        ob.keyframe_insert("scale", frame=f)
    return ob


def flare_light(sc, root):
    ld = bpy.data.lights.new("Burn", "POINT")
    ld.color, ld.shadow_soft_size = (1.0, 0.62, 0.25), 1.2
    ob = bpy.data.objects.new("Burn", ld)
    sc.collection.objects.link(ob)
    ob.parent = root
    ob.location = (0.0, -1.0, -SIZE / 2 - 0.8)
    for f, e in ((IGNITE - 1, 0.0), (IGNITE + 4, 9000.0), (LIFTOFF, 7000.0), (GONE, 7000.0), (GONE + 3, 0.0)):
        ld.energy = e
        ld.keyframe_insert("energy", frame=f)


def debris(sc):
    mat = stage.pbr("Debris", (0.1, 0.09, 0.08), roughness=0.8)
    em = fx.particle_burst(sc, "Debris", fx.ring_mesh("DebrisR", 0.9, 0.1, 28), mat, 160, (IGNITE + 4, LIFTOFF + 18), 40, 0.05, 3.6, rand=1.6,
                           align=(0.0, 0.0, 2.2), gravity=0.55, location=(0.0, 0.0, GROUND_Z + 0.25))
    sparks = stage.emit("Sparks", (1.0, 0.55, 0.15), 18.0)
    fx.particle_burst(sc, "Sparks", fx.ring_mesh("SparksR", 0.7, 0.1, 28), sparks, 240, (IGNITE + 2, LIFTOFF + 30), 18, 0.022, 4.5, rand=1.2,
                      align=(0.0, 0.0, 1.4), gravity=0.35, location=(0.0, 0.0, GROUND_Z + 0.3))
    return em


def build_show(sc, opts):
    root, meshes = load(sc)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.9, follow=root, lights=0.8, fog=(1.9, 7), streak=7.0)
    gas.filmic(sc)
    sh.shadow_catcher(sc, GROUND_Z, 50)
    animate(root)
    flare_light(sc, root)
    core_flame(sc, root)
    debris(sc)
    dom = exhaust(sc, root, res=64 if opts["test"] else 150)   # a bake is the slow part of a test still
    sh.camera_shake(cam, IGNITE + 4, GONE - IGNITE, amp=0.07, rot_deg=0.35, seed=12)
    sh.screen_extent(sc, cam, meshes, (1, LIFTOFF, 80, GONE))
    gas.bake(sc, dom)
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Rocket mid-lift, centred: procedural fire lick (no sim) so the loop closes exactly."""
    root, meshes = load(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=0.9, follow=root, lights=0.8, fog=(1.9, 7), streak=7.0)
    gas.filmic(sc)
    root.rotation_euler = (0, R(-12), 0)
    me = stage.lathe("Core", [(0.0, 0.0), (0.34, -0.2), (0.3, -1.1), (0.12, -2.4), (0.0, -3.3)], segs=24)
    mat = stage.emit("Core", (1.0, 0.72, 0.35), 34.0)
    core = stage.link(sc, "Core", me, mat, parent=root, loc=(0.0, 0.0, -SIZE / 2), shadow=False)
    for f in range(0, stage.ICON_N + 1):
        w = 2 * math.pi * f / stage.ICON_N
        core.scale = (1.0 + 0.1 * math.sin(4 * w), 1.0 + 0.1 * math.sin(4 * w), 1.0 + 0.2 * math.sin(3 * w) + 0.1 * math.sin(7 * w))
        core.keyframe_insert("scale", frame=f)
        root.location = (0.02 * math.sin(5 * w), 0.0, 0.05 * math.sin(w))
        root.keyframe_insert("location", frame=f)
    sc.frame_set(1)
    stage.frame_icon(cam, meshes + [core], pad=1.1)
    sparks = stage.emit("Sparks", (1.0, 0.55, 0.15), 18.0)
    fx.particle_burst(sc, "Sparks", fx.ring_mesh("SparksR", 0.3, 0.1, 16), sparks, 90, (-30, stage.ICON_N), 16, 0.03, 3.0, rand=1.0,
                      align=(0.0, 0.0, -3.5), gravity=0.3, location=(0.0, 0.0, -SIZE / 2 - 0.2))
    stage.bake_all(sc)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
