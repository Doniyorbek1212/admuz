"""Side-view walk test for the roar lion rig: blender -b -P walk_test.py -- <out_dir> [hind_flex fore_flex]"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402
import quadruped as qp  # noqa: E402

a = sys.argv[sys.argv.index("--") + 1:]
out = a[0]
hf, ff = (float(a[1]), float(a[2])) if len(a) > 2 else (28.0, 40.0)
sc = gc.reset_scene("Walk")
objs = gc.import_glb(os.path.join(gc.MODELS, "lion_roar.glb"))
for o in objs:
    if o.type == "MESH" and o.name not in ("Object_7", "Object_8"):
        o.hide_render = True
root, _ = gc.normalize(objs, 7.0, name="Lion")
root.rotation_euler = (0, 0, math.radians(90))     # facing -Y -> facing +X (screen right)
arm = next(o for o in objs if o.type == "ARMATURE")
arm.animation_data.action = None
for pb in arm.pose.bones:
    pb.matrix_basis.identity()  # clearing the action leaves its last pose on the bones
names = {b.name for b in arm.data.bones}


def chain(prefix):
    order = ["Leg1", "Leg2", "Leg3", "LegAnkle"]
    return [next(n for n in names if n.startswith(f"Rig{prefix}{o}_")) for o in order]


gait = qp.Gait(cycle_dist=95.0, hind_flex=hf, fore_flex=ff)
legs = qp.make_legs(arm, {k: chain(k) for k in ("LB", "LF", "RB", "RF")},
                    Vector((0, 0, -1)), Vector((0, -1, 0)), Vector((1, 0, 0)), gait)
bpy.context.view_layer.update()
k = (arm.matrix_world.to_3x3() @ Vector((0, 0, 1))).length          # world units per armature unit
gc.setup_render(sc, "", res=(640, 360), samples=16)
gc.setup_world(sc)
cam = gc.setup_camera(sc, elev_deg=5)
gc.setup_lights(sc, follow=root)
period = 28
for i in range(8):
    f = i * period / 8
    dist = gait.cycle_dist * f / period
    bob = qp.pose_walk(legs, gait, dist, 1.0)
    root.location = (0, 0, bob * k)                                  # walk in place for the test
    bpy.context.view_layer.update()
    sc.render.filepath = os.path.join(out, f"w_{i}.png")
    bpy.ops.render.render(write_still=True)
print("K", k)
