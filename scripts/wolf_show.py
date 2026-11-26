"""UZARO v2 show: wolf (tier 2, 120 f = 5 s).

Model: "Grey Wolf Rebuilt" by kenchoo (CC BY), from "Grey Wolf" by all of life (CC BY): a textured, rigged wolf with one
idle take (breathing and blink shape keys, a long look down to sniff the ground). It has no jaw bone, so the howl's
open mouth is a shape key of our own: the lower lip, lower gum, lower teeth and tongue turned about the jaw hinge.
Show: the wolf comes out of the night mist, sniffs the ground, lifts its muzzle to the sky and howls while a pale
moon blooms behind it; then wolf and moon fade back into the dark. The howl is hand keys combined on top of the take.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector
from mathutils.kdtree import KDTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import clipshow as cs  # noqa: E402
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import stage  # noqa: E402
from stage import R  # noqa: E402

ID = "wolf"
MODEL = "wolf_kenchoo"
TOTAL = 120
SIZE = 6.0
GROUND_Z = -3.2
YAW = R(58)                                    # nose (-Y in the file) turned right and a little toward the lens
IDLE = "Animation_GLTF_created_0"
SNIFF = (181, 262)                             # take frames: head down to the ground (~190-220) and back up
REST = (0, 60)
APPEAR = (1, 18)
HOWL = (58, 104)                               # matches the howl in wolf.mp3
FADE = (104, TOTAL - 1)
MOON = (0.85, 0.9, 1.0)
MOON_AT = (0.9, 9.0, 1.7)
NECK = ("Neck1_13", "Neck2_12", "Neck3_11")
HEAD = "Head_2"
EARS = ("Ear1.L_6", "Ear1.R_10")
# jaw, in the file's mesh units (the importer's nodes scale the mesh by 0.625: values measured in the scene / 0.625)
U = 1 / 0.625
HINGE_Y, HINGE_Z = -1.36 * U, 1.25 * U         # behind the mouth corner, under the eye
LIP = ((-1.434 * U, 1.224 * U), (-1.62 * U, 1.194 * U))    # mouth corner and front of the slit (y, z)
JAW_BACK = (-1.33 * U, -1.40 * U)              # skin blends from the head (first y) to the jaw (second y)
MOUTH_BOX = (-1.34 * U, 1.15 * U, 1.30 * U, 0.09 * U)       # y below, z between, |x| below: teeth, gums, tongue
JAW_DEG = 24.0


def smooth(a, b, x):
    t = min(1.0, max(0.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


def lip_z(y):
    (y0, z0), (y1, z1) = LIP
    return z0 if y > y0 else z0 + (z1 - z0) * (y - y0) / (y1 - y0)


def islands(bm):
    seen, out = set(), []
    for v in bm.verts:
        if v.index in seen:
            continue
        stack, ids = [v], []
        seen.add(v.index)
        while stack:
            x = stack.pop()
            ids.append(x.index)
            for e in x.link_edges:
                o = e.other_vert(x)
                if o.index not in seen:
                    seen.add(o.index)
                    stack.append(o)
        out.append(ids)
    return out


def jaw_weights(me):
    """{vertex: weight} of the lower jaw: skin below the lip line in front of the hinge, and the mouth parts that sit
    on the lower gum (lower teeth, tongue), found by which gum they are nearer."""
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.verts.ensure_lookup_table()
    co = [v.co.copy() for v in bm.verts]
    y_max, z_lo, z_hi, x_max = MOUTH_BOX
    mouth, skin = [], []
    for ids in islands(bm):
        pts = [co[i] for i in ids]
        inside = all(p.y < y_max and z_lo < p.z < z_hi and abs(p.x) < x_max for p in pts)
        (mouth if inside else skin).append(ids)
    bm.free()
    gums = sorted(mouth, key=len)[-2:]
    lower, upper = sorted(gums, key=lambda ids: sum(co[i].z for i in ids) / len(ids))
    trees = []
    for gum in (lower, upper):
        t = KDTree(len(gum))
        for i in gum:
            t.insert(co[i], i)
        t.balance()
        trees.append(t)
    w = {i: 1.0 for i in lower}
    for ids in mouth:
        if ids is lower or ids is upper:
            continue
        d_low = sorted(trees[0].find(co[i])[2] for i in ids)[len(ids) // 2]
        d_up = sorted(trees[1].find(co[i])[2] for i in ids)[len(ids) // 2]
        if d_low < d_up:
            w.update({i: 1.0 for i in ids})
    band = 0.004 * U
    for ids in skin:
        for i in ids:
            p = co[i]
            wy = smooth(-JAW_BACK[0], -JAW_BACK[1], -p.y)
            wz = smooth(lip_z(p.y) + band, lip_z(p.y) - band, p.z)
            if wy * wz > 0.0:
                w[i] = wy * wz
    return w


def add_jaw_key(mesh):
    """Shape key JawOpen: the lower jaw turned JAW_DEG down about the hinge (an axis along X)."""
    me = mesh.data
    if not me.shape_keys:
        mesh.shape_key_add(name="Basis")
    key = mesh.shape_key_add(name="JawOpen", from_mix=False)
    pivot = Vector((0.0, HINGE_Y, HINGE_Z))
    for i, wt in jaw_weights(me).items():
        rot = Matrix.Rotation(R(JAW_DEG * wt), 3, "X")
        key.data[i].co = pivot + rot @ (me.shape_keys.reference_key.data[i].co - pivot)
    return key


def load():
    root, arm, meshes = cs.load(MODEL, SIZE)
    body = max(meshes, key=lambda m: len(m.data.vertices))
    add_jaw_key(body)
    return root, arm, meshes, body


def key_jaw(body, items):
    """Key JawOpen on the shape keys' own action (the take's breathing and blink keys live there too)."""
    sk = body.data.shape_keys
    ad = sk.animation_data or sk.animation_data_create()
    if ad.action is None:
        ad.action = next((a for a in bpy.data.actions if a.name.startswith("Animation_mesh")), None) or bpy.data.actions.new("Keys")
    kb = sk.key_blocks["JawOpen"]
    for f, v in items:
        kb.value = v
        kb.keyframe_insert("value", frame=f)


def howl_keys(a, b):
    """Muzzle up to the sky (spread over the neck and head), ears laid back a little; held while the note lasts."""
    def ramp(deg, lag=0):
        return [(a + lag, "X", 0.0), (a + 10 + lag, "X", deg * 0.85), (b - 10, "X", deg), (b, "X", 0.0)]
    keys = {NECK[0]: ramp(14.0), NECK[1]: ramp(16.0, 1), NECK[2]: ramp(20.0, 2), HEAD: ramp(26.0, 3)}
    for e in EARS:
        keys[e] = [(a + 4, "X", 0.0), (a + 12, "X", -14.0), (b - 8, "X", -14.0), (b, "X", 0.0)]
    return keys


def jaw_items(a, b):
    return [(a + 6, 0.0), (a + 14, 0.75), (a + 24, 1.0), (b - 14, 0.9), (b - 4, 0.0)]


def moon_material(vis_keys):
    """Full moon face: pale emission with darker grey-blue maria from noise, faded by a keyed visibility."""
    m = bpy.data.materials.new("MoonFace")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out, em, tr, mix = N("ShaderNodeOutputMaterial"), N("ShaderNodeEmission"), N("ShaderNodeBsdfTransparent"), N("ShaderNodeMixShader")
    tc, noise, ramp = N("ShaderNodeTexCoord"), N("ShaderNodeTexNoise"), N("ShaderNodeValToRGB")
    noise.inputs["Scale"].default_value, noise.inputs["Detail"].default_value = 2.4, 8.0
    L(tc.outputs["Object"], noise.inputs["Vector"])
    e = ramp.color_ramp.elements
    e[0].position, e[0].color = 0.42, (0.5, 0.55, 0.66, 1)
    e[1].position, e[1].color = 0.6, (*MOON, 1)
    L(noise.outputs["Fac"], ramp.inputs["Fac"])
    L(ramp.outputs["Color"], em.inputs["Color"])
    em.inputs["Strength"].default_value = 0.8
    stage.key_socket(mix.inputs[0], vis_keys)
    L(tr.outputs[0], mix.inputs[1])
    L(em.outputs[0], mix.inputs[2])
    L(mix.outputs[0], out.inputs["Surface"])
    return m


def halo_material():
    """Soft radial glow on a flat disc: bright at the moon's rim, fading to nothing well inside the disc's edge."""
    m = bpy.data.materials.new("MoonHalo")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out, em, tr, mix = N("ShaderNodeOutputMaterial"), N("ShaderNodeEmission"), N("ShaderNodeBsdfTransparent"), N("ShaderNodeMixShader")
    tc, ln, ramp = N("ShaderNodeTexCoord"), N("ShaderNodeVectorMath"), N("ShaderNodeValToRGB")
    ln.operation = "LENGTH"
    L(tc.outputs["Object"], ln.inputs[0])
    L(ln.outputs["Value"], ramp.inputs["Fac"])
    e = ramp.color_ramp.elements
    e[0].position, e[0].color = 0.5, (0.45, 0.45, 0.45, 1)       # the disc's x/z radius is 1; moon rim sits at ~0.55
    e[1].position, e[1].color = 0.85, (0, 0, 0, 1)
    em.inputs["Color"].default_value = (*MOON, 1)
    em.inputs["Strength"].default_value = 1.0
    L(ramp.outputs["Color"], mix.inputs[0])
    L(tr.outputs[0], mix.inputs[1])
    L(em.outputs[0], mix.inputs[2])
    L(mix.outputs[0], out.inputs["Surface"])
    return m


def moon(sc):
    """A moon face behind the wolf with a soft halo, blooming in with the howl and fading out at the end."""
    vis = [(HOWL[0], 0.0), (HOWL[0] + 14, 1.0), (FADE[0], 1.0), (FADE[1], 0.0)]
    disc = stage.link(sc, "Moon", gc.ico_mesh("Moon", 1.0, 4), moon_material(vis), loc=MOON_AT, shadow=False)
    disc.data.polygons.foreach_set("use_smooth", [True] * len(disc.data.polygons))
    disc.scale = (2.1, 0.05, 2.1)
    halo = stage.link(sc, "MoonHalo", gc.ico_mesh("MoonHalo", 1.0, 3), halo_material(),
                      loc=(MOON_AT[0], MOON_AT[1] + 0.3, MOON_AT[2]), shadow=False)
    for f, s in ((HOWL[0], 0.0), (HOWL[0] + 16, 2.7), (FADE[0], 2.8), (FADE[1], 0.0)):
        halo.scale = (s, 0.02, s)       # flat disc behind the moon; a sphere this big would fog over its face
        halo.keyframe_insert("scale", frame=f)
    return disc


def cool_coat(meshes):
    """Moonlight: take most of the warmth out of the coat so it reads silver-grey, not tan, under the night light."""
    done = set()
    for o in meshes:
        for mat in o.data.materials:
            if not mat or not mat.use_nodes or mat.name in done:
                continue
            done.add(mat.name)
            b = next((n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
            if b is None or not b.inputs["Base Color"].links:
                continue
            nt = mat.node_tree
            src = b.inputs["Base Color"].links[0].from_socket
            hsv = nt.nodes.new("ShaderNodeHueSaturation")
            hsv.inputs["Saturation"].default_value, hsv.inputs["Value"].default_value = 0.18, 0.95
            tint = nt.nodes.new("ShaderNodeMix")
            tint.data_type, tint.blend_type = "RGBA", "MULTIPLY"
            tint.inputs["Factor"].default_value = 1.0
            tint.inputs["B"].default_value = (0.9, 0.95, 1.0, 1.0)
            nt.links.new(src, hsv.inputs["Color"])
            nt.links.new(hsv.outputs[0], tint.inputs["A"])
            nt.links.new(tint.outputs["Result"], b.inputs["Base Color"])


def visibility(meshes, items):
    """Every surface mixes with transparent by the keyed factor (0 = gone, 1 = solid)."""
    done = set()
    for o in meshes:
        for mat in o.data.materials:
            if not mat or not mat.use_nodes or mat.name in done:
                continue
            nt = mat.node_tree
            out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL" and n.is_active_output)
            shader = out.inputs["Surface"].links[0].from_socket
            tr, mix = nt.nodes.new("ShaderNodeBsdfTransparent"), nt.nodes.new("ShaderNodeMixShader")
            stage.key_socket(mix.inputs[0], items)
            nt.links.new(tr.outputs[0], mix.inputs[1])
            nt.links.new(shader, mix.inputs[2])
            nt.links.new(mix.outputs[0], out.inputs["Surface"])
            done.add(mat.name)


def build_show(sc, opts):
    root, arm, meshes, body = load()
    root.rotation_euler = (0.0, 0.0, YAW)
    cs.sequence(arm, [cs.Take(IDLE, 1, SNIFF), cs.Take(IDLE, 1 + SNIFF[1] - SNIFF[0] - 8, REST, blend=8)])
    cs.overlay(arm, "Howl", howl_keys(*HOWL))
    key_jaw(body, jaw_items(*HOWL))
    cs.lift_to(sc, root, meshes, GROUND_Z, 4)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.6, hdri="night.exr", lights=0.8, fog=(1.8, 7), streak=8.0)
    sh.shadow_catcher(sc, GROUND_Z, 40)
    moon(sc)
    cool_coat(meshes)
    visibility(meshes, [(APPEAR[0], 0.0), (APPEAR[1], 1.0), (FADE[0], 1.0), (FADE[1], 0.0)])
    sh.screen_extent(sc, cam, meshes, (4, 30, 70, 90, FADE[0]))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Standing wolf howling: muzzle up and mouth open once per loop, the moon behind."""
    root, arm, meshes, body = load()
    cam = stage.setup_icon(sc, opts["samples"], world=0.6, hdri="night.exr", lights=0.8, fog=(1.8, 7), streak=8.0)
    root.rotation_euler = (0.0, 0.0, R(40))
    cool_coat(meshes)
    n = stage.ICON_N
    cs.sequence(arm, [cs.Take(IDLE, 0, (0, 1), blend=0, repeat=n)])
    cs.overlay(arm, "IconHowl", howl_keys(0, n))
    key_jaw(body, [(0, 0.0), (8, 0.9), (n - 8, 0.9), (n, 0.0)])
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.12)
    sh.shadow_catcher(sc, gc.world_bbox(meshes)[0].z, 30)
    lo, hi = gc.world_bbox(meshes)
    disc = stage.link(sc, "Moon", gc.ico_mesh("Moon", 1.0, 4), moon_material([(0, 1.0)]),
                      loc=((lo.x + hi.x) / 2 + 0.6, 8.0, hi.z), shadow=False)
    disc.data.polygons.foreach_set("use_smooth", [True] * len(disc.data.polygons))
    disc.scale = (1.3, 0.05, 1.3)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
