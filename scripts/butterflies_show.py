"""UZARO v2 show: butterflies (tier 1, 96 f = 4 s).

A swarm of monarchs (rigged flap loop, per-insect phase) sweeps in from bottom-left, circles centre and leaves
top-right, each leaving a fading sparkle trail. Wings pick up a view-dependent iridescent sheen.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R  # noqa: E402

ID = "butterflies"
TOTAL = 96
COUNT, SIZE = 11, 1.9
CENTRE = [(-6, (-7.5, 0, -9.0)), (28, (-1.6, 0, -2.2)), (50, (1.3, 0, 0.2)), (68, (-0.4, 0, 2.2)), (TOTAL + 6, (7.5, 0, 9.5))]
SPREAD = (2.2, 1.6, 3.2)
FLAP = "hover_skeletal.3"


def iridescent(mat):
    """Thin-film look: viewing angle picks cyan -> violet emission on top of the wing texture."""
    nt = mat.node_tree
    b = stage.bsdf(mat)
    lw, ramp = nt.nodes.new("ShaderNodeLayerWeight"), nt.nodes.new("ShaderNodeValToRGB")
    lw.inputs["Blend"].default_value = 0.35
    els = ramp.color_ramp.elements
    els[0].position, els[0].color = 0.15, (0.0, 0.0, 0.0, 1)
    els[1].position, els[1].color = 1.0, (0.65, 0.1, 1.0, 1)
    els.new(0.5).color = (0.02, 0.75, 0.85, 1)
    nt.links.new(lw.outputs["Fresnel"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], b.inputs["Emission Color"])
    b.inputs["Emission Strength"].default_value = 0.9
    b.inputs["Roughness"].default_value = 0.35


def spawn(sc, base_arm, base_mesh, base_world, i, action):
    """Own armature (own flap phase), shared mesh data."""
    holder = bpy.data.objects.new(f"Holder{i}", None)
    sc.collection.objects.link(holder)
    arm = bpy.data.objects.new(f"Arm{i}", base_arm.data)
    sc.collection.objects.link(arm)
    arm.parent = holder
    arm.matrix_local = base_world     # file's own axes and unit scale; the holder then flies it
    arm.animation_data_create()
    tr = arm.animation_data.nla_tracks.new()
    st = tr.strips.new("flap", 1, action)
    st.repeat, st.scale = 12, 0.55
    st.frame_start_ui = 1 - (i * 7) % int(action.frame_range[1])
    me = bpy.data.objects.new(f"Wing{i}", base_mesh.data)
    sc.collection.objects.link(me)
    me.parent = arm
    me.matrix_local = base_mesh.matrix_local
    me.modifiers.new("Arm", "ARMATURE").object = arm
    return holder


def path(off, delay, f):
    c = Vector(stage.interp(CENTRE, f - delay))
    p = off[3]
    return c + Vector((off[0] * math.cos(f / 14 + p), off[1] * math.sin(f / 10 + p),
                       off[2] * math.sin(f / 18 + p) + 0.25 * math.sin(f / 2.2 + p)))


def load():
    objs = gc.import_glb(os.path.join(gc.MODELS, "butterfly.glb"), hide=("Icosphere",))
    arm = next(o for o in objs if o.type == "ARMATURE")
    mesh = next(o for o in objs if o.type == "MESH" and not o.hide_render)
    iridescent(mesh.data.materials[0])
    return arm, mesh, bpy.data.actions[FLAP]


def build_show(sc, opts):
    base_arm, base_mesh, action = load()
    base_arm.animation_data_clear()
    lo, hi = gc.world_bbox([base_mesh])
    k = SIZE / max(hi - lo)
    base_world = base_arm.matrix_world.copy()
    base_world.translation = (0, 0, 0)
    stage.setup(sc, TOTAL, opts["samples"], world=0.9, lights=0.6, fog=(1.4, 7), streak=3.5)
    rnd = stage.seeded(8)
    sparkle = fx.fade_material("Sparkle", (1.0, 0.78, 0.35), 16.0, 1.0, 1.2)
    frames = list(range(-2, TOTAL + 2, 2))
    for i in range(COUNT):
        arm = spawn(sc, base_arm, base_mesh, base_world, i, action)
        s = k * rnd.uniform(0.7, 1.15)
        arm.scale = (s, s, s)
        off = (rnd.uniform(-1, 1) * SPREAD[0], rnd.uniform(-1, 1) * SPREAD[1], rnd.uniform(-1, 1) * SPREAD[2], rnd.uniform(0, 6.28))
        delay = rnd.uniform(0, 12)
        arm.rotation_mode = "QUATERNION"

        def rot(f, off=off, delay=delay):
            v = path(off, delay, f + 1) - path(off, delay, f - 1)
            v.y -= 0.05         # always slightly toward the camera, so the wings read
            return v.to_track_quat("-Y", "Z")
        stage.key_path(arm, frames, lambda f, off=off, delay=delay: path(off, delay, f))
        stage.key_path(arm, frames, rot, path="rotation_quaternion")
        em = fx.particle_burst(sc, f"Trail{i}", gc.ico_mesh(f"TrailSrc{i}", 0.12, 1), sparkle, 110, (1, TOTAL), 22, 0.016, 0.0,
                               rand=0.6, gravity=0.03, emit_from="VOLUME")
        em.parent = arm
        em.scale = (1 / s,) * 3
    base_mesh.hide_render = base_arm.hide_render = True
    stage.bake_all(sc)


def build_icon(sc, opts):
    arm, mesh, action = load()
    cam = stage.setup_icon(sc, opts["samples"], world=0.9, lights=0.6, fog=(1.4, 7), streak=3.5)
    arm.animation_data.action = None
    tr = arm.animation_data.nla_tracks.new()
    st = tr.strips.new("flap", 0, action)
    st.scale = stage.ICON_N / action.frame_range[1]   # exact loop: one action pass per 30 frames
    root = bpy.data.objects.new("R", None)
    sc.collection.objects.link(root)
    arm.parent = root
    root.rotation_euler = (R(15), 0, R(-35))
    stage.frame_icon(cam, [mesh], pad=1.2)
    _ = (math, Vector)


stage.run(ID, build_show, build_icon)
