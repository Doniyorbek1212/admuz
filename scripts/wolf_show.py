"""UZARO v2 show: wolf (tier 2, 120 f = 5 s).

A grey wolf trots in, stops, lifts its head and howls; a pale moon blooms behind it and breath vapour curls from its
muzzle; then wolf and moon fade into the night. The file's single take holds a trot (61-93) and a stand (100-111): they are cut out and cross-faded on the
NLA, the trot speed read off the forefoot's stance (TROT_V). The howl (neck and head up, jaw open) is hand keys combined on top.
Fur is the model's own texture (no hair sim).
"""
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import clipshow as cs  # noqa: E402
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R  # noqa: E402

ID = "wolf"
TOTAL = 120
SIZE = 4.4
GROUND_Z = -3.2
YAW = R(66)                                    # nose (-Y after load) turned to trot right and a little toward the lens
TAKE = "Wolf"
TROT, STAND = (61, 93), (100, 111)
FOOT = "Front_Left_Foot_Bone_Wolf_Armature"
STOP = 44
HOWL = (58, 104)
NECK, HEAD, SNOUT, JAW = (f"{n}_Wolf_Armature" for n in ("Neck_Bone", "Head", "Bone.023", "Bone.024"))
MOON = (0.85, 0.9, 1.0)
TROT_V = 0.09        # the stance forefoot sweeps ~1.4 units back in ~16 frames; foot_speed's 10 % floor band caught 2 samples
FADE = (104, TOTAL - 1)


def howl_keys(a, b):
    """Neck and head lift (+X raises the tip on this rig), jaw drops; held, then eased back."""
    ramp = lambda deg: [(a, "X", 0.0), (a + 10, "X", deg), (b - 8, "X", deg), (b, "X", 0.0)]
    return {NECK: ramp(28.0), HEAD: ramp(30.0), SNOUT: ramp(8.0), JAW: [(a + 4, "X", 0.0), (a + 12, "X", -24.0),
                                                                        (b - 10, "X", -24.0), (b - 2, "X", 0.0)]}


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
    em.inputs["Strength"].default_value = 1.3
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
    disc = stage.link(sc, "Moon", gc.ico_mesh("Moon", 1.0, 4), moon_material(vis), loc=(1.2, 9.0, 2.6), shadow=False)
    disc.data.polygons.foreach_set("use_smooth", [True] * len(disc.data.polygons))
    disc.scale = (1.7, 0.05, 1.7)
    halo_m = halo_material()
    halo = stage.link(sc, "MoonHalo", gc.ico_mesh("MoonHalo", 1.0, 3), halo_m, loc=(1.2, 9.3, 2.6), shadow=False)
    for f, s in ((HOWL[0], 0.0), (HOWL[0] + 16, 2.2), (FADE[0], 2.3), (FADE[1], 0.0)):
        halo.scale = (s, 0.02, s)       # flat disc behind the moon; a sphere this big would fog over its face
        halo.keyframe_insert("scale", frame=f)
    return disc


def fade_out(meshes):
    """Wolf melts into the night: every surface mixes to transparent over FADE."""
    done = set()
    for o in meshes:
        for mat in o.data.materials:
            if not mat or not mat.use_nodes or mat.name in done:
                continue
            nt = mat.node_tree
            out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL" and n.is_active_output)
            shader = out.inputs["Surface"].links[0].from_socket
            tr, mix = nt.nodes.new("ShaderNodeBsdfTransparent"), nt.nodes.new("ShaderNodeMixShader")
            stage.key_socket(mix.inputs[0], [(FADE[0], 1.0), (FADE[1], 0.0)])
            nt.links.new(tr.outputs[0], mix.inputs[1])
            nt.links.new(shader, mix.inputs[2])
            nt.links.new(mix.outputs[0], out.inputs["Surface"])
            done.add(mat.name)


def breath(sc, arm):
    mat = fx.fade_material("Breath", (0.9, 0.93, 1.0), 0.6, 0.3, 1.2)
    em = fx.particle_burst(sc, "Breath", fx.point_mesh("BreathSrc", 0.05), mat, 90, (HOWL[0] + 8, HOWL[1] - 8), 30, 0.18, 0.25,
                           rand=0.6, align=(0.0, 0.0, 0.6), damping=0.2, gravity=-0.03)
    c = em.constraints.new("COPY_LOCATION")
    c.target, c.subtarget, c.head_tail = arm, SNOUT, 1.0
    return em


def build_show(sc, opts):
    root, arm, meshes = cs.load(ID, SIZE, rot=(0.0, 0.0, R(90)))
    v = TROT_V
    plan = [cs.Take(TAKE, 1, TROT, repeat=(STOP + 4) / (TROT[1] - TROT[0]), speed=v),
            cs.Take(TAKE, STOP - 2, STAND, blend=8)]
    seq = cs.sequence(arm, plan)
    cs.travel(root, TOTAL, YAW, seq, STOP + 8, (0.2, 0.6))
    cs.overlay(arm, "Howl", howl_keys(*HOWL))
    cs.lift_to(sc, root, meshes, GROUND_Z, 10)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.6, hdri="night.exr", lights=0.8, fog=(1.8, 7), streak=8.0)
    sh.shadow_catcher(sc, GROUND_Z, 40)
    moon(sc)
    breath(sc, arm)
    fade_out(meshes)
    sh.screen_extent(sc, cam, meshes, (1, 24, STOP + 8, 80, FADE[0]))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Standing wolf howling: head up and down once per loop, the moon behind."""
    root, arm, meshes = cs.load(ID, SIZE, rot=(0.0, 0.0, R(90)))
    cam = stage.setup_icon(sc, opts["samples"], world=0.6, hdri="night.exr", lights=0.8, fog=(1.8, 7), streak=8.0)
    root.rotation_euler = (0.0, 0.0, R(40))
    n = stage.ICON_N
    cs.sequence(arm, [cs.Take(TAKE, 0, (104, 105), blend=0, repeat=n)])
    cs.overlay(arm, "IconHowl", howl_keys(0, n))
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
