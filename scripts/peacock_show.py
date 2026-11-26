"""UZARO v2 show: peacock (tier 2, 120 f = 5 s).

Model: "Indian Peacock - Fanned Tail Bird" by s8819296 (Sketchfab, CC BY), a static mesh with its train folded.
We give it a small rig of our own (body, two neck bones, head, two train bones) weighted by distance.
Show: it appears in a puff of gold, turns slowly from facing us to full profile with the head bobbing as peacocks do,
then lifts its train and rattles it (the shiver real peacocks do) while gold glints rise off the feathers, looks back
at us and vanishes in sparkles.
"""
import math
import os
import sys

from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import autorig  # noqa: E402
import gift_common as gc  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402
import stage  # noqa: E402
from stage import R, env, interp  # noqa: E402

ID = "peacock"
TOTAL = 120
SIZE = 6.0                       # model length (beak to train tip)
GROUND_Z = -2.3
DECIMATE = 0.3                   # the file is 1.9M faces; a third keeps every feather edge at this size
APPEAR, TURN, LIFT, SHIVER, LOOK, VANISH = (1, 14), (14, 58), (58, 70), (68, 90), (90, 102), (104, 118)
GOLD = (1.0, 0.8, 0.45)
# rig in model units (file: beak toward -Y, up +Z, height 0.72, length 0.98)
BONES = [
    ("body", None, (0.0, -0.08, 0.30), (0.0, -0.30, 0.36)),
    ("neck0", "body", (0.0, -0.33, 0.42), (0.0, -0.40, 0.53)),
    ("neck1", "neck0", (0.0, -0.40, 0.53), (0.0, -0.44, 0.61)),
    ("head", "neck1", (0.0, -0.44, 0.61), (0.0, -0.50, 0.63)),
    ("train0", "body", (0.0, -0.08, 0.30), (0.0, 0.20, 0.15)),
    ("train1", "train0", (0.0, 0.20, 0.15), (0.0, 0.48, 0.07)),
]
NECK_BASE_Z, TRAIN_ROOT_Y = 0.40, -0.12   # model units: only the neck above, and the train behind, may follow those bones


def load(sc):
    root, model, objs, meshes = stage.load("peacock", SIZE)
    for m in meshes:
        stage.apply_modifier(m, "DECIMATE", ratio=DECIMATE)
    mw = model.matrix_world.copy()
    bones = [(n, p, mw @ Vector(h), mw @ Vector(t)) for n, p, h, t in BONES]
    neck_z = (mw @ Vector((0.0, 0.0, NECK_BASE_Z))).z
    train_y = (mw @ Vector((0.0, TRAIN_ROOT_Y, 0.0))).y
    above = lambda co: (co[:, 2] > neck_z).astype(float)        # noqa: E731
    behind = lambda co: (co[:, 1] > train_y).astype(float)      # noqa: E731
    limits = {"neck0": above, "neck1": above, "head": above, "train0": behind, "train1": behind}
    autorig.bake_world(meshes)
    arm = autorig.add_rig(sc, "PeacockRig", bones, meshes, power=4.0, limits=limits)
    arm.parent = root
    for m in meshes:
        m.parent = root
        for s in m.data.materials:
            if s and s.use_nodes and "Shiny" not in s:
                stage.shiny(s, roughness=0.42, coat=0.25, sheen=0.3)
                s["Shiny"] = True
    for pb in arm.pose.bones:
        pb.rotation_mode = "XYZ"
    return root, arm, meshes


def pose(arm, f, spec):
    """spec {bone: (x, y, z) degrees}; every bone keyed each frame so nothing drifts between keys."""
    for pb in arm.pose.bones:
        x, y, z = spec.get(pb.name, (0.0, 0.0, 0.0))
        pb.rotation_euler = (R(x), R(y), R(z))
        pb.keyframe_insert("rotation_euler", frame=f)


def bird_spec(f, bob, lift, shiver, look):
    """bob: head-bob phase; lift 0..1 raises the train; shiver 0..1 rattles it; look turns the head toward us."""
    b = math.sin(bob)
    rattle = shiver * math.sin(f * 2.9) * 3.0
    return {
        "body": (-2.0 * lift, 0.0, 0.0),
        "neck0": (6.0 * b - 4.0 * lift, 0.0, 10.0 * look),
        "neck1": (-4.0 * b + 6.0 * lift, 0.0, 14.0 * look),
        "head": (-3.0 * b - 6.0 * lift, 0.0, 10.0 * look),
        "train0": (-16.0 * lift + rattle, rattle * 0.5, 0.0),
        "train1": (-10.0 * lift - rattle, 0.0, 0.0),
    }


def animate(root, arm):
    yaw = [(TURN[0], -55.0), (TURN[1], 72.0)]
    for f in range(1, TOTAL + 1):
        root.rotation_euler = (0.0, 0.0, R(interp(yaw, f)))
        root.keyframe_insert("rotation_euler", frame=f)
        strut = 1.0 - env(f, TURN[1] - 6, TURN[1] + 2)
        root.location = (0.0, 0.0, 0.03 * abs(math.sin(f * math.pi / 11.0)) * strut)
        root.keyframe_insert("location", frame=f)
        lift = env(f, *LIFT) * (1.0 - env(f, LOOK[0] + 4, VANISH[0] + 2))
        shiver = env(f, SHIVER[0], SHIVER[0] + 4) * (1.0 - env(f, SHIVER[1] - 4, SHIVER[1]))
        look = env(f, *LOOK)
        pose(arm, f, bird_spec(f, f * 2 * math.pi / 11.0 * strut, lift, shiver, look))


def ground(sc, root, meshes):
    """Feet on the ground at full size: the pop scales from the root, so measure on a frame at scale 1."""
    sc.frame_set(APPEAR[1] + 2)
    dz = GROUND_Z - gc.world_bbox(meshes)[0].z
    for fc in root.animation_data.action.fcurves:
        if fc.data_path == "location" and fc.array_index == 2:
            for kp in fc.keyframe_points:
                for attr in ("co", "handle_left", "handle_right"):
                    getattr(kp, attr).y += dz


def glints(sc):
    """Gold motes rising off the train while it rattles, and a soft ring as it lifts."""
    mat = fx.fade_material("Glint", GOLD, 10.0)
    em = fx.particle_burst(sc, "Glint", fx.point_mesh("GlintSrc", 1.0), mat, 260, (SHIVER[0], SHIVER[1] + 4), 24, 0.02, 0.35,
                           rand=0.8, align=(0.0, 0.0, 0.5), damping=0.4, gravity=-0.03, location=(0.0, 0.0, GROUND_Z + 1.2))
    em.scale = (1.6, 1.0, 0.7)
    fx.shock_ring(sc, "LiftRing", (0.0, 0.0, GROUND_Z + 0.03), (LIFT[0], LIFT[0] + 22), 3.2, GOLD, 2.5, width=0.04)


def build_show(sc, opts):
    root, arm, meshes = load(sc)
    animate(root, arm)
    ground(sc, root, meshes)
    fx.pop(sc, root, APPEAR, VANISH, rgb=GOLD, size=1.6)
    cam = stage.setup(sc, TOTAL, opts["samples"], world=1.0, hdri="sunrise.exr", lights=1.15, fog=(2.0, 6), streak=8.0)
    sh.shadow_catcher(sc, GROUND_Z, 40)
    glints(sc)
    sh.screen_extent(sc, cam, meshes, (14, 30, 58, 80, 100))
    stage.bake_all(sc)


def build_icon(sc, opts):
    """Three-quarter profile, train raised and rattling, head bobbing twice per loop."""
    root, arm, meshes = load(sc)
    cam = stage.setup_icon(sc, opts["samples"], world=1.0, hdri="sunrise.exr", lights=1.15, fog=(2.0, 6), streak=6.0)
    root.rotation_euler = (0.0, 0.0, R(55))
    n = stage.ICON_N
    for f in range(0, n + 1):
        w = 2 * math.pi * f / n
        spec = bird_spec(0, 2 * w, 0.7, 0.0, 0.0)
        r = math.sin(3 * w) * 2.5                                           # three rattles per loop: seamless
        spec["train0"] = (spec["train0"][0] + r, 0.0, 0.0)
        spec["train1"] = (spec["train1"][0] - r, 0.0, 0.0)
        pose(arm, f, spec)
    sc.frame_set(1)
    stage.frame_icon(cam, meshes, pad=1.16)
    sh.shadow_catcher(sc, gc.world_bbox(meshes)[0].z, 30)


if __name__ == "__main__":
    stage.run(ID, build_show, build_icon)
