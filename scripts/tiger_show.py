"""UZARO v2 show: tiger (tier 3, 144 f = 6 s).

A tiger stalks in low from the left, turning toward camera; it stops, snarls with bared teeth and wiggles its haunches,
then leaps straight at the lens: the flight drops into slow motion with claws out and jaw open, then it clears the
frame over the camera. Autorig plus particle fur; the white coat in the file is tinted orange, stripes stay black.
"""
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import animal  # noqa: E402
import gift_common as gc  # noqa: E402
import quadruped as qp  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, env, interp  # noqa: E402

ID = "tiger"
TOTAL = 144
SIZE = 6.0
K = 1.0
GROUND_Z = -3.0
FOOT = 1.57
ORANGE = (0.95, 0.36, 0.055)
FUR = (0.6, 0.13, 0.012)   # hair scatters light: darker and more saturated than the skin to read the same colour
GAIT = qp.Gait(cycle_dist=3.3, duty=0.66, lift=0.3, bob=0.03, hind_flex=25.0, fore_flex=40.0)
STALK = {"LB": 0.0, "LF": 0.25, "RB": 0.5, "RF": 0.75}
TRAVEL = [(1, (-10.4, 0.0)), (50, (-2.0, -0.4)), (62, (-1.4, -0.9))]
HEADING = [(1, 76.0), (46, 66.0), (62, 42.0), (78, 38.0)]
CROUCH = [(1, 0.34), (50, 0.42), (62, 0.55), (74, 0.72), (79, 0.05)]
SNARL = (50, 58, 72, 80)
LEAP_F = 78
# slow-mo: flight fraction per frame. Fast takeoff, a long hang, then it rushes the lens.
FLIGHT = [(LEAP_F, 0.0), (88, 0.16), (116, 0.34), (TOTAL - 8, 1.0), (TOTAL, 1.0)]
TAKEOFF = (-1.4, -0.9)
OVER_CAMERA = (7.5, -11.0, 5.0)
JOINTS = {
    "spine": [(0, 1.5, 0.5), (0, 0.0, 0.55), (0, -1.2, 0.6)],
    "neck": [(0, -1.4, 0.75), (0, -2.0, 1.3)],
    "head": [(0, -2.0, 1.4), (0, -2.96, 0.72)],
    "jaw": [(0, -2.35, 0.75), (0, -2.85, 0.5)],
    "tail": [(0, 2.1, 0.55), (0, 2.4, -0.06), (0, 2.3, -0.86), (0, 2.5, -1.2), (0, 2.96, -1.3)],
    "fore": [(0.35, -1.2, 0.35), (0.35, -1.15, -0.56), (0.35, -1.25, -1.2), (0.35, -1.4, -1.47), (0.35, -1.7, -1.57)],
    "hind": [(0.35, 1.5, 0.35), (0.35, 1.2, -0.56), (0.35, 2.0, -1.06), (0.35, 1.8, -1.45), (0.35, 1.3, -1.57)],
}
X, Y, Z = animal.X, animal.Y, animal.Z


def flight(f):
    return interp(FLIGHT, f) if f >= LEAP_F else 0.0


def in_air(f):
    return env(f, LEAP_F, LEAP_F + 7)


def snarl(f):
    return env(f, SNARL[0], SNARL[1]) * (1 - env(f, SNARL[2], SNARL[3]))


def orange_skin(mat):
    """Multiply the white coat so the bare skin under the fur reads the same orange."""
    nt = mat.node_tree
    b = stage.bsdf(mat)
    if not b.inputs["Base Color"].links:
        return
    src = b.inputs["Base Color"].links[0].from_socket
    mx = nt.nodes.new("ShaderNodeMix")
    mx.data_type, mx.blend_type = "RGBA", "MULTIPLY"
    mx.inputs["Factor"].default_value = 1.0
    mx.inputs["B"].default_value = (*ORANGE, 1.0)
    nt.links.new(src, mx.inputs["A"])
    nt.links.new(mx.outputs["Result"], b.inputs["Base Color"])


def claws(sc, arm):
    """Ivory claws on the fore paws, rigid to the paw bone: visible when the paws spread in the leap."""
    mat = stage.pbr("Claw", (0.55, 0.48, 0.36), roughness=0.3, coat=0.5)
    for side, s in (("L", 1.0), ("R", -1.0)):
        verts, faces = [], []
        for i in range(4):
            cx = s * 0.35 + (i - 1.5) * 0.11
            base = len(verts)
            for k in range(6):
                t = 2 * math.pi * k / 6
                verts.append((cx + 0.035 * math.cos(t), -1.56, -1.5 + 0.035 * math.sin(t)))
            verts.append((cx, -1.72, -1.6))
            faces += [(base + k, base + (k + 1) % 6, base + 6) for k in range(6)]
        me = bpy.data.meshes.new(f"Claws{side}")
        me.from_pydata(verts, [], faces)
        me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
        ob = stage.link(sc, f"Claws{side}", me, mat, parent=arm)
        ob.vertex_groups.new(name=f"{side}F3").add(list(range(len(verts))), 1.0, "REPLACE")
        ob.modifiers.new("Rig", "ARMATURE").object = arm
        ob.hide_render = True                 # sheathed until the leap: on the ground they read as white spikes
        ob.keyframe_insert("hide_render", frame=LEAP_F - 1)
        ob.hide_render = False
        ob.keyframe_insert("hide_render", frame=LEAP_F)


def load(sc):
    root, model, objs, meshes = stage.load(ID, SIZE, strip_rig=True)
    limits = animal.side_limits(JOINTS)
    limits["jaw"] = lambda c: ((c[:, 1] < -2.3) & (c[:, 2] < 0.72)) * 1.0
    for i in range(4):
        limits[f"tail{i}"] = lambda c: (c[:, 1] > 1.9) * 1.0
    arm = animal.build(sc, "Tiger", JOINTS, meshes, power=7.0, limits=limits)
    wrap = bpy.data.objects.new("Heading", None)
    sc.collection.objects.link(wrap)
    wrap.parent = root
    wrap.rotation_mode = "XYZ"
    arm.parent = wrap
    root.scale = (K, K, K)
    claws(sc, arm)
    for m in meshes:
        for s in m.data.materials:
            orange_skin(s)
            stage.shiny(s, roughness=0.6)
        animal.fur(m, 0.04, count=16000, children=24, radius=0.0038, roughness=0.45, clump=0.2, gamma=2.6, multiply=FUR)
    return root, wrap, arm, meshes


def animate(root, wrap, mover):
    frames = range(1, TOTAL + 1)
    dist, prev = 0.0, interp(TRAVEL, 1)
    for f in frames:
        px = interp(TRAVEL, f)
        dist += math.hypot(px[0] - prev[0], px[1] - prev[1])
        prev = px
        air, t = in_air(f), flight(f)
        moving = 1 - env(f, 48, 62)
        crouch = interp(CROUCH, f)
        bob = mover.legs_at(f, dist, moving, crouch * (1 - air))
        if air > 0.001:
            ext = air * (1 - 0.25 * env(f, 118, TOTAL))
            for key, s in (("LF", 1.0), ("RF", -1.0)):
                mover.leg(f, key, paw=(2.0 * ext, 1.6 * ext + 0.1 * s * math.sin(f / 5.0)), flex=-0.3 * ext)
            for key in ("LB", "RB"):
                mover.leg(f, key, paw=(-1.6 * ext, 0.55 * ext), flex=-0.2 * ext)
        sn = snarl(f)
        roar = max(sn, air)
        wiggle = 0.06 * math.sin(f * 1.5) * env(f, 62, 68) * (1 - env(f, 75, 78))
        pitch = -24.0 * env(f, LEAP_F, LEAP_F + 6) * (1 - 0.55 * env(f, 90, 118))
        stalk = 1 - air
        mover.body(f, {
            "spine0": (X, pitch * 0.6 + 5.0 * stalk * math.sin(dist * 3.8)),
            "spine1": (X, pitch * 0.4 + 3.0 * crouch * stalk),
            "neck0": [(Z, -24.0 * sn), (X, 22.0 * stalk * (1 - sn) - 18.0 * air)],
            "head": [(X, 12.0 * stalk * (1 - sn) + 8.0 * sn - 14.0 * air), (Y, 7.0 * sn * math.sin(f / 2.2))],
            "jaw": (X, 30.0 * roar + 3.0 * roar * math.sin(f / 1.7)),
            "tail0": [(X, -26.0 * stalk - 42.0 * air), (Z, 16.0 * math.sin(f / 7.0))],
            "tail1": [(X, -16.0 - 16.0 * air), (Z, 18.0 * math.sin(f / 7.0 - 0.9))],
            "tail2": (Z, 20.0 * math.sin(f / 7.0 - 1.8)),
            "tail3": (Z, 24.0 * math.sin(f / 7.0 - 2.7)),
        })
        ground = (px[0] + wiggle, px[1], GROUND_Z + FOOT + bob - crouch * (1 - air))
        y = ground[1] + (OVER_CAMERA[1] - ground[1]) * t
        z = ground[2] + (OVER_CAMERA[2] - ground[2]) * t ** 1.8 + 1.3 * math.sin(math.pi * min(1.0, t * 1.4)) * air
        root.location = (ground[0] + OVER_CAMERA[0] * t, y, z)
        root.keyframe_insert("location", frame=f)
        wrap.rotation_euler = (0.0, 0.0, R(interp(HEADING, f)))
        wrap.keyframe_insert("rotation_euler", frame=f)


def dust(sc):
    """Paws throw grit at the takeoff, with a soft cloud behind."""
    mat = fx.fade_material("Dust", (0.72, 0.58, 0.42), 1.0, 0.16, 1.2)
    fx.particle_burst(sc, "Launch", fx.ring_mesh("LaunchR", 0.7, 0.05, 32), mat, 200, (LEAP_F - 2, LEAP_F + 6), 24, 0.34, 1.4, rand=2.2,
                      damping=0.12, gravity=-0.02, location=(TAKEOFF[0], TAKEOFF[1], GROUND_Z + 0.05))
    fx.particle_burst(sc, "Grit", fx.ring_mesh("GritR", 1.2, 0.05, 32), stage.pbr("Grit", (0.32, 0.25, 0.18), roughness=0.9), 200, (LEAP_F - 1, LEAP_F + 4), 28, 0.03, 3.0, rand=2.2,
                      align=(0, 1.0, 1.4), gravity=0.5, location=(TAKEOFF[0], TAKEOFF[1], GROUND_Z + 0.05))


def build_show(sc, opts):
    root, wrap, arm, meshes = load(sc)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=0.6, follow=root, lights=0.75, fog=(1.8, 6), streak=9.0, shutter=0.3)
    e = R(5)
    cam.location, cam.rotation_euler = (0.0, -gc.CAM_DIST * math.cos(e), gc.CAM_DIST * math.sin(e)), (R(90) - e, 0, 0)
    cam.data.clip_start = 0.3
    sh.shadow_catcher(sc, GROUND_Z, 50)
    animate(root, wrap, animal.Mover(arm, GAIT, STALK))
    dust(sc)
    sh.camera_shake(cam, LEAP_F, 12, amp=0.05, rot_deg=0.3, seed=3)
    sh.screen_extent(sc, cam, meshes, (1, 50, 70, 100, 125, TOTAL))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Crouched face-on, snarling on a seamless loop of the head and tail."""
    root, wrap, arm, meshes = load(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=0.6, follow=root, lights=0.75, fog=(1.8, 6), streak=9.0)
    mover = animal.Mover(arm, GAIT, STALK)
    wrap.rotation_euler = (0, 0, R(22))
    n = stage.ICON_N
    for f in range(0, n + 1):
        w = 2 * math.pi * f / n
        s = 0.55 + 0.45 * math.sin(w)
        mover.legs_at(f, 0.0, 0.0, 0.45)
        mover.body(f, {
            "neck0": (X, 6.0), "head": [(X, 8.0 * s), (Y, 5.0 * math.sin(2 * w))],
            "jaw": (X, 28.0 * s),
            "tail0": [(X, -26.0), (Z, 16.0 * math.sin(w))], "tail1": (Z, 18.0 * math.sin(w - 0.9)), "tail2": (Z, 20.0 * math.sin(w - 1.8)),
        })
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.1)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
