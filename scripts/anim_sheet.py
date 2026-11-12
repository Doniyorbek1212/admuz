"""blender -b -P anim_sheet.py -- <model.glb> <out_dir> <keep_mesh_names,comma or *> [yaw_deg]
Renders 8 frames spread over the model's action (side 3/4 view) to see what the animation does."""
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402

a = sys.argv[sys.argv.index("--") + 1:]
glb, out_dir, keep = a[0], a[1], a[2].split(",")
yaw = math.radians(float(a[3])) if len(a) > 3 else math.radians(60)
sc = gc.reset_scene("Sheet")
objs = gc.import_glb(glb)
for o in objs:
    if o.type == "MESH" and keep != ["*"] and o.name not in keep:
        o.hide_render = True
    if o.name == "Icosphere":
        o.hide_render = True
root, _ = gc.normalize(objs, 7.0, rot=(0, 0, yaw), name="S")
gc.setup_render(sc, "", res=(480, 270), samples=16)
gc.setup_world(sc)
cam = gc.setup_camera(sc, elev_deg=8)
cam.data.lens = 32
gc.setup_lights(sc, follow=root)
act = next((x for x in bpy.data.actions if x.fcurves), None)
f0, f1 = (int(v) for v in act.frame_range)
print("ACTION", act.name, f0, f1)
for i in range(8):
    f = round(f0 + (f1 - f0) * i / 7)
    sc.frame_set(f)
    sc.render.filepath = os.path.join(out_dir, f"s_{i}_{f:03d}.png")
    bpy.ops.render.render(write_still=True)
