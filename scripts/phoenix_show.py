"""UZARO v2 show: phoenix (tier 3, 144 f = 6 s).

Flames gather at the bottom of frame (Mantaflow); the firebird bursts up out of them with burning wings: the bird mesh is
itself a fire source, so fire streams off the wings as they beat. It hangs, wings blazing, shedding embers, flares
in a final burst of light and shoots up out of frame. Wing beat is the action from the file, looped.
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
from stage import R, interp  # noqa: E402

ID = "phoenix"
TOTAL = 144
SIZE = 8.0
K = 0.8
HIDE = ("Plane001",)
BODY = "default001fg_15"
PATH = [(1, (0.0, 0.0, -13.0)), (30, (0.0, 0.0, -11.0)), (58, (0.0, -0.8, -0.8)), (112, (0.0, -1.2, 0.2)), (118, (0.0, -1.2, 0.5)), (TOTAL - 6, (0.0, 1.0, 13.0))]
PITCH = [(1, -68.0), (58, -56.0), (72, -32.0), (112, -28.0), (120, -58.0), (TOTAL, -70.0)]
FLARE_F = 114
GLOW = [(1, 1.2), (58, 2.0), (108, 2.6), (FLARE_F, 12.0), (FLARE_F + 8, 5.0), (TOTAL, 3.0)]


def loop_flap(objs, period=None):
    """Repeat the file's flap for as long as the show runs. period rescales one beat to that many frames."""
    for o in objs:
        ad = o.animation_data
        if not ad or not ad.action:
            continue
        act = ad.action
        length = act.frame_range[1] - act.frame_range[0]
        k = period / length if period else 1.0
        for fc in act.fcurves:
            for kp in fc.keyframe_points:
                for attr in ("co", "handle_left", "handle_right"):
                    getattr(kp, attr).x *= k
            fc.modifiers.new("CYCLES")


def burn(mat, glow_keys):
    """The feather texture itself glows, with keyed strength."""
    if not mat or not mat.use_nodes:
        return
    b = stage.bsdf(mat)
    links = b.inputs["Base Color"].links
    if links:
        mat.node_tree.links.new(links[0].from_socket, b.inputs["Emission Color"])
    else:
        b.inputs["Emission Color"].default_value = b.inputs["Base Color"].default_value
    stage.key_socket(b.inputs["Emission Strength"], [(f, float(v)) for f, v in glow_keys])


def mesh_flow(ob):
    """The bird burns: its mesh feeds the domain with fuel, keyed on when it emerges."""
    fm = ob.modifiers.new("Fluid", "FLUID")
    fm.fluid_type = "FLOW"
    fs = fm.flow_settings
    fs.flow_type, fs.flow_behavior, fs.flow_source = "BOTH", "INFLOW", "MESH"
    fs.surface_distance = 0.22
    fs.use_initial_velocity = True
    fs.velocity_normal = 0.6
    for f, fuel in ((1, 0.0), (32, 0.0), (42, 1.4), (TOTAL - 20, 1.4), (TOTAL - 8, 0.0)):
        fs.fuel_amount, fs.density = fuel, fuel * 0.12
        ob.keyframe_insert('modifiers["Fluid"].flow_settings.fuel_amount', frame=f)
        ob.keyframe_insert('modifiers["Fluid"].flow_settings.density', frame=f)


def embers(sc, root):
    """Embers off the whole span: they stay in the air behind the moving bird, cooling as they fall."""
    hot = fx.fade_material("Ember", (1.0, 0.42, 0.05), 22.0, 1.0, 0.9)
    em = fx.particle_burst(sc, "Embers", fx.ring_mesh("EmberR", 2.6, 0.1, 40), hot, 2200, (36, TOTAL - 8), 34, 0.018, 0.7, rand=1.2, gravity=0.12)
    em.parent = root
    gold = fx.fade_material("Spark", (1.0, 0.75, 0.25), 30.0, 1.0, 1.0)
    em2 = fx.particle_burst(sc, "Sparks", fx.ring_mesh("SparkR", 1.2, 0.1, 30), gold, 900, (40, TOTAL - 10), 22, 0.012, 1.1, rand=1.4, gravity=0.2)
    em2.parent = root


def flare(sc, root):
    """Final burst: core star, a ring of light facing the camera, motes flying out."""
    core = stage.link(sc, "FlareCore", gc.ico_mesh("FlareCore", 0.3, 2), stage.emit("FlareCore", (1.0, 0.85, 0.55), 70.0), shadow=False)
    at = (0.0, -1.3, 0.35)
    core.location = at
    stage.key_path(core, (FLARE_F - 2, FLARE_F + 2, FLARE_F + 10), lambda f: {FLARE_F - 2: (0.001,) * 3, FLARE_F + 2: (2.4,) * 3, FLARE_F + 10: (0.001,) * 3}[f], path="scale")
    for name, rgb in (("MoteA", (1.0, 0.72, 0.28)), ("MoteB", (1.0, 0.35, 0.06))):
        fx.particle_burst(sc, name, gc.ico_mesh(f"{name}E", 0.25, 2), stage.emit(name, rgb, 26.0), 320, (FLARE_F, FLARE_F + 3), 24, 0.024, 4.5, rand=0.9, damping=0.09, gravity=0.04, location=at)
    ld = bpy.data.lights.new("Flare", "POINT")
    ld.color, ld.shadow_soft_size = (1.0, 0.65, 0.3), 1.0
    stage.link(sc, "FlareL", ld, loc=(0.0, -3.0, 0.5))
    for f, e in ((FLARE_F - 1, 0.0), (FLARE_F + 2, 9000.0), (FLARE_F + 18, 0.0)):
        ld.energy = e
        ld.keyframe_insert("energy", frame=f)
    _ = root


def load(sc, period=None):
    root, model, objs, meshes = stage.load(ID, SIZE, hide=HIDE)
    loop_flap(objs, period)
    root.scale = (K, K, K)
    root.rotation_mode = "XYZ"
    return root, objs, meshes


def build_show(sc, opts):
    root, objs, meshes = load(sc)
    test = opts["test"] is not None
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.55, follow=root, lights=0.65, fog=(1.8, 7), streak=6.0)
    gas.filmic(sc)
    for mat in {s for m in meshes for s in m.data.materials}:
        burn(mat, GLOW)
    frames = range(1, TOTAL + 1)
    stage.key_path(root, frames, lambda f: interp(PATH, f))
    stage.key_path(root, frames, lambda f: (R(interp(PITCH, f)), 0.0, R(10.0 * math.sin(f / 19.0))), path="rotation_euler")
    embers(sc, root)
    flare(sc, root)
    # fire: a bed of flame at the foot of frame, then the burning bird. Lower grid for test stills: a bake is the slow part.
    mat = gas.material("PhoenixFire", smoke_rgb=(0.08, 0.05, 0.04), density=0.25, edge_fade=(0.1, 0.08, 0.06))
    dom = gas.domain(sc, ID, (0.0, 0.0, 0.0), (4.4, 3.4, 7.8), TOTAL, mat, res=64 if test else 150, vorticity=1.0, burn=0.7, flame_smoke=0.25, flame_vort=1.6, dissolve=14, beta=2.0)
    bed = gas.flow(sc, "Bed", 1.3, (0.0, 0.0, -6.3), velocity=(0, 0, 2.0))
    bed.scale = (1.7, 1.0, 0.25)
    gas.key_flow(bed, [(1, 0.0, 0.0), (6, 1.2, 0.08), (52, 1.6, 0.1), (70, 0.0, 0.0)])
    mesh_flow(next(m for m in meshes if m.name.startswith(BODY)))
    sh.camera_shake(cam, 46, 14, amp=0.05, rot_deg=0.3, seed=3)
    sh.camera_shake(cam, FLARE_F, 12, amp=0.04, rot_deg=0.25, seed=7)
    sh.screen_extent(sc, cam, meshes, (1, 58, 100, 130))
    stage.bake_all(sc)
    gas.bake(sc, dom)


def build_icon(sc, opts):
    """Beating two wing strokes per loop over a ring of embers; no sim, it must loop exactly."""
    n = stage.ICON_N
    root, objs, meshes = load(sc, period=n / 2)
    cam = stage.setup_icon(sc, opts["samples"], world=0.55, follow=root, lights=0.65, fog=(1.8, 7), streak=6.0)
    gas.filmic(sc)
    for mat in {s for m in meshes for s in m.data.materials}:
        burn(mat, [(0, 3.0), (n, 3.0)])
    root.rotation_euler = (R(-30), 0.0, 0.0)
    hot = fx.fade_material("Ember", (1.0, 0.42, 0.05), 22.0, 1.0, 0.9)
    em = fx.particle_burst(sc, "Embers", fx.ring_mesh("EmberR", 2.6, 0.1, 40), hot, 1200, (-40, n), 34, 0.03, 0.6, rand=1.2, gravity=-0.05)
    em.parent = root
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.15)
    stage.bake_all(sc)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
