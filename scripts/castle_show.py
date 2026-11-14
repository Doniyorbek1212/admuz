"""UZARO v2 show: castle (tier 3, 156 f = 6.5 s).

A sea of cloud gathers; a fairytale castle rises through it, windows light up one by one, cloth flags stream from the
towers, fireworks burst overhead; it sinks back as the clouds thin out. The source scene carries the castle on a giant
turtle: everything below the rock is cut away, cloud hides the cut, none of the turtle is left in frame.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import autorig  # noqa: E402
import clouds  # noqa: E402
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import spark_trails as st  # noqa: E402
import stage  # noqa: E402
from stage import R, interp  # noqa: E402

ID = "castle"
CLIP_Z = -2.2
GLOW = ((1.0, 0.97, 0.93), 0.3)
TOTAL = 156
SIZE = 8.0
SCALE = 1.45
HIDE = ("Skybox", "Outside", "Clouds", "Spells", "Trail", "Birds", "CastleTrurtleOutline", "TreesOutlines", "Cube", "Glass_", "WingsTrail")
CUT_Z = -0.9
RISE = [(1, -13.0), (58, -1.3), (136, -1.3), (TOTAL, -13.0)]
# x, z in the file at SIZE, read from the front view; y comes from a ray onto the wall
WINDOWS = ((-1.1, 1.25), (-0.85, 1.25), (-0.6, 1.2), (-1.1, 0.95), (-0.7, 0.95), (-0.35, 0.95), (0.1, 2.05), (0.3, 2.05), (0.5, 2.05),
           (0.2, 1.6), (0.4, 1.6), (0.3, 1.2), (1.25, 1.0), (1.45, 1.0), (1.2, 0.6), (1.4, 0.6), (1.7, 0.85), (1.75, 0.55))
FLAGS = (((0.3, -0.95, 2.62), 0.55), ((1.37, 0.3, 1.97), 0.42))
LIGHT_FROM = 58
SHELLS = ((88, (-1.7, 1.0, 5.2), (1.0, 0.55, 0.15), 5), (102, (1.8, 1.5, 4.6), (0.3, 0.55, 1.0), 6), (114, (-0.3, 2.0, 5.7), (1.0, 0.25, 0.5), 7), (124, (2.1, 1.0, 3.6), (0.5, 1.0, 0.4), 8))


def trim(meshes):
    """Delete all below the rock in world space: the turtle, its shell and its legs."""
    autorig.bake_world(meshes)
    kept = []
    for o in meshes:
        bm = bmesh.new()
        bm.from_mesh(o.data)
        doomed = [v for v in bm.verts if v.co.z < CUT_Z * SCALE or v.co.x < -2.6 * SCALE]
        bmesh.ops.delete(bm, geom=doomed, context="VERTS")
        bm.to_mesh(o.data)
        bm.free()
        if len(o.data.vertices):
            kept.append(o)
        else:
            o.hide_render = True
    return kept


def masonry():
    """The file has no textures: stone walls, slate roofs, grey rock with moss, all from height and surface slope."""
    m = bpy.data.materials.new("Masonry")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out, b, tc, geo, sep, nsep, noise = N("ShaderNodeOutputMaterial"), N("ShaderNodeBsdfPrincipled"), N("ShaderNodeTexCoord"), N("ShaderNodeNewGeometry"), N("ShaderNodeSeparateXYZ"), N("ShaderNodeSeparateXYZ"), N("ShaderNodeTexNoise")
    L(tc.outputs["Object"], sep.inputs[0])
    L(geo.outputs["Normal"], nsep.inputs[0])
    noise.inputs["Scale"].default_value, noise.inputs["Detail"].default_value = 9.0, 7.0
    L(tc.outputs["Object"], noise.inputs["Vector"])

    def step(sock, lo, hi):
        r = N("ShaderNodeMapRange")
        r.interpolation_type = "SMOOTHSTEP"
        r.inputs["From Min"].default_value, r.inputs["From Max"].default_value = lo, hi
        L(sock, r.inputs["Value"])
        return r.outputs[0]

    def mix(fac, a, c):
        n = N("ShaderNodeMix")
        n.data_type = "RGBA"
        L(fac, n.inputs["Factor"])
        for slot, v in (("A", a), ("B", c)):
            if isinstance(v, tuple):
                n.inputs[slot].default_value = (*v, 1.0)
            else:
                L(v, n.inputs[slot])
        return n.outputs["Result"]

    def times(p, q):
        n = N("ShaderNodeMath")
        n.operation = "MULTIPLY"
        L(p, n.inputs[0])
        L(q, n.inputs[1])
        return n.outputs[0]

    stone = mix(step(noise.outputs["Fac"], 0.4, 0.6), (0.5, 0.42, 0.32), (0.68, 0.6, 0.47))
    rock = mix(step(noise.outputs["Fac"], 0.38, 0.62), (0.13, 0.11, 0.1), (0.3, 0.27, 0.24))
    moss = mix(step(nsep.outputs["Z"], 0.55, 0.8), rock, (0.09, 0.2, 0.04))
    roof_mask = times(step(nsep.outputs["Z"], 0.3, 0.45), step(sep.outputs["Z"], 1.0 * SCALE, 1.08 * SCALE))
    cone_mask = step(sep.outputs["Z"], 2.3 * SCALE, 2.34 * SCALE)
    wall = mix(roof_mask, stone, (0.06, 0.09, 0.2))
    wall = mix(cone_mask, wall, (0.06, 0.09, 0.2))
    rock_mask = step(sep.outputs["Z"], 0.82 * SCALE, 0.74 * SCALE)
    L(mix(rock_mask, wall, moss), b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = 0.8
    L(b.outputs[0], out.inputs["Surface"])
    return m


def foliage():
    """Trees and jetty: upward-facing blobs are leaves, near-vertical surfaces are bark and timber."""
    m = bpy.data.materials.new("Foliage")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out, b, geo, sep, r, noise, ramp = N("ShaderNodeOutputMaterial"), N("ShaderNodeBsdfPrincipled"), N("ShaderNodeNewGeometry"), N("ShaderNodeSeparateXYZ"), N("ShaderNodeMapRange"), N("ShaderNodeTexNoise"), N("ShaderNodeValToRGB")
    L(geo.outputs["Normal"], sep.inputs[0])
    ab = N("ShaderNodeMath")
    ab.operation = "ABSOLUTE"
    L(sep.outputs["Z"], ab.inputs[0])
    r.interpolation_type = "SMOOTHSTEP"
    r.inputs["From Min"].default_value, r.inputs["From Max"].default_value = 0.12, 0.3
    L(ab.outputs[0], r.inputs["Value"])
    noise.inputs["Scale"].default_value = 22.0
    L(geo.outputs["Position"], noise.inputs["Vector"])
    els = ramp.color_ramp.elements
    els[0].position, els[0].color = 0.38, (0.03, 0.1, 0.02, 1)
    els[1].position, els[1].color = 0.62, (0.16, 0.3, 0.05, 1)
    L(noise.outputs["Fac"], ramp.inputs["Fac"])
    mx = N("ShaderNodeMix")
    mx.data_type = "RGBA"
    mx.inputs["A"].default_value = (0.09, 0.05, 0.025, 1)
    L(ramp.outputs["Color"], mx.inputs["B"])
    L(r.outputs["Result"], mx.inputs["Factor"])
    L(mx.outputs["Result"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = 0.75
    L(b.outputs[0], out.inputs["Surface"])
    return m


def clip_below(m, z=CLIP_Z):
    """Nothing shows under the cloud layer: while rising, the castle would otherwise hang below the clouds."""
    nt = m.node_tree
    N, L = nt.nodes.new, nt.links.new
    out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL")
    surface = out.inputs["Surface"].links[0].from_socket
    geo, sep, edge, tr, mix = N("ShaderNodeNewGeometry"), N("ShaderNodeSeparateXYZ"), N("ShaderNodeMapRange"), N("ShaderNodeBsdfTransparent"), N("ShaderNodeMixShader")
    L(geo.outputs["Position"], sep.inputs[0])
    edge.interpolation_type = "SMOOTHSTEP"
    edge.inputs["From Min"].default_value, edge.inputs["From Max"].default_value = z - 0.4, z
    L(sep.outputs["Z"], edge.inputs["Value"])
    L(edge.outputs["Result"], mix.inputs[0])
    L(tr.outputs[0], mix.inputs[1])
    L(surface, mix.inputs[2])
    L(mix.outputs[0], out.inputs["Surface"])
    return m


def load(sc):
    root, model, objs, meshes = stage.load(ID, SIZE * SCALE, hide=HIDE)
    meshes = trim(meshes)
    stone, leaves = clip_below(masonry()), clip_below(foliage())
    for o in meshes:
        o.data.materials.clear()
        o.data.materials.append(leaves if o.name.startswith("Attachments") else stone)
        o.parent = root
    return root, meshes


def wall_points():
    """Project each window from the front onto whatever wall is there."""
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    out = []
    for x, z in WINDOWS:
        hit, loc, nor, *_ = bpy.context.scene.ray_cast(dg, Vector((x * SCALE, -30.0, z * SCALE)), Vector((0, 1, 0)))
        if hit:
            out.append((loc, nor))
    print("INFO_WINDOWS", len(out), "of", len(WINDOWS))
    return out


def window_mesh(name, loc, nor, w=0.09, h=0.17):
    side = Vector((0, 0, 1)).cross(nor).normalized()
    up = nor.cross(side).normalized()
    c = loc + nor * 0.012
    outline = [(-1, -1), (1, -1), (1, 0.45), (0.5, 0.85), (0, 1), (-0.5, 0.85), (-1, 0.45)]   # arched
    me = bpy.data.meshes.new(name)
    me.from_pydata([c + side * (a * w * SCALE / 2) + up * (b * h * SCALE / 2) for a, b in outline], [], [tuple(range(len(outline)))])
    return me


def windows(sc, root, points, start=LIGHT_FROM):
    rnd = stage.seeded(4)
    order = list(range(len(points)))
    rnd.shuffle(order)
    for rank, i in enumerate(order):
        loc, nor = points[i]
        mat = clip_below(stage.emit(f"Win{i}", (1.0, 0.68, 0.28), 0.0))
        sock = mat.node_tree.nodes["Emission"].inputs["Strength"]
        on = start + rank * 1.6
        stage.key_socket(sock, [(int(on), 0.0), (int(on) + 2, 9.0), (int(on) + 6, 5.5), (TOTAL, 5.5)])
        stage.link(sc, f"Win{i}", window_mesh(f"Win{i}", loc, nor), mat, parent=root, shadow=False)


def sea(sc):
    """Overlapping cloud banks around the base; nearer ones hide the cut. All fade in and out over the first and last frames."""
    fade = [(1, 0.0), (22, 1.0), (140, 1.0), (TOTAL, 0.0)]
    half = (4.3, 4.0, 2.6)
    mat = clouds.layer("Sea", half, density=5.0, fade=fade, glow=GLOW, drift=[(1, (0.0, 0.0, 0.0)), (TOTAL, (0.5, 0.2, 0.15))])
    clouds.cloud(sc, "Sea", (0.0, -0.6, -2.7), half, mat)


def build_show(sc, opts):
    root, meshes = load(sc)
    points = wall_points()
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.7, hdri="sunrise.exr", follow=None, lights=0.7, fog=(1.9, 6), streak=8.0)
    sc.view_settings.view_transform, sc.view_settings.look = "Filmic", "Medium High Contrast"
    sc.cycles.transparent_max_bounces = 128
    windows(sc, root, points)
    for (at, base_w) in FLAGS:
        flag = stage.flag(sc, f"Flag{base_w}", root, Vector(at) * SCALE, base_w * SCALE, base_w * 0.55 * SCALE, (0.7, 0.03, 0.05), TOTAL)
        for frame, hidden in ((1, True), (34, False), (150, True)):     # flags clear the cloud layer between these
            flag.hide_render = hidden
            flag.keyframe_insert("hide_render", frame=frame)
    stage.wind(strength=6.0, location=(-5.0, 0.0, 3.0), rotation=(0, R(90), 0))
    stage.key_path(root, range(1, TOTAL + 1), lambda f: (0.0, 0.0, interp(RISE, f)))
    sea(sc)
    for f, at, rgb, seed in SHELLS:
        st.shell(sc, f"Shell{f}", f, at, (at[0] * 0.3, at[1], -1.0), f - 12, rgb, TOTAL, count=170, speed=5.5, seed=seed, trail=9, life=22)
    sh.screen_extent(sc, cam, meshes, (1, 58, 130))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Castle at night: windows breathe on the loop, flags omitted for a cleaner tiny silhouette."""
    root, meshes = load(sc)
    points = wall_points()
    cam = stage.setup_icon(sc, opts["samples"], world=0.7, hdri="sunrise.exr", lights=0.7, fog=(1.9, 6), streak=8.0)
    sc.view_settings.view_transform, sc.view_settings.look = "Filmic", "Medium High Contrast"
    n = stage.ICON_N
    for i, (loc, nor) in enumerate(points):
        mat = stage.emit(f"Win{i}", (1.0, 0.68, 0.28), 5.0)
        sock = mat.node_tree.nodes["Emission"].inputs["Strength"]
        stage.key_socket(sock, [(f, 3.5 + 3.0 * math.sin(2 * math.pi * f / n + i * 2.1) ** 2) for f in range(0, n + 1, 2)])
        stage.link(sc, f"Win{i}", window_mesh(f"Win{i}", loc, nor), mat, parent=root, shadow=False)
    stage.frame_icon(cam, meshes, pad=1.08)
    half = (3.3, 3.0, 1.5)
    clouds.cloud(sc, "Sea", (0, -1.0, CUT_Z * SCALE - 0.1), half, clouds.layer("Sea", half, density=5.0, glow=GLOW))
    _ = gc


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
