"""The 20 original UZARO avatar frame designs, built from frame_common blocks (rendered by frames.py).

No brand marks or emblems of states: the plate icons are the UZARO monogram, star, heart, leaf, flame, bolt,
shield, crown, snowflake or a cut gem.
"""
import math
import random

import bpy

import frame_common as fc
import stage as st

R, TAU, BAND = fc.R, fc.TAU, fc.BAND_R
DARK = (0.02, 0.025, 0.035)
GOLD_TEXT = (1.0, 0.78, 0.38)


# ---------------------------------------------------------------- shared pieces
def gold_band(sc, width=0.09, depth=0.08, rims=True, mat=None):
    mat = mat or fc.metal("Gold", fc.GOLD)
    obs = [fc.put(sc, "Band", fc.band("Band", BAND, width, depth), mat)]
    if rims:
        obs.append(fc.put(sc, "RimIn", fc.tube("RimIn", BAND - width / 2 - 0.012, 0.011), mat, (0, -0.01, 0)))
        obs.append(fc.put(sc, "RimOut", fc.tube("RimOut", BAND + width / 2 + 0.012, 0.011), mat, (0, -0.01, 0)))
    return obs


def rims(sc, mat, half, thick=0.013):
    fc.put(sc, "RimIn", fc.tube("RimIn", BAND - half, thick), mat)
    fc.put(sc, "RimOut", fc.tube("RimOut", BAND + half, thick), mat)


def crown(sc, gold, gem, loc, size=0.4, tilt=0.0):
    gold = fc.metal("CrownGold", (1.0, 0.76, 0.32), 0.3, 0.6)   # rougher than the band: catches light from any side
    ob = fc.bevel(fc.put(sc, "Crown", fc.slab("Crown", fc.crown_outline(1.0, 0.62), 0.12), gold, loc, (0, R(tilt), 0), size),
                  0.02, 3)
    for i, x in enumerate((-0.52, -0.18, 0.18, 0.52)):
        z = 0.62 if abs(x) > 0.4 else 0.82
        fc.put(sc, f"CrownBall{i}", fc.sphere("Ball", 0.06, 2), gold, (x * 0.98, 0, z * 0.62 / 0.82 + 0.03), parent=ob)
    fc.put(sc, "CrownGem", fc.gem_round("CrownGem", 0.09), gem, (0, -0.08, 0.18), parent=ob)
    return ob


def glint_mat():
    return st.emit("Glint", (1.0, 0.95, 0.85), 8.0)


def stars_under(sc, mat, z=-0.935, gap=0.09, size=0.035):
    me = fc.faceted_star("SmallStar", 5, 1.0, 0.45, 0.35)
    return [fc.put(sc, f"UnderStar{i}", me, mat, (x, -0.25, z), scale=size) for i, x in enumerate((-gap, 0.0, gap))]


def hud(sc, rgb, strength=4.0):
    """Tech ring: segmented arcs on three tracks turning at different speeds (each by its own symmetry per loop)."""
    lit = fc.neon("HudLit", rgb, strength, cycles=2)
    sc.view_settings.look = "AgX - Punchy"
    dim = st.emit("HudDim", rgb, strength * 0.3)
    fc.put(sc, "HudBase", fc.band("HudBase", BAND, 0.10, 0.04), fc.enamel("HudBase", DARK, 0.3), (0, 0.03, 0))
    tracks = ((BAND - 0.035, 0.018, 6, 40, 1 / 6, lit), (BAND + 0.02, 0.03, 4, 62, -1 / 4, dim),
              (BAND + 0.075, 0.012, 12, 18, 1 / 12, lit))
    for k, (r, w, count, span, turns, mat) in enumerate(tracks):
        pivot = bpy.data.objects.new(f"HudPivot{k}", None)
        sc.collection.objects.link(pivot)
        for i in range(count):
            a0 = TAU * i / count
            fc.put(sc, f"Hud{k}_{i}", fc.band(f"Hud{k}", r, w, 0.03, a0, a0 + R(span), 96), mat, (0, -0.02, 0), parent=pivot)
        fc.spin(pivot, turns)
    ticks = fc.slab("Tick", [(-0.006, 0.0), (0.006, 0.0), (0.006, 0.05), (-0.006, 0.05)], 0.02)
    fc.ring_of(sc, "Tick", ticks, dim, 48, BAND + 0.105, -0.02, face_out=True)


def neon_ring(sc, rgb, tint, strength=3.5):
    """Glowing tube with a bright head running round once per loop, on a dark channel so the colour stays deep."""
    fc.put(sc, "Neon", fc.tube("Neon", BAND, 0.026), fc.comet("Neon", rgb, strength, 0.55, 1, 0.35, tint))
    fc.put(sc, "Channel", fc.band("Channel", BAND, 0.1, 0.04), fc.enamel("Channel", DARK, 0.3), (0, 0.035, 0))
    fc.put(sc, "Halo", fc.tube("Halo", BAND + 0.045, 0.007), fc.neon("Halo", tint, 1.2, 2))
    fc.put(sc, "HaloIn", fc.tube("HaloIn", BAND - 0.045, 0.006), fc.neon("HaloIn", rgb, 1.0, 2, offset=0.5))
    sc.view_settings.look = "AgX - Punchy"            # keeps the neon colour saturated instead of washing to white


def stripes(name, dark, gold):
    """Diagonal black and gold stripes: a wave texture picks between glossy black and gold metal."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N_, L = nt.nodes.new, nt.links.new
    tc = N_("ShaderNodeTexCoord")
    wave = N_("ShaderNodeTexWave")
    wave.bands_direction, wave.wave_profile = "DIAGONAL", "SAW"
    wave.inputs["Scale"].default_value = 3.0
    L(tc.outputs["Object"], wave.inputs["Vector"])
    step = N_("ShaderNodeMath")
    step.operation = "GREATER_THAN"
    L(wave.outputs["Fac"], step.inputs[0])
    step.inputs[1].default_value = 0.55
    a = N_("ShaderNodeBsdfPrincipled")
    a.inputs["Base Color"].default_value = (*dark, 1)
    a.inputs["Roughness"].default_value = 0.12
    a.inputs["Coat Weight"].default_value = 1.0
    b = N_("ShaderNodeBsdfPrincipled")
    b.inputs["Base Color"].default_value = (*gold, 1)
    b.inputs["Metallic"].default_value = 1.0
    b.inputs["Roughness"].default_value = 0.35
    b.inputs["Emission Color"].default_value = (*gold, 1)
    b.inputs["Emission Strength"].default_value = 0.25
    mix = N_("ShaderNodeMixShader")
    L(step.outputs[0], mix.inputs[0])
    L(a.outputs[0], mix.inputs[1])
    L(b.outputs[0], mix.inputs[2])
    L(mix.outputs[0], N_("ShaderNodeOutputMaterial").inputs["Surface"])
    return m


def flower(sc, name, petal, pink, center, loc, size, rot=0.0):
    pivot = bpy.data.objects.new(name, None)
    sc.collection.objects.link(pivot)
    pivot.location, pivot.rotation_euler, pivot.scale = loc, (0, R(rot), 0), (size, size, size)
    for i in range(5):
        deg = 90 + 72 * i
        fc.put(sc, f"{name}P{i}", petal, pink, fc.polar(0.08, deg), (R(8), -R(deg), 0), 1.0, pivot)
    for i in range(6):
        fc.put(sc, f"{name}C{i}", fc.sphere("Stamen", 0.045, 1), center, fc.polar(0.1 if i else 0.0, 60 * i, -0.05), parent=pivot)
    return pivot


def gem_cluster(sc, name, gem_me, mat, loc, sizes, seed=0):
    rnd = random.Random(seed)
    for i, s in enumerate(sizes):
        off = (rnd.uniform(-1, 1) * s * 1.4, rnd.uniform(-0.05, 0.0), rnd.uniform(-1, 1) * s * 1.4) if i else (0, 0, 0)
        fc.put(sc, f"{name}{i}", gem_me, mat, (loc[0] + off[0], loc[1] + off[1], loc[2] + off[2]),
               (R(rnd.uniform(-25, 25)), R(rnd.uniform(-40, 40)), R(rnd.uniform(-30, 30))), s)


def crystal_mesh(name):
    """Hexagonal quartz point, base at -1, tip at +1 along Z."""
    return st.lathe(name, [(0.0, -1.0), (0.22, -0.7), (0.25, 0.45), (0.0, 1.0)], segs=6, smooth_shade=False)


def off_plate(deg):
    """True where the label plate sits (the bottom of the ring): decorations keep clear of it."""
    d = (deg + 180) % 360 - 180
    return -115 < d < -65


# ---------------------------------------------------------------- the 20 designs
def gold_laurel(sc):
    gold, ink = fc.metal("Gold", fc.GOLD), fc.enamel("Ink", DARK)
    leaf_gold = fc.metal("LeafGold", (1.0, 0.76, 0.32), 0.3, 0.6)
    gold_band(sc)
    for side in (-1, 1):
        fc.laurel(sc, leaf_gold, side, a_from=-62, a_to=52, count=10, size=0.22)
    crown(sc, gold, fc.gem("Ruby", (1.0, 0.05, 0.1)), (0, -0.1, 0.72), 0.48)
    fc.twinkles(sc, glint_mat(), 7, 0.8, 0.98, 0.05, seed=11)
    return fc.plate(sc, "pill", ink, fc.label(GOLD_TEXT), gold) + stars_under(sc, gold)


def teal_neon(sc):
    neon_ring(sc, (0.0, 0.9, 0.55), (0.0, 0.5, 0.9))
    fc.twinkles(sc, st.emit("Spark", (0.5, 1.0, 0.85), 10.0), 6, 0.84, 0.96, 0.045, seed=2)
    return fc.plate(sc, "pill", fc.enamel("Tag", (0.01, 0.1, 0.06)), fc.label((0.85, 1.0, 0.94)),
                    st.emit("TagRim", (0.0, 0.85, 0.5), 2.5), "u")


def blue_crystal(sc):
    ice = fc.gem("Crystal", (0.35, 0.6, 1.0), 0.25, 1.6)
    fc.put(sc, "Band", fc.band("Band", BAND, 0.07, 0.06), fc.metal("Steel", (0.6, 0.75, 1.0), 0.2))
    fc.put(sc, "Core", fc.tube("Core", BAND, 0.018), fc.neon("Core", (0.15, 0.45, 1.0), 3.0), (0, -0.03, 0))
    crystal = crystal_mesh("Crystal")
    rnd = random.Random(4)
    for i in range(30):
        deg = 360 * i / 30 + rnd.uniform(-3, 3)
        if off_plate(deg):
            continue
        fc.put(sc, f"Crystal{i}", crystal, ice, fc.polar(BAND + 0.07, deg, -0.04),
               (R(rnd.uniform(-15, 15)), -R(deg - 90 + rnd.uniform(-30, 30)), 0), rnd.uniform(0.07, 0.12))
    diamond = fc.put(sc, "Diamond", fc.brilliant("Diamond", 1.0, 10), fc.gem("Diamond", (0.85, 0.93, 1.0), 0.05),
                     fc.polar(0.9, -38, -0.25), (R(-8), R(-14), 0), 0.15)
    fc.animate(diamond, lambda t: (R(-8), R(-14), TAU * t / 5), "rotation_euler")   # 10 facets: 1/5 turn repeats
    fc.twinkles(sc, glint_mat(), 9, 0.8, 1.0, 0.06, seed=5)
    return fc.plate(sc, "pill", fc.enamel("Tag", (0.02, 0.06, 0.25)), fc.label((0.92, 0.96, 1.0)),
                    fc.metal("TagRim", (0.6, 0.8, 1.0)))


def fire_ring(sc):
    fc.put(sc, "Band", fc.band("Band", BAND, 0.07, 0.06), fc.metal("Ember", (0.6, 0.14, 0.03), 0.3))
    fc.put(sc, "Core", fc.tube("Core", BAND, 0.016), fc.neon("Core", (1.0, 0.3, 0.02), 3.0, 3), (0, -0.03, 0))
    fire = fc.flow("Fire", [(0.22, (0.35, 0.01, 0.0)), (0.4, (0.9, 0.1, 0.0)), (0.62, (1.0, 0.38, 0.02)),
                            (0.85, (1.0, 0.7, 0.15)), (1.0, (1.0, 0.92, 0.6))],
                   scale=4.0, drift=(0.0, 0.0, -2.4), strength=2.4, r0=0.76, r1=1.0, falloff=1.1, stretch=(1.6, 1.0, 0.55))
    fc.put(sc, "Flames", fc.band("Flames", 0.87, 0.26, 0.002, round_r=0.0005), fire, (0, 0.05, 0))
    fc.falling(sc, "Ember", fc.sphere("Ember", 1.0, 1), st.emit("Ember", (1.0, 0.55, 0.15), 6.0), 10, 0.012, seed=7,
               top=-0.9, bottom=1.0, y=-0.15, inside=0.88)
    return fc.plate(sc, "pill", fc.enamel("Tag", (0.15, 0.02, 0.0)), fc.label((1.0, 0.85, 0.5)),
                    fc.metal("TagRim", (1.0, 0.5, 0.15)), "flame", icon_mat=st.emit("Flame", (1.0, 0.45, 0.05), 3.0))


def cosmic(sc):
    nebula = fc.flow("Nebula", [(0.15, (0.08, 0.01, 0.25)), (0.4, (0.35, 0.05, 0.8)), (0.7, (0.12, 0.35, 1.0)),
                                (1.0, (0.9, 0.55, 1.0))],
                     scale=3.0, drift=(0.6, 0.0, 0.4), strength=1.6, r0=0.72, r1=0.98, falloff=1.4, detail=8.0)
    fc.put(sc, "Nebula", fc.band("Nebula", 0.86, 0.26, 0.002, round_r=0.0005), nebula, (0, 0.05, 0))
    neon_ring(sc, (0.55, 0.15, 1.0), (0.15, 0.35, 1.0))
    planet = fc.put(sc, "Planet", fc.sphere("Planet", 1.0, 4), fc.enamel("Planet", (0.3, 0.35, 1.0), 0.4, 0.4),
                    fc.polar(0.86, 42, -0.3), (R(20), R(-25), 0), 0.13)
    fc.put(sc, "PlanetRing", fc.tube("PlanetRing", 1.65, 0.08), fc.metal("PlanetRing", (0.9, 0.8, 1.0), 0.3), parent=planet,
           rot=(R(70), 0, 0))
    moon = fc.put(sc, "Moon", fc.sphere("Moon", 0.03, 2), st.emit("Moon", (1, 0.95, 0.85), 4.0), (0, -0.3, 0))
    cx, _, cz = fc.polar(0.86, 42)
    fc.animate(moon, lambda t: (cx + 0.24 * math.cos(TAU * t), -0.3 - 0.1 * math.sin(TAU * t), cz + 0.07 * math.sin(TAU * t)))
    fc.twinkles(sc, st.emit("Star", (0.95, 0.9, 1.0), 12.0), 14, 0.78, 1.0, 0.045, seed=8)
    return fc.plate(sc, "pill", fc.enamel("Tag", (0.1, 0.03, 0.3)), fc.label((1.0, 0.95, 1.0)),
                    st.emit("TagRim", (0.5, 0.25, 1.0), 2.5), "star", icon_mat=st.emit("TagStar", (1.0, 0.85, 0.4), 2.5))


def silver_diamond(sc):
    silver = fc.metal("Silver", fc.SILVER, 0.12)
    gold_band(sc, mat=silver)
    stone = fc.gem("Diamond", (0.95, 0.97, 1.0), 0.05)
    me = fc.brilliant("Gem", 1.0, 10)
    gem_cluster(sc, "TL", me, stone, fc.polar(0.86, 140, -0.15), (0.13, 0.09, 0.07, 0.06), seed=1)
    gem_cluster(sc, "R", me, stone, fc.polar(0.88, 10, -0.15), (0.14, 0.09, 0.07), seed=2)
    fc.ring_of(sc, "Set", fc.gem_round("SetGem", 1.0), stone, 24, BAND, -0.05, scale=0.028)
    fc.twinkles(sc, glint_mat(), 10, 0.75, 1.0, 0.07, seed=3)
    return fc.plate(sc, "banner", fc.enamel("Ribbon", (0.62, 0.65, 0.72), 0.3), fc.label((0.03, 0.04, 0.08), 1.0),
                    fc.metal("Tails", (0.62, 0.65, 0.72), 0.3), w=0.86)


def sakura(sc):
    rose = fc.metal("RoseGold", (1.0, 0.72, 0.62), 0.28)
    fc.put(sc, "Band", fc.band("Band", BAND, 0.06, 0.06), rose)
    fc.put(sc, "Band2", fc.tube("Band2", BAND + 0.05, 0.01), rose)
    pink = st.pbr("Petal", (1.0, 0.45, 0.62), roughness=0.5, emission=(1.0, 0.4, 0.6), strength=0.12)
    petal = fc.slab("Petal", fc.petal_outline(1.0, 0.75), 0.03)
    small = fc.slab("Petal2", fc.petal_outline(1.0, 0.75), 0.05)
    center = st.pbr("Stamen", (1.0, 0.75, 0.2), roughness=0.4)
    for name, deg, s, rot in (("F1", 138, 0.24, 10), ("F2", 115, 0.18, -20), ("F3", 162, 0.16, 30),
                              ("F4", -38, 0.21, 5), ("F5", -58, 0.15, -25), ("F6", 28, 0.14, 15)):
        flower(sc, name, petal, pink, center, fc.polar(0.86, deg, -0.08), s, rot)
    fc.falling(sc, "Fall", small, pink, 9, 0.05, seed=9, x=(-0.95, 0.95), inside=0.8)
    return fc.plate(sc, "pill", fc.enamel("Tag", (0.8, 0.78, 0.79)), fc.label((0.55, 0.0, 0.18), 1.0),
                    fc.enamel("TagRim", (1.0, 0.5, 0.65)), "heart", icon_mat=st.emit("TagHeart", (1.0, 0.15, 0.35), 1.6))


def green_laurel(sc):
    gold = fc.metal("Gold", fc.GOLD)
    gold_band(sc, mat=fc.enamel("Green", (0.02, 0.35, 0.08)), rims=False)
    rims(sc, gold, 0.056, 0.012)
    leaf = st.pbr("Leaf", (0.2, 0.75, 0.12), roughness=0.35, coat=0.5, emission=(0.1, 0.4, 0.05), strength=0.2)
    fc.laurel(sc, leaf, -1, a_from=-62, a_to=85, count=12, size=0.24, stem=gold)
    fc.laurel(sc, leaf, 1, a_from=-62, a_to=-15, count=4, size=0.2, stem=gold)
    fc.twinkles(sc, glint_mat(), 7, 0.8, 0.98, 0.05, seed=12)
    return fc.plate(sc, "pill", fc.enamel("Tag", (0.01, 0.1, 0.03)), fc.label(GOLD_TEXT), gold, "leaf",
                    icon_mat=st.emit("TagLeaf", (0.3, 0.9, 0.2), 1.6))


def cyan_hud(sc):
    hud(sc, (0.0, 0.85, 1.0), 4.0)
    return fc.plate(sc, "pill", fc.enamel("Tag", (0.01, 0.05, 0.07)), fc.label((0.8, 1.0, 1.0)),
                    st.emit("TagRim", (0.0, 0.8, 1.0), 2.5), "shield")


def black_gold_ribbon(sc):
    gold, ink = fc.metal("Gold", fc.GOLD), fc.enamel("Ink", DARK, 0.15)
    fc.put(sc, "Band", fc.band("Band", BAND, 0.07, 0.06), gold)
    fc.put(sc, "Ribbon", fc.band("Ribbon", BAND + 0.05, 0.1, 0.03, R(150), R(390), 192), ink, (0, -0.04, 0))
    fc.put(sc, "RibbonEdge", fc.tube("RibbonEdge", BAND + 0.1, 0.009, R(150), R(390)), gold, (0, -0.05, 0))
    crown(sc, gold, fc.gem("Gem", (1.0, 0.75, 0.25)), fc.polar(0.86, 28, -0.08), 0.42, tilt=-28)
    fc.twinkles(sc, glint_mat(), 8, 0.78, 0.98, 0.06, seed=13)
    return fc.plate(sc, "banner", ink, fc.label(GOLD_TEXT), gold, w=0.86)


def purple_neon_crown(sc):
    neon_ring(sc, (0.6, 0.05, 1.0), (0.1, 0.25, 1.0))
    crown(sc, fc.metal("Gold", fc.GOLD), fc.gem("Gem", (0.75, 0.2, 1.0)), fc.polar(0.85, 128, -0.12), 0.42, tilt=36)
    bolt = fc.put(sc, "Bolt", fc.slab("Bolt", fc.bolt_outline(1.0), 0.06), fc.neon("Bolt", (1.0, 0.75, 0.05), 3.5, 2, 0.6, 1.4),
                  fc.polar(0.92, -12, -0.12), (0, R(-10), 0), 0.34)
    fc.bevel(bolt, 0.01, 2)
    fc.twinkles(sc, st.emit("Spark", (0.8, 0.5, 1.0), 10.0), 7, 0.82, 0.98, 0.045, seed=14)
    return fc.plate(sc, "pill", fc.enamel("Tag", (0.06, 0.02, 0.12)), fc.label((1.0, 0.95, 1.0)),
                    st.emit("TagRim", (0.55, 0.15, 1.0), 2.5), "bolt", icon_mat=st.emit("TagBolt", (1.0, 0.8, 0.1), 2.5))


def ice_snow(sc):
    ice = fc.gem("Ice", (0.6, 0.85, 1.0), 0.2, 1.31)
    fc.put(sc, "Band", fc.band("Band", BAND, 0.08, 0.07), ice)
    fc.put(sc, "Core", fc.tube("Core", BAND, 0.012), fc.neon("Core", (0.3, 0.65, 1.0), 2.5, 2), (0, -0.04, 0))
    flake = fc.snowflake("Flake", 1.0, 0.07, 0.05)
    frost = st.pbr("Frost", (0.85, 0.95, 1.0), roughness=0.2, emission=(0.6, 0.85, 1.0), strength=0.8)
    for i, (deg, s) in enumerate(((125, 0.14), (100, 0.1), (60, 0.13), (150, 0.08), (35, 0.09))):
        fc.spin(fc.put(sc, f"Flake{i}", flake, frost, fc.polar(0.9, deg, -0.1), scale=s), (-1) ** i / 6)  # 6 arms
    crystal = crystal_mesh("Icicle")
    for i in range(11):
        deg = -160 + 140 * i / 10
        if not off_plate(deg):
            fc.put(sc, f"Ice{i}", crystal, ice, fc.polar(0.92, deg, -0.04), (0, -R(deg - 90), 0), 0.12 - 0.03 * abs(i - 5) / 5)
    fc.falling(sc, "Snow", fc.sphere("Snow", 1.0, 1), st.emit("Snow", (0.95, 0.98, 1.0), 2.5), 14, 0.018, seed=15, inside=0.8)
    return fc.plate(sc, "pill", fc.enamel("Tag", (0.08, 0.25, 0.7), 0.15), fc.label((1.0, 1.0, 1.0)),
                    fc.metal("TagRim", (0.8, 0.9, 1.0)), "snow", icon_mat=st.emit("TagSnow", (0.85, 0.95, 1.0), 1.6))


def navy_laurel(sc):
    gold, navy = fc.metal("Gold", fc.GOLD), fc.enamel("Navy", (0.02, 0.06, 0.32))
    gold_band(sc, 0.1, mat=navy, rims=False)
    rims(sc, gold, 0.062, 0.014)
    leaf_gold = fc.metal("LeafGold", (1.0, 0.76, 0.32), 0.3, 0.6)
    for side in (-1, 1):
        fc.laurel(sc, leaf_gold, side, a_from=-58, a_to=48, count=9, size=0.21)
    obs = fc.plate(sc, "banner", navy, fc.label(GOLD_TEXT), gold, w=0.8, z=-0.86)
    disc = fc.slab("Medal", [(0.09 * math.cos(TAU * i / 40), 0.09 * math.sin(TAU * i / 40)) for i in range(40)], 0.04)
    obs.append(fc.put(sc, "Medal", disc, navy, (0, -0.3, -0.7)))
    obs.append(fc.put(sc, "MedalRim", fc.tube("MedalRim", 0.095, 0.014), gold, (0, -0.3, -0.7)))
    obs.append(fc.emblem(sc, "star", gold, (0, -0.34, -0.7), 0.065))
    return obs


def white_green_leaf(sc):
    white = fc.enamel("Porcelain", (0.8, 0.84, 0.81), 0.15)
    fc.put(sc, "Band", fc.band("Band", BAND, 0.08, 0.06), white)
    fc.put(sc, "Glow", fc.tube("Glow", BAND + 0.05, 0.013), fc.comet("Glow", (0.1, 1.0, 0.35), 4.0, 0.5, 1, 0.2), (0, -0.01, 0))
    fc.put(sc, "GlowIn", fc.tube("GlowIn", BAND - 0.05, 0.009), fc.neon("GlowIn", (0.1, 0.9, 0.35), 1.5, 2))
    leaf_mat = st.pbr("Leaf", (0.12, 0.65, 0.18), roughness=0.3, coat=0.6, emission=(0.05, 0.35, 0.08), strength=0.2)
    leaf = fc.slab("BigLeaf", fc.leaf_outline(1.0, 0.45), 0.05, smooth=True)
    for i, (deg, s, rot) in enumerate(((-30, 0.44, 72), (-12, 0.34, 28), (-50, 0.3, 115), (-22, 0.24, 145), (8, 0.22, 60))):
        ob = fc.bevel(fc.put(sc, f"Leaf{i}", leaf, leaf_mat, fc.polar(0.86, deg, -0.12 - 0.01 * i), (0, -R(rot), 0), s), 0.006, 2)
        base = ob.rotation_euler.copy()
        fc.animate(ob, lambda t, base=base, i=i: (base.x, base.y + R(4) * math.sin(TAU * (t + i * 0.3)), base.z), "rotation_euler")
    fc.twinkles(sc, glint_mat(), 6, 0.8, 0.98, 0.05, seed=16)
    return fc.plate(sc, "pill", fc.enamel("Tag", (0.78, 0.82, 0.79), 0.2), fc.label((0.0, 0.25, 0.06), 1.0), fc.enamel("TagRim", (0.15, 0.75, 0.3)), "leaf",
                    icon_mat=st.emit("TagLeaf", (0.1, 0.7, 0.2), 1.4))


def teal_brush(sc):
    paint = fc.flow("Paint", [(0.1, (0.0, 0.2, 0.3)), (0.35, (0.0, 0.45, 0.55)), (0.65, (0.08, 0.65, 0.78)),
                              (1.0, (0.55, 0.95, 1.0))],
                    scale=7.0, drift=(0.25, 0.0, 0.0), strength=1.4, r0=0.72, r1=0.94, falloff=0.8, detail=10.0)
    fc.put(sc, "Paint", fc.band("Paint", 0.84, 0.22, 0.002, round_r=0.0005), paint, (0, 0.03, 0))
    gold = fc.metal("Gold", fc.GOLD, 0.25)
    fc.put(sc, "GoldStroke", fc.band("GoldStroke", BAND + 0.02, 0.055, 0.03, R(-70), R(150)), gold, (0, -0.02, 0))
    fc.put(sc, "GoldStroke2", fc.tube("GoldStroke2", BAND - 0.045, 0.011, R(170), R(300)), gold, (0, -0.02, 0))
    fc.twinkles(sc, glint_mat(), 9, 0.75, 0.98, 0.05, seed=17)
    obs = fc.plate(sc, "banner", fc.enamel("Ribbon", (1.0, 0.72, 0.25), 0.3), fc.label((0.08, 0.05, 0.02), 1.0),
                   fc.metal("Tails", (0.85, 0.55, 0.18)), w=0.84)
    for ob in obs:
        if ob.parent is None:
            ob.rotation_euler.y += R(-10)
            ob.location.x += 0.08
    return obs


def violet_hud(sc):
    hud(sc, (0.5, 0.15, 1.0), 4.5)
    return fc.plate(sc, "pill", fc.enamel("Tag", (0.05, 0.02, 0.1)), fc.label((1.0, 0.95, 1.0)),
                    st.emit("TagRim", (0.5, 0.15, 1.0), 2.5), "u")


def black_gold_stripes(sc):
    gold = fc.metal("Gold", fc.GOLD)
    fc.put(sc, "Band", fc.band("Band", BAND, 0.12, 0.07), stripes("Stripes", DARK, fc.GOLD))
    rims(sc, gold, 0.07)
    fc.put(sc, "Sweep", fc.tube("Sweep", BAND + 0.07, 0.014), fc.comet("Sweep", (1.0, 0.8, 0.4), 5.0, 0.15, 1, 0.0),
           (0, -0.004, 0))
    fc.twinkles(sc, glint_mat(), 6, 0.8, 0.95, 0.06, seed=18)
    return fc.plate(sc, "pill", fc.enamel("Tag", DARK, 0.15), fc.label(GOLD_TEXT), gold, "gem",
                    icon_mat=fc.gem("TagGem", (1.0, 0.8, 0.4), 0.6))


def red_hearts(sc):
    red = st.pbr("Red", (0.85, 0.02, 0.06), roughness=0.15, coat=1.0)
    fc.put(sc, "Band", fc.band("Band", BAND, 0.08, 0.06), red)
    fc.put(sc, "Swirl", fc.tube("Swirl", BAND + 0.055, 0.011, R(20), R(250)), fc.metal("Pearl", (1.0, 0.85, 0.85), 0.2))
    heart = st.heart_mesh("Heart", 1.0, 0.5)
    for i, (deg, s, off) in enumerate(((-140, 0.17, 0.0), (-122, 0.12, 0.3), (-160, 0.1, 0.6), (-128, 0.08, 0.15),
                                       (48, 0.13, 0.45), (70, 0.09, 0.75), (30, 0.08, 0.9))):
        ob = fc.put(sc, f"Heart{i}", heart, red, fc.polar(0.9, deg, -0.1), (0, R(deg % 30 - 15), 0), s)
        fc.pulse(ob, 0.9, 1.08, off, 2)                          # a heartbeat twice per loop
    fc.twinkles(sc, glint_mat(), 6, 0.8, 0.98, 0.05, seed=19)
    return fc.plate(sc, "pill", st.pbr("Tag", (0.7, 0.02, 0.05), roughness=0.2, coat=1.0), fc.label((1.0, 0.95, 0.95)),
                    fc.metal("TagRim", (1.0, 0.8, 0.8)), "heart", icon_mat=st.emit("TagHeart", (1.0, 0.9, 0.9), 1.6))


def gold_stars(sc):
    gold = fc.metal("Gold", fc.GOLD)
    gold_band(sc)
    star = fc.faceted_star("Star", 5, 1.0, 0.45, 0.4)
    for i in range(7):
        deg = 90 + 360 * i / 7
        if off_plate(deg):
            continue
        ob = fc.put(sc, f"Star{i}", star, gold, fc.polar(BAND + 0.03, deg, -0.08), scale=0.12 if i % 2 else 0.16)
        base = ob.rotation_euler.copy()
        fc.animate(ob, lambda t, i=i, base=base: (base.x, base.y + R(8) * math.sin(TAU * (t + i / 7)), base.z), "rotation_euler")
    fc.twinkles(sc, glint_mat(), 10, 0.78, 1.0, 0.06, seed=20)
    return fc.plate(sc, "banner", fc.enamel("Ribbon", (1.0, 0.7, 0.2), 0.3), fc.label((0.1, 0.05, 0.0), 1.0),
                    fc.metal("Tails", (0.85, 0.5, 0.12)), "star", w=0.86, icon_mat=fc.enamel("TagStar", (0.25, 0.1, 0.0)))


def green_leaves(sc):
    neon_ring(sc, (0.1, 1.0, 0.2), (0.6, 1.0, 0.1))
    leaf = st.pbr("Leaf", (0.2, 0.8, 0.15), roughness=0.3, coat=0.5, emission=(0.1, 0.6, 0.05), strength=0.3)
    fc.laurel(sc, leaf, -1, a_from=-62, a_to=75, count=12, size=0.23, stem=st.pbr("Stem", (0.15, 0.45, 0.1), roughness=0.4))
    fc.twinkles(sc, st.emit("Spark", (0.7, 1.0, 0.6), 10.0), 6, 0.82, 0.98, 0.045, seed=21)
    return fc.plate(sc, "pill", fc.enamel("Tag", (0.01, 0.12, 0.03)), fc.label((0.9, 1.0, 0.9)),
                    st.emit("TagRim", (0.1, 0.9, 0.25), 2.5), "leaf", icon_mat=st.emit("TagLeaf", (0.3, 1.0, 0.25), 2.0))


DESIGNS = {f.__name__: f for f in (
    gold_laurel, teal_neon, blue_crystal, fire_ring, cosmic, silver_diamond, sakura, green_laurel, cyan_hud,
    black_gold_ribbon, purple_neon_crown, ice_snow, navy_laurel, white_green_leaf, teal_brush, violet_hud,
    black_gold_stripes, red_hearts, gold_stars, green_leaves)}
