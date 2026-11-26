"""UZARO v2 show: timurid_palace (tier 3, 156 f = 6.5 s).

A sea of golden cloud gathers; an original blue-dome palace rises through it: a tall tiled portal with a pointed arch,
two slim minarets on its corners, low arcaded wings, and a ribbed turquoise melon dome on a high drum behind. A wave of
light runs up the tile mosaic, fireworks burst overhead, and the palace sinks back as the clouds thin out.
Every part and pattern is built here from generic Timurid-style elements; the proportions copy no real building.
"""
import math
import os
import sys

import bmesh
import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import clouds  # noqa: E402
import show_common as sh  # noqa: E402
import spark_trails as st  # noqa: E402
import stage  # noqa: E402
from stage import R, interp  # noqa: E402

ID = "timurid_palace"
TOTAL = 156
BASE_Z = -3.3
PAL_SCALE = 0.8      # at 1.0 the palace alone spanned 0.08..0.86 of the width; with the cloud it covered 61.8 %
RISE = [(1, -13.5), (60, 0.0), (134, 0.0), (TOTAL, -13.5)]
WAVE = [(60, -3.8), (94, 5.8)]                       # light front height in root space (base -3.3, finial top 5.5)
GLOW = ((1.0, 0.8, 0.42), 0.45)
TURQ, COBALT, CREAM, GOLD = (0.0, 0.5, 0.55), (0.02, 0.09, 0.5), (0.92, 0.86, 0.7), (1.0, 0.72, 0.3)
SHELLS = ((96, (-2.4, 2.0, 5.6), (0.2, 0.85, 0.9), 3), (106, (2.5, 2.4, 5.0), (1.0, 0.72, 0.2), 5),
          (114, (0.2, 3.0, 6.3), (0.95, 0.3, 0.7), 8))   # last sparks gone before the final frame


def node(nt, kind, op=None, a=None, b=None):
    n = nt.nodes.new(kind)
    if op:
        n.operation = op
    if a is not None:
        n.inputs[0].default_value = a
    if b is not None:
        n.inputs[1].default_value = b
    return n


def tile_material(name, root, scale, base, star, line, wave_keys, steady=False, glaze=0.6):
    """Glazed mosaic: 8-point stars in a square grid with a cream outline ring. Coordinates are the root's object
    space projected on (x + 0.7 y, z), so every part shares one pattern. A wave value keyed upward lights the tiles;
    steady keeps the glow behind and ahead of the crest equal, so only the crest moves (seamless icon loop)."""
    m = stage.pbr(name, base, roughness=0.18, coat=glaze)
    nt = m.node_tree
    L = nt.links.new
    b = stage.bsdf(m)
    tc = nt.nodes.new("ShaderNodeTexCoord")
    tc.object = root
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    L(tc.outputs["Object"], sep.inputs[0])
    u = node(nt, "ShaderNodeMath", "MULTIPLY_ADD", b=0.7)          # x + 0.7 y
    L(sep.outputs["Y"], u.inputs[0])
    L(sep.outputs["X"], u.inputs[2])
    comb = nt.nodes.new("ShaderNodeCombineXYZ")
    L(u.outputs[0], comb.inputs["X"])
    L(sep.outputs["Z"], comb.inputs["Y"])
    sc_ = node(nt, "ShaderNodeVectorMath", "SCALE")
    sc_.inputs["Scale"].default_value = scale
    L(comb.outputs[0], sc_.inputs[0])
    fr = node(nt, "ShaderNodeVectorMath", "FRACTION")
    L(sc_.outputs[0], fr.inputs[0])
    cen = node(nt, "ShaderNodeVectorMath", "SUBTRACT")
    cen.inputs[1].default_value = (0.5, 0.5, 0.0)
    L(fr.outputs[0], cen.inputs[0])
    s2 = nt.nodes.new("ShaderNodeSeparateXYZ")
    L(cen.outputs[0], s2.inputs[0])
    ang = node(nt, "ShaderNodeMath", "ARCTAN2")
    L(s2.outputs["Y"], ang.inputs[0])
    L(s2.outputs["X"], ang.inputs[1])
    rad = node(nt, "ShaderNodeVectorMath", "LENGTH")
    L(cen.outputs[0], rad.inputs[0])
    a8 = node(nt, "ShaderNodeMath", "MULTIPLY", b=8.0)
    L(ang.outputs[0], a8.inputs[0])
    cs = node(nt, "ShaderNodeMath", "COSINE")
    L(a8.outputs[0], cs.inputs[0])
    edge = node(nt, "ShaderNodeMath", "MULTIPLY_ADD", b=0.07)       # star radius 0.24 +- 0.07 cos(8 a)
    edge.inputs[2].default_value = 0.24
    L(cs.outputs[0], edge.inputs[0])
    in_star = node(nt, "ShaderNodeMath", "LESS_THAN")
    L(rad.outputs["Value"], in_star.inputs[0])
    L(edge.outputs[0], in_star.inputs[1])
    ring_d = node(nt, "ShaderNodeMath", "SUBTRACT", b=0.42)
    L(rad.outputs["Value"], ring_d.inputs[0])
    ring_a = node(nt, "ShaderNodeMath", "ABSOLUTE")
    L(ring_d.outputs[0], ring_a.inputs[0])
    ring = node(nt, "ShaderNodeMath", "LESS_THAN", b=0.035)
    L(ring_a.outputs[0], ring.inputs[0])
    c1 = nt.nodes.new("ShaderNodeMixRGB")
    c1.inputs["Color1"].default_value, c1.inputs["Color2"].default_value = (*base, 1), (*star, 1)
    L(in_star.outputs[0], c1.inputs["Fac"])
    c2 = nt.nodes.new("ShaderNodeMixRGB")
    c2.inputs["Color2"].default_value = (*line, 1)
    L(c1.outputs["Color"], c2.inputs["Color1"])
    L(ring.outputs[0], c2.inputs["Fac"])
    L(c2.outputs["Color"], b.inputs["Base Color"])
    L(c2.outputs["Color"], b.inputs["Emission Color"])
    # light wave: a bright crest at the front, a steady glow behind it
    wave = nt.nodes.new("ShaderNodeValue")
    wave.name = "Wave"
    stage.key_socket(wave.outputs[0], wave_keys, "LINEAR" if steady else None)
    d = node(nt, "ShaderNodeMath", "SUBTRACT")
    L(wave.outputs[0], d.inputs[0])
    L(sep.outputs["Z"], d.inputs[1])
    behind = nt.nodes.new("ShaderNodeMapRange")
    behind.inputs["From Min"].default_value, behind.inputs["From Max"].default_value = 0.0, 0.25
    behind.inputs["To Min"].default_value, behind.inputs["To Max"].default_value = 0.7 if steady else 0.0, 0.7
    L(d.outputs[0], behind.inputs["Value"])
    crest_a = node(nt, "ShaderNodeMath", "ABSOLUTE")
    L(d.outputs[0], crest_a.inputs[0])
    crest = nt.nodes.new("ShaderNodeMapRange")
    crest.inputs["From Min"].default_value, crest.inputs["From Max"].default_value = 0.0, 0.5
    crest.inputs["To Min"].default_value, crest.inputs["To Max"].default_value = 3.0, 0.0
    L(crest_a.outputs[0], crest.inputs["Value"])
    tot = node(nt, "ShaderNodeMath", "ADD")
    L(behind.outputs["Result"], tot.inputs[0])
    L(crest.outputs["Result"], tot.inputs[1])
    L(tot.outputs[0], b.inputs["Emission Strength"])
    return m


def arch_outline(w, h, spring, n=12):
    """Pointed (two-centred) arch, base centred at the origin, in XZ: sides rise to `spring`, arcs meet at h."""
    rise = h - spring
    half = w / 2
    # each arc: centre on the spring line at x = +-c, radius r, through (-+half, spring) and (0, h)
    c = (rise ** 2 - half ** 2) / (2 * half)
    r = half + c
    left = []
    for i in range(n + 1):
        a0, a1 = math.pi, math.atan2(rise, -c)              # left spring point, apex (seen from the arc centre)
        a = a0 + (a1 - a0) * i / n
        left.append((c + r * math.cos(a), spring + r * math.sin(a)))
    right = [(-x, z) for x, z in reversed(left[:-1])]
    return [(-half, 0.0)] + left + right + [(half, 0.0)]


def prism(name, outline, depth):
    """Extrude an XZ outline along Y, front face at y = 0, back at y = depth."""
    bm = bmesh.new()
    front = [bm.verts.new((x, 0.0, z)) for x, z in outline]
    back = [bm.verts.new((x, depth, z)) for x, z in outline]
    bm.faces.new(list(reversed(front)))
    bm.faces.new(back)
    n = len(outline)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((front[i], front[j], back[j], back[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return me


def ribbed_dome(name, radius, height, ribs=24, rows=40, segs=192):
    """Melon dome: swells past the drum, tapers to a point; each rib is a rounded lobe that fades toward the tip."""
    verts, faces = [], []
    for j in range(rows + 1):
        t = j / rows
        prof = radius * (1.0 + 0.16 * math.sin(math.pi * min(t / 0.7, 1.0))) * (1.0 - t ** 2.2) ** 0.75
        lobe = 0.07 * (1.0 - t ** 3)
        for i in range(segs):
            a = 2 * math.pi * i / segs
            rr = prof * (1.0 + lobe * (abs(math.cos(ribs / 2 * a)) ** 0.6 - 0.5))
            verts.append((rr * math.cos(a), rr * math.sin(a), height * t))
    for j in range(rows):
        for i in range(segs):
            k = (i + 1) % segs
            faces.append((j * segs + i, j * segs + k, (j + 1) * segs + k, (j + 1) * segs + i))
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    bmesh_me = bmesh.new()
    bmesh_me.from_mesh(me)
    bmesh.ops.remove_doubles(bmesh_me, verts=bmesh_me.verts, dist=1e-5)
    bmesh_me.to_mesh(me)
    bmesh_me.free()
    return me


def build(sc, wave_keys, steady=False):
    root = bpy.data.objects.new("Palace", None)
    sc.collection.objects.link(root)
    mats = {
        "portal": tile_material("PortalTile", root, 3.0, COBALT, TURQ, CREAM, wave_keys, steady),
        "wall": tile_material("WallTile", root, 2.2, (0.78, 0.62, 0.42), TURQ, COBALT, wave_keys, steady, glaze=0.2),
        "minaret": tile_material("MinaretTile", root, 4.0, TURQ, COBALT, CREAM, wave_keys, steady),
        "drum": tile_material("DrumTile", root, 3.4, COBALT, TURQ, GOLD, wave_keys, steady),
    }
    dome = stage.pbr("Dome", (0.02, 0.55, 0.62), roughness=0.12, coat=0.9)
    gold = stage.pbr("Gold", GOLD, metallic=1.0, roughness=0.2)
    niche = stage.pbr("Niche", (0.01, 0.03, 0.12), roughness=0.6, emission=(1.0, 0.62, 0.28), strength=1.6)
    if not steady:
        stage.key_socket(stage.bsdf(niche).inputs["Emission Strength"], [(60, 0.0), (80, 1.6), (TOTAL, 1.6)])
    meshes = []

    def add(name, me, mat, loc, rot=None):
        ob = stage.link(sc, name, me, mat, parent=root, loc=loc)
        if rot:
            ob.rotation_euler = rot
        meshes.append(ob)
        return ob

    z0 = BASE_Z
    add("Plinth", stage.box_mesh("Plinth", 6.6, 3.6, 0.5), mats["wall"], (0, 1.2, z0 + 0.25))
    add("Portal", stage.box_mesh("Portal", 3.1, 0.9, 5.3), mats["portal"], (0, 0, z0 + 0.5 + 2.65))
    add("PortalFrame", prism("PortalFrame", arch_outline(2.1, 4.1, 2.7), 0.06), gold, (0, -0.48, z0 + 0.5))
    add("PortalNiche", prism("PortalNiche", arch_outline(1.9, 3.9, 2.6), 0.05), niche, (0, -0.5, z0 + 0.6))
    add("Door", prism("Door", arch_outline(0.7, 1.4, 0.95), 0.03), gold, (0, -0.53, z0 + 0.5))
    for sx in (-1, 1):
        add(f"Wing{sx}", stage.box_mesh(f"Wing{sx}", 1.25, 2.2, 2.6), mats["wall"], (sx * 2.3, 0.75, z0 + 0.5 + 1.3))
        for row, zz in enumerate((0.25, 1.4)):
            for col, xx in enumerate((2.27, 2.7)):
                add(f"Arch{sx}{row}{col}", prism("Arch", arch_outline(0.36, 0.95, 0.64), 0.04), niche,
                    (sx * xx, -0.37, z0 + 0.5 + zz))
        add(f"Minaret{sx}", stage.lathe(f"Minaret{sx}", [(0.0, 0.0), (0.33, 0.0), (0.27, 6.4), (0.0, 6.4)], 48),
            mats["minaret"], (sx * 1.72, -0.3, z0 + 0.5))
        add(f"Balcony{sx}", stage.lathe(f"Balcony{sx}", [(0.0, 0.0), (0.28, 0.0), (0.42, 0.18), (0.42, 0.26), (0.0, 0.26)], 48),
            gold, (sx * 1.72, -0.3, z0 + 0.5 + 5.6))
        add(f"Lantern{sx}", stage.lathe(f"Lantern{sx}", [(0.0, 0.0), (0.24, 0.0), (0.24, 0.42), (0.0, 0.42)], 32),
            niche, (sx * 1.72, -0.3, z0 + 0.5 + 6.4))
        add(f"MinDome{sx}", ribbed_dome(f"MinDome{sx}", 0.27, 0.55, ribs=12, rows=16, segs=96), dome,
            (sx * 1.72, -0.3, z0 + 0.5 + 6.82))
        for k, h in enumerate((1.6, 3.2, 4.8)):
            add(f"Band{sx}{k}", stage.lathe("Band", [(0.0, 0.0), (0.335 - 0.0094 * h, 0.0), (0.335 - 0.0094 * h, 0.09), (0.0, 0.09)], 48),
                gold, (sx * 1.72, -0.3, z0 + 0.5 + h))
    drum_z = z0 + 0.5 + 3.2
    add("Drum", stage.lathe("Drum", [(0.0, 0.0), (1.25, 0.0), (1.25, 1.9), (0.0, 1.9)], 96), mats["drum"], (0, 1.7, drum_z))
    add("DrumBand", stage.lathe("DrumBand", [(0.0, 0.0), (1.29, 0.0), (1.29, 0.14), (0.0, 0.14)], 96), gold, (0, 1.7, drum_z + 1.85))
    add("Dome", ribbed_dome("Dome", 1.3, 2.3), dome, (0, 1.7, drum_z + 1.98))
    add("Finial", stage.lathe("Finial", [(0.0, 0.0), (0.09, 0.0), (0.16, 0.18), (0.09, 0.34), (0.03, 0.4), (0.03, 0.75), (0.0, 0.8)], 32),
        gold, (0, 1.7, drum_z + 1.98 + 2.25))
    return root, meshes


def sea(sc, fade=None):
    half = (3.6 * PAL_SCALE, 4.2, 2.6 * PAL_SCALE)    # 5.0 wide ran off both sides of the frame
    mat = clouds.layer("GoldSea", half, rgb=(1.0, 0.84, 0.55), density=5.0, fade=fade, glow=GLOW,
                       drift=[(1, (0.0, 0.0, 0.0)), (TOTAL, (0.6, 0.2, 0.12))] if fade else None)
    return clouds.cloud(sc, "GoldSea", (0.0, -0.4, (BASE_Z - 1.6) * PAL_SCALE + 0.6), half, mat)   # +0.6 keeps the base sunk in it


def clip_below(meshes, z):
    """Hide whatever of the palace is below world height z (inside the cloud), so it seems to rise out of the cloud and
    sink back into it: the narrower cloud no longer fills the bottom of the frame to hide it."""
    done = set()
    for o in meshes:
        for mat in o.data.materials:
            if not mat or not mat.use_nodes or mat.name in done:
                continue
            nt = mat.node_tree
            out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL" and n.is_active_output)
            shader = out.inputs["Surface"].links[0].from_socket
            geo, sep, gt = nt.nodes.new("ShaderNodeNewGeometry"), nt.nodes.new("ShaderNodeSeparateXYZ"), nt.nodes.new("ShaderNodeMath")
            tr, mix = nt.nodes.new("ShaderNodeBsdfTransparent"), nt.nodes.new("ShaderNodeMixShader")
            gt.operation = "GREATER_THAN"
            gt.inputs[1].default_value = z
            nt.links.new(geo.outputs["Position"], sep.inputs[0])
            nt.links.new(sep.outputs["Z"], gt.inputs[0])
            nt.links.new(gt.outputs[0], mix.inputs[0])
            nt.links.new(tr.outputs[0], mix.inputs[1])
            nt.links.new(shader, mix.inputs[2])
            nt.links.new(mix.outputs[0], out.inputs["Surface"])
            done.add(mat.name)


def build_show(sc, opts):
    root, meshes = build(sc, WAVE)
    root.scale = (PAL_SCALE,) * 3
    clip_below(meshes, (BASE_Z - 1.6) * PAL_SCALE + 0.6)       # the cloud's centre height
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.7, hdri="sunset.exr", lights=0.75, fog=(1.9, 6), streak=8.0)
    sc.view_settings.view_transform, sc.view_settings.look = "Filmic", "Medium High Contrast"
    sc.cycles.transparent_max_bounces = 128
    stage.key_path(root, range(1, TOTAL + 1), lambda f: (0.0, 0.0, interp(RISE, f)))
    sea(sc, fade=[(1, 0.0), (22, 1.0), (140, 1.0), (TOTAL, 0.0)])
    for f, at, rgb, seed in SHELLS:
        st.shell(sc, f"Shell{f}", f, at, (at[0] * 0.3, at[1], -1.0), f - 12, rgb, TOTAL, count=170, speed=5.5, seed=seed, trail=9, life=18)
    sh.screen_extent(sc, cam, meshes, (40, 60, 100, 134))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """The light wave climbs the palace once per loop: it starts below the base and ends above the finial, so the loop
    closes on the steady glow."""
    n = stage.ICON_N
    root, meshes = build(sc, [(0, -4.8), (n, 6.8)], steady=True)
    cam = stage.setup_icon(sc, opts["samples"], world=0.7, hdri="sunset.exr", lights=0.75, fog=(1.9, 6), streak=8.0)
    sc.view_settings.view_transform, sc.view_settings.look = "Filmic", "Medium High Contrast"
    sc.cycles.transparent_max_bounces = 128
    stage.frame_icon(cam, meshes, pad=1.08)
    sea(sc)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
