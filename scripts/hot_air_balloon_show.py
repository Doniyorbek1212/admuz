"""UZARO v2 show: hot_air_balloon (tier 2, 120 f = 5 s).

The balloon climbs into frame in the dark of its own envelope; the burner flares and fire lights the fabric from inside
(a keyed glow gradient from the throat up, plus a real lamp); it rises through wisps of cloud, flares again and leaves
through the top. The file is unpainted, so envelope, net, swags and basket get materials by part.
"""
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import autorig  # noqa: E402
import clouds  # noqa: E402
import gas  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, interp  # noqa: E402

ID = "hot_air_balloon"
TOTAL = 120
SIZE = 6.0
K = 1.12
THROAT_Z = -0.98           # at SIZE, under the envelope
BURNER_Z = -1.28
ENVELOPE = ("Sphere.061", "Sphere.003")
BASKET = ("Plane.001",)
NET = ("Circle.008",)
SWAG = ("Plane.011", "Plane.018")
RED, GOLD, CREAM = (0.3, 0.006, 0.008), (0.6, 0.26, 0.02), (0.7, 0.6, 0.44)
GLOW = [(1, 0.05), (26, 0.05), (34, 1.5), (46, 1.2), (56, 0.25), (66, 0.25), (72, 1.7), (86, 1.3), (96, 0.3), (TOTAL, 0.3)]
PATH_Z = [(1, -11.5), (40, -1.1), (88, 0.7), (TOTAL, 12.0)]
BURN = ((28, 48), (68, 88))


def envelope_material():
    """Red and gold gores by angle; emission climbs from the throat by object height, with its strength keyed."""
    m = bpy.data.materials.new("Envelope")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out, b = N("ShaderNodeOutputMaterial"), N("ShaderNodeBsdfPrincipled")
    tc, sep = N("ShaderNodeTexCoord"), N("ShaderNodeSeparateXYZ")
    L(tc.outputs["Object"], sep.inputs[0])
    at = N("ShaderNodeMath")
    at.operation = "ARCTAN2"
    L(sep.outputs["Y"], at.inputs[0])
    L(sep.outputs["X"], at.inputs[1])
    stripes = N("ShaderNodeMath")
    stripes.operation, stripes.inputs[1].default_value = "MULTIPLY", 8.0
    L(at.outputs[0], stripes.inputs[0])
    sin = N("ShaderNodeMath")
    sin.operation = "SINE"
    L(stripes.outputs[0], sin.inputs[0])
    gt = N("ShaderNodeMath")
    gt.operation, gt.inputs[1].default_value = "GREATER_THAN", 0.55
    L(sin.outputs[0], gt.inputs[0])
    col = N("ShaderNodeMix")
    col.data_type = "RGBA"
    col.inputs["A"].default_value, col.inputs["B"].default_value = (*RED, 1), (*GOLD, 1)
    L(gt.outputs[0], col.inputs["Factor"])
    L(col.outputs["Result"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = 0.42
    b.inputs["Sheen Weight"].default_value = 0.5
    grad = N("ShaderNodeMapRange")
    grad.interpolation_type = "SMOOTHSTEP"
    grad.inputs["From Min"].default_value, grad.inputs["From Max"].default_value = 2.2, THROAT_Z
    grad.inputs["To Min"].default_value, grad.inputs["To Max"].default_value = 0.08, 1.0
    L(sep.outputs["Z"], grad.inputs["Value"])
    hot = N("ShaderNodeMix")
    hot.data_type = "RGBA"
    hot.inputs["B"].default_value = (1.0, 0.55, 0.14, 1.0)
    hot.inputs["Factor"].default_value = 0.3
    L(col.outputs["Result"], hot.inputs["A"])
    L(hot.outputs["Result"], b.inputs["Emission Color"])
    power = N("ShaderNodeMath")
    power.operation = "MULTIPLY"
    L(grad.outputs["Result"], power.inputs[0])
    stage.key_socket(power.inputs[1], [(f, float(v)) for f, v in GLOW])
    L(power.outputs[0], b.inputs["Emission Strength"])
    L(b.outputs[0], out.inputs["Surface"])
    return m


def wicker():
    m = stage.pbr("Wicker", (0.34, 0.2, 0.08), roughness=0.75)
    nt = m.node_tree
    wave = nt.nodes.new("ShaderNodeTexWave")
    wave.inputs["Scale"].default_value = 18.0
    wave.inputs["Distortion"].default_value = 1.5
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.6
    nt.links.new(wave.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs[0], stage.bsdf(m).inputs["Normal"])
    return m


def paint(meshes):
    env_m, cream, gold_m, wick, brass = envelope_material(), stage.pbr("Rope", CREAM, roughness=0.8), stage.pbr("Swag", (0.72, 0.36, 0.04), roughness=0.4, coat=0.3), wicker(), stage.pbr("Brass", (0.8, 0.52, 0.2), metallic=1.0, roughness=0.3)
    autorig.bake_world(meshes)
    for o in meshes:
        n = o.name
        o.data.materials.clear()
        zs = [v.co.z for v in o.data.vertices]
        z_top = max(zs) if zs else 0.0
        z_low = min(zs) if zs else 0.0
        if any(n.startswith(s) for s in ENVELOPE):
            mat = env_m
        elif any(n.startswith(s) for s in BASKET):
            mat = wick
        elif any(n.startswith(s) for s in SWAG):
            mat = gold_m
        elif z_low > 0.75 and z_top < 1.25:   # belt and tassels
            mat = gold_m
        elif z_top < -1.6:                    # basket, its trim and gear
            mat = wick
        elif z_low > -1.6 and z_top < -0.8:   # burner frame
            mat = brass
        else:
            mat = cream
        o.data.materials.append(mat)
        o.data.polygons.foreach_set("use_smooth", [True] * len(o.data.polygons))
    return env_m


def flame(sc, root):
    """Soft blue-to-orange tongues out of the burner, in two blasts."""
    for name, frames, count in (("Burn1", BURN[0], 520), ("Burn2", BURN[1], 620), ("Pilot", (1, TOTAL), 120)):
        for part, rgb, size, strength, n_mul in (("Core", (1.0, 0.72, 0.28), 0.17, 30.0, 1.0), ("Lick", (1.0, 0.24, 0.02), 0.24, 16.0, 0.8)):
            mat = fx.fade_material(f"{name}{part}", rgb, strength, 0.8, 1.0)
            em = fx.particle_burst(sc, f"{name}{part}", fx.ring_mesh(f"{name}{part}R", 0.05, 0.02, 12), mat, int(count * n_mul), frames, 8,
                                   size * (0.35 if name == "Pilot" else 1.0), 0.15, rand=0.25, align=(0, 0, 3.4 if name != "Pilot" else 1.2), gravity=0.0, location=(0, 0, BURNER_Z))
            em.parent = root


def lamp(sc, root):
    ld = bpy.data.lights.new("Inner", "POINT")
    ld.color, ld.shadow_soft_size = (1.0, 0.55, 0.2), 0.5
    stage.link(sc, "Inner", ld, parent=root, loc=(0, 0, 0.2))
    for f, v in GLOW:
        ld.energy = 14.0 * v
        ld.keyframe_insert("energy", frame=f)
    low = bpy.data.lights.new("BurnerGlow", "POINT")
    low.color, low.shadow_soft_size = (1.0, 0.5, 0.15), 0.2
    stage.link(sc, "BurnerGlow", low, parent=root, loc=(0, -0.3, BURNER_Z + 0.1))
    for f, v in GLOW:
        low.energy = 22.0 * max(0.0, v - 0.25)
        low.keyframe_insert("energy", frame=f)


def wisps(sc):
    """Clouds pass downward: the balloon climbs through them, nearer ones faster."""
    rnd = stage.seeded(5)
    specs = (((-2.3, 3.5, 5.0), (2.4, 1.3, 1.1), 8.0), ((2.6, -3.5, 1.6), (2.2, 1.2, 0.8), 15.0), ((-1.8, -5.0, -2.5), (1.9, 1.1, 0.7), 17.0), ((2.0, 4.0, -4.0), (2.6, 1.4, 1.1), 8.0))
    for i, (loc, half, travel) in enumerate(specs):
        mat = clouds.material(f"Wisp{i}", density=3.2, scale=2.2, threshold=0.47, glow=((1.0, 0.97, 0.93), 0.18), drift=[(1, (rnd.random(), rnd.random(), 0.0)), (TOTAL, (rnd.random() + 0.3, rnd.random(), 0.25))])
        clouds.cloud(sc, f"Wisp{i}", loc, half, mat, keys=[(1, (loc[0], loc[1], loc[2] + travel * 0.5)), (TOTAL, (loc[0], loc[1], loc[2] - travel * 0.5))])
    for fc in (ob.animation_data.action.fcurves for ob in sc.objects if ob.name.startswith("Wisp")):
        for c in fc:
            for kp in c.keyframe_points:
                kp.interpolation = "LINEAR"


def build_show(sc, opts):
    root, model, objs, meshes = stage.load(ID, SIZE)
    paint(meshes)
    for o in meshes:
        o.parent = root
    root.scale = (K, K, K)
    root.rotation_mode = "XYZ"
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.75, follow=root, lights=0.75, fog=(1.9, 6), streak=9.0)
    gas.filmic(sc)
    frames = range(1, TOTAL + 1)
    stage.key_path(root, frames, lambda f: (0.3 * math.sin(f / 40.0), 0.0, interp(PATH_Z, f)))
    stage.key_path(root, frames, lambda f: (R(1.5 * math.sin(f / 23.0)), R(2.0 * math.sin(f / 31.0)), R(f * 0.25)), path="rotation_euler")
    flame(sc, root)
    lamp(sc, root)
    wisps(sc)
    sh.screen_extent(sc, cam, meshes[:40], (1, 40, 88, TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Hanging at centre, one burner pulse per loop, a slow sway."""
    root, model, objs, meshes = stage.load(ID, SIZE)
    env_m = paint(meshes)
    for o in meshes:
        o.parent = root
    cam = stage.setup_icon(sc, opts["samples"], world=0.75, follow=root, lights=0.75, fog=(1.9, 6), streak=9.0)
    gas.filmic(sc)
    n = stage.ICON_N
    power = next(nd for nd in env_m.node_tree.nodes if nd.type == "MATH" and nd.operation == "MULTIPLY" and not nd.inputs[1].is_linked and nd.inputs[1].default_value != 8.0)
    env_m.node_tree.animation_data_clear()
    keys = [(f, 0.25 + 1.3 * max(0.0, math.sin(2 * math.pi * f / n)) ** 2) for f in range(0, n + 1)]
    stage.key_socket(power.inputs[1], keys)
    root.rotation_mode = "XYZ"
    for f in range(0, n + 1):
        w = 2 * math.pi * f / n
        root.rotation_euler = (R(1.5 * math.sin(w)), R(2.0 * math.cos(w)), 0.0)
        root.location = (0, 0, 0.06 * math.sin(w))
        root.keyframe_insert("rotation_euler", frame=f)
        root.keyframe_insert("location", frame=f)
    for i in range(2):
        mat = fx.fade_material(f"Icon{i}", (1.0, 0.45 + 0.3 * i, 0.08), 26.0, 0.8, 1.0)
        em = fx.particle_burst(sc, f"Icon{i}", fx.ring_mesh(f"IconR{i}", 0.05, 0.02, 12), mat, 300, (-20, n), 8, 0.1, 0.1, rand=0.25, align=(0, 0, 3.0), location=(0, 0, BURNER_Z))
        em.parent = root
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.08)
    stage.bake_all(sc)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
