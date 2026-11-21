"""UZARO v2 show: pegasus (tier 4, 168 f = 7 s).

A golden winged horse flies a full arc across and around the frame, feather wings beating, mane and tail glowing, a trail
of gold dust hanging behind it; it lands at centre in a burst of light, wings raised, tosses its head and springs up
out of frame. Body is the horse model from the horse gift; the wings are built here from individual feathers.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import animal  # noqa: E402
import gift_common as gc  # noqa: E402
import horse_show as hs  # noqa: E402
import quadruped as qp  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, env, interp  # noqa: E402

ID = "pegasus"
TOTAL = 168
SIZE = 5.4
K = SIZE / 6.0            # joints are measured at the horse size 6
GROUND_Z = -3.4
FOOT = 2.33
X, Y, Z = animal.X, animal.Y, animal.Z
GOLD = (1.0, 0.68, 0.24)
LAND_F = 130
TAKEOFF_F = 152
ARC = [(9.5, 3.5, 4.8), (2.0, 4.0, 4.2), (-3.0, 2.0, 2.0), (-2.2, -2.0, -0.6), (2.0, -2.0, -0.2), (2.6, 0.6, 1.0), (0.0, 0.0, GROUND_Z + FOOT * K)]
WING_POINTS = [(0.28, -0.55, 1.15), (1.5, -0.35, 1.7), (2.9, 0.0, 2.15), (4.5, 0.5, 2.3)]
SIDES = (("L", 1.0), ("R", -1.0))


def wing_bones():
    out = []
    for side, s in SIDES:
        pts = [Vector((p[0] * s, p[1], p[2])) for p in WING_POINTS]
        for i in range(3):
            out.append((f"wing{side}{i}", "spine1" if i == 0 else f"wing{side}{i - 1}", pts[i], pts[i + 1]))
    return out


def point_on_wing(t, s):
    """t 0..3 along the three wing bones."""
    i = min(2, int(t))
    a, b = Vector(WING_POINTS[i]), Vector(WING_POINTS[i + 1])
    p = a.lerp(b, t - i)
    return Vector((p.x * s, p.y, p.z))


def feather(verts, faces, weights, root, direction, normal, length, width, t, curve=0.14):
    """A leaf quad strip with a raised midrib, curling down at the tip; weights follow where its root sits on the wing."""
    side = direction.cross(normal).normalized()
    base = len(verts)
    n = 7
    for k in range(n + 1):
        u = k / n
        c = root + direction * (length * u) - normal * (curve * length * u * u)
        w = width * math.sin(math.pi * min(1.0, u * 0.92 + 0.08)) ** 0.6
        for q, lift in ((-1.0, -0.018), (0.0, 0.018), (1.0, -0.018)):
            verts.append(c + side * (q * w / 2) + normal * lift)
    for k in range(n):
        a = base + k * 3
        faces += [(a, a + 3, a + 4, a + 1), (a + 1, a + 4, a + 5, a + 2)]
    i = min(2, int(t))
    frac = t - i
    w = {i: 1.0 - frac}
    w[min(2, i + 1)] = w.get(min(2, i + 1), 0.0) + frac
    weights += [w] * ((n + 1) * 3)


def wing_mesh(sc, arm, side, s, mat):
    verts, faces, weights = [], [], []
    rnd = stage.seeded(3 if s > 0 else 4)
    up = Vector((0, 0, 1))
    # (rows) count, t range, length range, width, back-sweep angle at root and at tip, height above bone
    rows = ((13, (2.0, 3.0), (2.1, 1.35), 0.34, (55.0, 12.0), -0.02), (15, (0.15, 2.05), (1.7, 2.1), 0.36, (88.0, 60.0), -0.02),
            (22, (0.15, 3.0), (0.95, 0.62), 0.27, (80.0, 30.0), 0.05), (30, (0.1, 3.0), (0.5, 0.34), 0.2, (76.0, 34.0), 0.09))
    for count, (t0, t1), (l0, l1), width, (a0, a1), lift in rows:
        for j in range(count):
            u = j / max(1, count - 1)
            t = t0 + (t1 - t0) * u
            ang = R(a0 + (a1 - a0) * u + rnd.uniform(-2.0, 2.0))
            d = Vector((math.cos(ang) * s, math.sin(ang), -0.06)).normalized()
            feather(verts, faces, weights, point_on_wing(t, s) + up * lift, d, up, (l0 + (l1 - l0) * u) * rnd.uniform(0.96, 1.04), width, t)
    me = bpy.data.meshes.new(f"Wing{side}")
    me.from_pydata(verts, [], faces)
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    ob = stage.link(sc, f"Wing{side}", me, mat, parent=arm)
    groups = [ob.vertex_groups.new(name=f"wing{side}{i}") for i in range(3)]
    for vi, w in enumerate(weights):
        for i, x in w.items():
            if x > 0.0:
                groups[i].add([vi], x, "REPLACE")
    ob.modifiers.new("Rig", "ARMATURE").object = arm
    return ob


def feather_material():
    """Gold with barbs: a stretched noise bump gives each vane its grain; a touch of glow at the keyed moments."""
    m = stage.pbr("Plumage", GOLD, metallic=0.9, roughness=0.3, emission=(1.0, 0.62, 0.2), strength=0.15)
    nt = m.node_tree
    noise, bump, map_, tc = nt.nodes.new("ShaderNodeTexNoise"), nt.nodes.new("ShaderNodeBump"), nt.nodes.new("ShaderNodeMapping"), nt.nodes.new("ShaderNodeTexCoord")
    map_.inputs["Scale"].default_value = (70.0, 8.0, 70.0)
    noise.inputs["Detail"].default_value = 3.0
    bump.inputs["Strength"].default_value = 0.35
    nt.links.new(tc.outputs["Object"], map_.inputs["Vector"])
    nt.links.new(map_.outputs[0], noise.inputs["Vector"])
    nt.links.new(noise.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs[0], stage.bsdf(m).inputs["Normal"])
    return m


def gild(mat):
    """Keep the coat's light and dark from the texture, but in gold metal."""
    b, nt = stage.bsdf(mat), mat.node_tree
    if b.inputs["Base Color"].links:
        src = b.inputs["Base Color"].links[0].from_socket
        ramp = nt.nodes.new("ShaderNodeRGBToBW")
        nt.links.new(src, ramp.inputs[0])
        rng = nt.nodes.new("ShaderNodeMapRange")
        rng.inputs["From Min"].default_value, rng.inputs["From Max"].default_value = 0.0, 0.6
        rng.inputs["To Min"].default_value, rng.inputs["To Max"].default_value = 0.55, 1.0
        nt.links.new(ramp.outputs[0], rng.inputs["Value"])
        mix = nt.nodes.new("ShaderNodeMix")
        mix.data_type, mix.blend_type = "RGBA", "MULTIPLY"
        mix.inputs["Factor"].default_value = 1.0
        mix.inputs["B"].default_value = (*GOLD, 1.0)
        nt.links.new(rng.outputs["Result"], mix.inputs["A"])
        nt.links.new(mix.outputs["Result"], b.inputs["Base Color"])
    stage.shiny(mat, roughness=0.3, metallic=0.85)


def mane(m):
    """Glowing hair: crest of the neck and along the tail, picked by position on the rest mesh."""
    vg = m.vertex_groups.new(name="Mane")
    a, c = Vector((-1.0, 1.05)), Vector((-2.3, 2.3))   # (y, z) along the crest
    span = (c - a).length
    for v in m.data.vertices:
        p = Vector((v.co.y, v.co.z))
        u = (p - a).dot(c - a) / span ** 2
        off = (p - a.lerp(c, max(0.0, min(1.0, u)))).length
        crest = 0.0 <= u <= 1.05 and abs(v.co.x) < 0.14 and off < 0.2
        tail = v.co.y > 2.45
        vg.add([v.index], 1.0 if crest or tail else 0.0, "REPLACE")
    ps = animal.fur(m, 0.26, count=1100, children=6, radius=0.004, density_vg="Mane", clump=0.7, multiply=(0.28, 0.1, 0.012), seed=4)
    hm = m.data.materials[ps.settings.material - 1]
    nt = hm.node_tree
    hair = next(n for n in nt.nodes if n.type == "BSDF_HAIR_PRINCIPLED")
    out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL")
    em, add = nt.nodes.new("ShaderNodeEmission"), nt.nodes.new("ShaderNodeAddShader")
    em.inputs["Color"].default_value = (1.0, 0.6, 0.16, 1.0)
    em.inputs["Strength"].default_value = 0.12
    nt.links.new(hair.outputs[0], add.inputs[0])
    nt.links.new(em.outputs[0], add.inputs[1])
    nt.links.new(add.outputs[0], out.inputs["Surface"])


def load(sc):
    root, model, objs, meshes = stage.load("horse", 6.0)
    limits = {f"wing{side}{i}": (lambda c: c[:, 0] * 0.0) for side, _ in SIDES for i in range(3)}
    arm = animal.build(sc, "Pegasus", hs.JOINTS, meshes, power=7.0, limits=limits, extra=wing_bones())
    wrap = bpy.data.objects.new("Heading", None)
    sc.collection.objects.link(wrap)
    wrap.parent = root
    wrap.rotation_mode = "XYZ"
    arm.parent = wrap
    root.scale = (K, K, K)
    for m in meshes:
        for s in m.data.materials:
            gild(s)
        mane(m)
    plumage = feather_material()
    for side, s in SIDES:
        wing_mesh(sc, arm, side, s, plumage)
    return root, wrap, arm, meshes


def wing_spec(flap, raise_up=0.0):
    """flap -1..1, down positive; raise_up folds into a tall V so the span fits the safe area on the ground."""
    spec = {}
    for side, s in SIDES:
        spec[f"wing{side}0"] = (Y, s * (24.0 * flap - 62.0 * raise_up))
        spec[f"wing{side}1"] = (Y, s * (18.0 * math.sin(flap * 1.2) - 8.0 * raise_up))
        spec[f"wing{side}2"] = (Y, s * (24.0 * flap - 12.0 * abs(flap) + 26.0 * raise_up))
    return spec


def path(f):
    if f <= LAND_F:
        t = (f - 1) / (LAND_F - 1)
        return Vector(stage.catmull(ARC, t))
    p = Vector(ARC[-1])
    if f <= TAKEOFF_F:
        return p
    u = (f - TAKEOFF_F) / (TOTAL - TAKEOFF_F)
    return p + Vector((0.0, 1.0 * u, 16.0 * u * u))


def animate(root, wrap, mover):
    for f in range(1, TOTAL + 1):
        ground = 1.0 if LAND_F <= f <= TAKEOFF_F else 0.0
        land = env(f, LAND_F - 7, LAND_F) * (1 - env(f, TAKEOFF_F, TAKEOFF_F + 7))
        fly = 1 - land
        p = path(f)
        beat = math.sin(f * 2 * math.pi / 14.0)
        flap = beat * fly + 0.12 * math.sin(f / 5.0) * land
        d = path(f + 1) - path(f - 1)
        if d.length > 1e-4:
            pitch, yaw = stage.aim(d)
            prev = stage.aim(path(f + 3) - path(f + 1))[1] if f < LAND_F - 3 else yaw
            bank = max(-30.0, min(30.0, math.degrees(_wrap(prev - yaw)) * 6.0))
        else:
            pitch, yaw, bank = 0.0, R(-18), 0.0
        if f >= LAND_F - 8:
            yaw_blend = land if f <= TAKEOFF_F else 1.0
            yaw = yaw + _wrap(R(66) - yaw) * yaw_blend
            pitch *= 1 - yaw_blend
            bank *= 1 - yaw_blend
        wrap.rotation_euler = (pitch * 0.55, R(bank), yaw)
        wrap.keyframe_insert("rotation_euler", frame=f)
        root.location = p + Vector((0, 0, 0.2 * flap * fly))
        root.keyframe_insert("location", frame=f)
        mover.legs_at(f, 0.0, 0.0)
        tuck = fly
        for key, ph in (("LF", 0.0), ("RF", 0.8), ("LB", 2.2), ("RB", 3.0)):
            run = math.sin(f / 4.0 + ph)
            fore = key.endswith("F")
            mover.leg(f, key, paw=(tuck * ((0.7 if fore else -0.5) + 0.35 * run), tuck * ((1.25 if fore else 0.8) + 0.25 * run)), flex=tuck * (1.1 if fore else 0.3))
        toss = env(f, LAND_F + 6, LAND_F + 12) * (1 - env(f, LAND_F + 16, LAND_F + 22))
        spec = {
            "spine0": (X, -3.0 * flap - 14.0 * toss),
            "spine1": (X, -3.0 * flap - 10.0 * toss),
            "neck0": (X, -8.0 * fly + 5.0 * flap + 8.0 * toss),
            "neck1": (X, -6.0 * fly - 12.0 * toss),
            "head": (X, 16.0 * fly + 3.0 * flap - 14.0 * toss),
            "earL0": (X, 18.0 * fly), "earR0": (X, 18.0 * fly),
            "tail0": (X, -32.0 * fly + 8.0 * math.sin(f / 3.4)),
            "tail1": (X, -20.0 * fly + 8.0 * math.sin(f / 3.4 - 0.9)),
            "tail2": (X, 9.0 * math.sin(f / 3.4 - 1.8)),
        }
        spec.update(wing_spec(flap, land))
        mover.body(f, spec)
        _ = ground


def _wrap(a):
    return (a + math.pi) % (2 * math.pi) - math.pi


def trail(sc, root):
    """Gold dust left hanging in the air along the arc, drifting down."""
    for name, rgb, strength, size, n in (("Dust", (1.0, 0.72, 0.25), 18.0, 0.024, 2200), ("Spark", (1.0, 0.88, 0.55), 34.0, 0.012, 1100)):
        mat = fx.fade_material(f"Trail{name}", rgb, strength, 1.0, 0.8)
        em = fx.particle_burst(sc, f"Trail{name}", fx.ring_mesh(f"Trail{name}R", 1.4, 0.2, 36), mat, n, (1, LAND_F), 42, size, 0.12, rand=0.5, gravity=0.04)
        em.parent = root
    wingtips = fx.fade_material("Tips", (1.0, 0.78, 0.35), 24.0, 1.0, 0.9)
    em = fx.particle_burst(sc, "Tips", fx.ring_mesh("TipsR", 3.6, 0.1, 24), wingtips, 1000, (1, LAND_F), 30, 0.016, 0.05, rand=0.3, gravity=0.05, location=(0, 0.3, 2.0))
    em.parent = root
    takeoff = fx.fade_material("TakeoffGold", (1.0, 0.72, 0.25), 20.0, 1.0, 0.8)
    em = fx.particle_burst(sc, "Takeoff", fx.ring_mesh("TakeoffR", 1.4, 0.2, 36), takeoff, 700, (TAKEOFF_F, TOTAL), 32, 0.024, 0.12, rand=0.5, gravity=0.06)
    em.parent = root


def burst(sc):
    at = (0.0, 0.0, GROUND_Z + 0.04)
    fx.shock_ring(sc, "LandRing", at, (LAND_F, LAND_F + 22), 4.4, (1.0, 0.72, 0.28), 5.0, width=0.06)
    core = stage.link(sc, "LandCore", gc.ico_mesh("LandCore", 0.5, 2), stage.emit("LandCore", (1.0, 0.8, 0.45), 7.0), loc=(0.0, 0.0, GROUND_Z + 0.3), shadow=False)
    stage.key_path(core, (LAND_F - 2, LAND_F + 2, LAND_F + 11), lambda f: {LAND_F - 2: (0.001,) * 3, LAND_F + 2: (1.6, 1.6, 0.35), LAND_F + 11: (0.001,) * 3}[f], path="scale")
    for name, rgb in (("BurstA", (1.0, 0.76, 0.3)), ("BurstB", (1.0, 0.92, 0.65))):
        fx.particle_burst(sc, name, fx.ring_mesh(f"{name}R", 0.9, 0.1, 40), stage.emit(name, rgb, 24.0), 500, (LAND_F, LAND_F + 4), 30, 0.022, 3.6, rand=1.2, align=(0, 0, 2.6), damping=0.06, gravity=0.14, location=at)
    ld = bpy.data.lights.new("Land", "POINT")
    ld.color, ld.shadow_soft_size = (1.0, 0.72, 0.35), 1.0
    stage.link(sc, "LandL", ld, loc=(0.0, -2.0, GROUND_Z + 1.0))
    for f, e in ((LAND_F - 1, 0.0), (LAND_F + 2, 2200.0), (LAND_F + 20, 0.0)):
        ld.energy = e
        ld.keyframe_insert("energy", frame=f)


def build_show(sc, opts):
    root, wrap, arm, meshes = load(sc)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.7, hdri="studio.exr", follow=root, lights=0.6, fog=(2.2, 7), streak=7.0)
    gas_like = sc.view_settings
    gas_like.view_transform, gas_like.look = "Filmic", "Medium High Contrast"
    sh.shadow_catcher(sc, GROUND_Z, 50)
    animate(root, wrap, animal.Mover(arm, GAIT, animal.GALLOP_PHASES))
    trail(sc, root)
    burst(sc)
    sh.camera_shake(cam, LAND_F, 12, amp=0.05, rot_deg=0.3, seed=9)
    sh.screen_extent(sc, cam, meshes, (1, 40, 80, 110, LAND_F, TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Hovering three-quarter, wings beating twice per loop; a gold dust halo."""
    root, wrap, arm, meshes = load(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=0.7, hdri="studio.exr", follow=root, lights=0.6, fog=(2.2, 7), streak=7.0)
    sc.view_settings.view_transform, sc.view_settings.look = "Filmic", "Medium High Contrast"
    mover = animal.Mover(arm, GAIT, animal.GALLOP_PHASES)
    wrap.rotation_euler = (0.0, 0.0, R(62))
    n = stage.ICON_N
    for f in range(0, n + 1):
        w = 2 * math.pi * f / n
        flap = math.sin(2 * w)
        mover.legs_at(f, 0.0, 0.0)
        for key, ph in (("LF", 0.0), ("RF", 0.8), ("LB", 2.2), ("RB", 3.0)):
            fore = key.endswith("F")
            run = math.sin(w + ph)
            mover.leg(f, key, paw=(((0.7 if fore else -0.5) + 0.3 * run), ((1.25 if fore else 0.8) + 0.2 * run)), flex=1.1 if fore else 0.3)
        spec = {"neck0": (X, -8.0 + 4.0 * flap), "head": (X, 14.0 + 3.0 * flap), "tail0": (X, -30.0 + 6.0 * math.sin(w)), "tail1": (X, -20.0 + 8.0 * math.sin(w - 1)), "tail2": (X, 9.0 * math.sin(w - 2))}
        spec.update(wing_spec(flap))
        mover.body(f, spec)
        root.location = (0.0, 0.0, 0.2 * math.sin(2 * w - 0.8))
        root.keyframe_insert("location", frame=f)
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.5)
    _ = (interp, Z)


GAIT = qp.Gait(cycle_dist=7.0, duty=0.42, lift=0.75, bob=0.0, hind_flex=35.0, fore_flex=70.0)

if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
