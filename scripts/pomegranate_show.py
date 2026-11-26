"""UZARO v2 show: pomegranate (tier 1, 96 f = 4 s).

A glossy pomegranate rolls in and settles, shivers, and cracks open into three wedges that fall outward; ruby seeds
spill out as rigid bodies, bounce and roll, and glint like gems. All meshes are built here: wedge lathes with pith
caps, a six-point calyx crown, faceted ruby seeds.
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
from stage import R, env, interp  # noqa: E402

ID = "pomegranate"
TOTAL = 96
GROUND_Z = -2.4
RAD = 1.55
ROLL = (1, 22)
CRACK, BURST = 26, 36
EXIT = 84                         # everything dissolves into sparkles from here, gone by the last frame
ELEV = R(16)
PROFILE = [(0.0, -1.0), (0.42, -0.97), (0.78, -0.82), (0.97, -0.5), (1.02, -0.08), (0.96, 0.36), (0.8, 0.7), (0.52, 0.9),
           (0.3, 0.98), (0.0, 1.0)]
SEEDS = 260


def skin_material():
    """Deep red-to-crimson peel with a blush and a high gloss coat."""
    m = stage.pbr("Peel", (0.5, 0.03, 0.04), roughness=0.3, coat=0.9)
    nt = m.node_tree
    N, L = nt.nodes.new, nt.links.new
    tc, noise, ramp = N("ShaderNodeTexCoord"), N("ShaderNodeTexNoise"), N("ShaderNodeValToRGB")
    noise.inputs["Scale"].default_value, noise.inputs["Detail"].default_value = 2.2, 6.0
    L(tc.outputs["Object"], noise.inputs["Vector"])
    e = ramp.color_ramp.elements
    e[0].position, e[0].color = 0.35, (0.28, 0.02, 0.03, 1)
    e[1].position, e[1].color = 0.7, (0.75, 0.12, 0.08, 1)
    L(noise.outputs["Fac"], ramp.inputs["Fac"])
    L(ramp.outputs["Color"], stage.bsdf(m).inputs["Base Color"])
    fine = N("ShaderNodeTexNoise")
    fine.inputs["Scale"].default_value = 40.0
    L(tc.outputs["Object"], fine.inputs["Vector"])
    bump = N("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.08
    L(fine.outputs["Fac"], bump.inputs["Height"])
    L(bump.outputs[0], stage.bsdf(m).inputs["Normal"])
    stage.bsdf(m).inputs["Coat Roughness"].default_value = 0.08
    return m


def cut_material():
    """The cut faces: packed ruby arils (Voronoi cells, domed by their own distance) in cream membrane."""
    m = stage.pbr("Cut", (0.95, 0.88, 0.72), roughness=0.25, coat=0.6)
    nt = m.node_tree
    N, L = nt.nodes.new, nt.links.new
    b = stage.bsdf(m)
    tc, vor, edge = N("ShaderNodeTexCoord"), N("ShaderNodeTexVoronoi"), N("ShaderNodeTexVoronoi")
    vor.inputs["Scale"].default_value = edge.inputs["Scale"].default_value = 7.0
    edge.feature = "DISTANCE_TO_EDGE"
    for v in (vor, edge):
        v.inputs["Randomness"].default_value = 0.8
        L(tc.outputs["Object"], v.inputs["Vector"])
    ramp = N("ShaderNodeValToRGB")
    e = ramp.color_ramp.elements
    e[0].position, e[0].color = 0.04, (0.95, 0.88, 0.72, 1)        # membrane between the seeds
    e[1].position, e[1].color = 0.09, (0.62, 0.02, 0.06, 1)
    e.new(0.3).color = (0.85, 0.08, 0.12, 1)
    L(edge.outputs["Distance"], ramp.inputs["Fac"])
    L(ramp.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Subsurface Weight"].default_value = 0.5
    b.inputs["Subsurface Radius"].default_value = (0.8, 0.1, 0.1)
    dome = N("ShaderNodeMath")
    dome.operation = "SUBTRACT"
    dome.inputs[0].default_value = 1.0
    L(vor.outputs["Distance"], dome.inputs[1])
    bump = N("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.45
    L(dome.outputs[0], bump.inputs["Height"])
    L(bump.outputs[0], b.inputs["Normal"])
    return m


def ruby():
    m = stage.pbr("Ruby", (0.9, 0.04, 0.08), roughness=0.02, transmission=1.0, ior=1.6, coat=0.5)
    b = stage.bsdf(m)
    b.inputs["Emission Color"].default_value = (0.7, 0.02, 0.05, 1)
    b.inputs["Emission Strength"].default_value = 0.25
    return m


def wedge(name, a0, a1, segs=28):
    """Lathe of PROFILE (scaled by RAD) from angle a0 to a1, with flat pith caps on both cut planes."""
    bm = bmesh.new()
    prof = [(r * RAD, z * RAD) for r, z in PROFILE]
    rows = []
    for i in range(segs + 1):
        a = a0 + (a1 - a0) * i / segs
        rows.append([bm.verts.new((r * math.cos(a), r * math.sin(a), z)) if r > 1e-6 else None for r, z in prof])
    axis = [bm.verts.new((0.0, 0.0, z)) for r, z in prof if r <= 1e-6]
    ends = {0: axis[0], len(prof) - 1: axis[-1]}
    skin = []
    for r0, r1 in zip(rows, rows[1:]):
        for j in range(len(prof) - 1):
            a, b, c, d = r0[j] or ends[j], r0[j + 1] or ends[j + 1], r1[j + 1] or ends[j + 1], r1[j] or ends[j]
            vs = [v for v in (a, b, c, d) if v is not None]
            uniq = list(dict.fromkeys(vs))
            if len(uniq) >= 3:
                skin.append(bm.faces.new(uniq))
    caps = []
    for row in (rows[0], rows[-1]):
        ring = [ends[0]] + [v for v in row if v is not None] + [ends[len(prof) - 1]]
        caps.append(bm.faces.new(ring))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    me.polygons.foreach_set("use_smooth", [len(p.vertices) == 4 or len(p.vertices) == 3 for p in me.polygons])
    for p in me.polygons:
        p.material_index = 1 if len(p.vertices) > 4 else 0
    return me


def crown_mesh(name):
    """Six pointed calyx lobes around a short tube."""
    bm = bmesh.new()
    n = 12
    base = [bm.verts.new((0.22 * RAD * math.cos(2 * math.pi * i / n), 0.22 * RAD * math.sin(2 * math.pi * i / n), 0.0)) for i in range(n)]
    tip = []
    for i in range(n):
        a = 2 * math.pi * i / n
        r = (0.34 if i % 2 == 0 else 0.2) * RAD
        z = (0.32 if i % 2 == 0 else 0.2) * RAD
        tip.append(bm.verts.new((r * math.cos(a), r * math.sin(a), z)))
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((base[i], base[j], tip[j], tip[i]))
    bmesh.ops.solidify(bm, geom=bm.faces[:], thickness=0.03)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return me


def seed_mesh():
    """Faceted teardrop seed: an ico stretched along Z, flat shaded so the facets catch light."""
    me = gc.ico_mesh("Seed", 0.1, 1)
    me.transform(Matrix.Diagonal((0.85, 0.85, 1.25, 1.0)))
    return me


def build_fruit(sc):
    root = bpy.data.objects.new("Fruit", None)
    sc.collection.objects.link(root)
    peel, pith = skin_material(), cut_material()
    hinges, wedges = [], []
    for k in range(3):
        a0 = 2 * math.pi * k / 3 + R(8)
        a1 = a0 + 2 * math.pi / 3
        mid = (a0 + a1) / 2
        hinge = bpy.data.objects.new(f"Hinge{k}", None)          # pivots on the bottom outer edge of each wedge
        sc.collection.objects.link(hinge)
        hinge.parent = root
        hinge.location = (0.55 * RAD * math.cos(mid), 0.55 * RAD * math.sin(mid), -0.92 * RAD)
        hinge.rotation_euler = (0, 0, mid)
        ob = stage.link(sc, f"Wedge{k}", wedge(f"Wedge{k}", a0, a1), peel, pith, parent=hinge)
        ob.rotation_euler = (0, 0, -mid)
        ob.location = Matrix.Rotation(-mid, 3, "Z") @ -Vector(hinge.location)
        hinges.append(hinge)
        wedges.append(ob)
    crown = stage.link(sc, "Crown", crown_mesh("Crown"), peel, parent=wedges[0], loc=(0.0, 0.0, 0.97 * RAD))
    return root, hinges, wedges + [crown]


def animate(root, hinges):
    for f in range(1, TOTAL + 1):
        u = env(f, *ROLL)
        x = -6.5 * (1 - u)
        roll = -x / RAD                                          # rolling without slipping
        shiver = env(f, CRACK, BURST) * (1 - env(f, BURST, BURST + 2)) * math.sin(f * 2.4) * R(2.0)
        root.location = (x, 0.0, GROUND_Z + RAD * 0.97)
        root.rotation_euler = (0.0, roll * (1 - env(f, ROLL[1] - 4, ROLL[1] + 6)) + R(4) * math.sin(f * 0.5) * env(f, ROLL[1] - 6, ROLL[1]) * (1 - env(f, ROLL[1], ROLL[1] + 10)) + shiver, 0.0)
        root.keyframe_insert("location", frame=f)
        root.keyframe_insert("rotation_euler", frame=f)
    for k, h in enumerate(hinges):
        mid = h.rotation_euler.z
        for f, tilt in ((BURST - 1, 0.0), (BURST + 5, R(58)), (BURST + 9, R(50)), (BURST + 13, R(54))):
            h.rotation_euler = (0.0, tilt, mid)
            h.keyframe_insert("rotation_euler", frame=f)


def seeds(sc, root):
    """Packed inside the fruit (kinematic, riding with it) until the burst, then free rigid bodies."""
    stage.rigid_world(sc, TOTAL, substeps=12)
    floor = stage.link(sc, "Floor", stage.box_mesh("Floor", 40, 40, 0.2), loc=(0.0, 0.0, GROUND_Z - 0.1))
    floor.hide_render = True
    stage.rigid(sc, floor, kind="PASSIVE", shape="BOX", friction=0.8, bounce=0.35)
    shells = []
    mat, me = ruby(), seed_mesh()
    rng = stage.seeded(9)
    pts = []
    while len(pts) < SEEDS:
        p = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-0.85, 0.85))) * (0.72 * RAD)
        if p.length < 0.72 * RAD and all((p - q).length > 0.2 for q in pts):
            pts.append(p)
    bpy.context.view_layer.update()
    sc.frame_set(BURST)
    centre = root.matrix_world.to_translation()
    for i, p in enumerate(pts):
        ob = stage.link(sc, f"Seed{i}", me, loc=centre + p)
        if i == 0:
            me.materials.append(mat)
        ob.rotation_euler = (rng.uniform(0, 6.3), rng.uniform(0, 6.3), rng.uniform(0, 6.3))
        rb = stage.rigid(sc, ob, mass=0.05, shape="CONVEX_HULL", friction=0.6, bounce=0.45, kinematic=True)
        rb.keyframe_insert("kinematic", frame=BURST)
        rb.kinematic = False
        rb.keyframe_insert("kinematic", frame=BURST + 1)
        out = p.normalized()
        ob.hide_render = True
        ob.keyframe_insert("hide_render", frame=BURST - 1)
        ob.hide_render = False
        ob.keyframe_insert("hide_render", frame=BURST)
        shells.append((ob, out))
    bpy.ops.object.effector_add(type="FORCE", location=centre - Vector((0, 0, 0.6)))   # radial push at the burst
    fo = bpy.context.active_object
    fo.field.strength = 0.0
    fo.field.keyframe_insert("strength", frame=BURST)
    fo.field.strength = 60.0
    fo.field.keyframe_insert("strength", frame=BURST + 2)
    fo.field.strength = 0.0
    fo.field.keyframe_insert("strength", frame=BURST + 6)
    return [o for o, _ in shells]


def glints(sc):
    """Star glints that pop on random seeds after they settle."""
    rng = stage.seeded(3)
    for k in range(10):
        f = rng.randrange(50, 88)
        g = stage.link(sc, f"Glint{k}", gc.ico_mesh(f"Glint{k}", 0.03, 2), stage.emit(f"Glint{k}", (1.0, 0.92, 0.9), 0.0), shadow=False)
        g.location = (rng.uniform(-3.0, 3.0), rng.uniform(-1.5, 1.0), GROUND_Z + 0.2)
        stage.key_socket(g.data.materials[0].node_tree.nodes["Emission"].inputs["Strength"], [(f - 3, 0.0), (f, 80.0), (f + 4, 0.0)])


def dissolve(sc):
    """Fade peel, cut faces and seeds out together while a puff of ruby-gold sparkles rises."""
    for name in ("Peel", "Cut", "Ruby"):
        stage.key_socket(stage.bsdf(bpy.data.materials[name]).inputs["Alpha"], [(EXIT, 1.0), (TOTAL - 1, 0.0)])
    spark = fx.fade_material("Spark", (1.0, 0.62, 0.55), 8.0)
    burst = fx.particle_burst(sc, "Sparkle", fx.point_mesh("SparkSrc", 2.4), spark, 300, (EXIT, EXIT + 8), 18, 0.025, 0.9,
                              rand=1.0, align=(0.0, 0.0, 0.8), damping=0.3, gravity=-0.1, location=(0.0, 0.0, GROUND_Z + 0.8))
    burst.scale = (1.6, 0.6, 0.5)


def camera(cam):
    cam.location = (0.0, -gc.CAM_DIST * math.cos(ELEV), gc.CAM_DIST * math.sin(ELEV) - 1.4)
    cam.rotation_euler = (R(90) - ELEV, 0, 0)


def build_show(sc, opts):
    root, hinges, parts = build_fruit(sc)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.85, hdri="studio.exr", lights=0.8, fog=(2.0, 6), streak=10.0)
    sc.cycles.transparent_max_bounces = 64
    camera(cam)
    sh.shadow_catcher(sc, GROUND_Z, 40)
    animate(root, hinges)
    seeds(sc, root)
    glints(sc)
    dissolve(sc)
    sh.screen_extent(sc, cam, parts, (ROLL[1], BURST + 10, 70))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Fruit cracked open on a slow turntable, a few seeds in front, glints pulsing on the loop."""
    root, hinges, parts = build_fruit(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=0.85, hdri="studio.exr", lights=0.8, fog=(2.0, 6), streak=10.0)
    root.location = (0.0, 0.0, GROUND_Z + RAD * 0.97)
    for h in hinges:
        h.rotation_euler = (0.0, R(35), h.rotation_euler.z)
    n = stage.ICON_N
    for f in range(0, n + 1):
        root.rotation_euler = (0.0, 0.0, R(20) * math.sin(2 * math.pi * f / n))
        root.keyframe_insert("rotation_euler", frame=f)
    mat, me = ruby(), seed_mesh()
    me.materials.append(mat)
    rng = stage.seeded(5)
    for i in range(24):
        ob = stage.link(sc, f"Seed{i}", me, loc=(rng.uniform(-2.2, 2.2), rng.uniform(-1.8, -0.6), GROUND_Z + 0.1))
        ob.rotation_euler = (R(90), rng.uniform(0, 6.3), 0.0)
        parts.append(ob)
    sh.shadow_catcher(sc, GROUND_Z, 30)
    sc.frame_set(1)
    stage.frame_icon(cam, parts, pad=1.12)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
