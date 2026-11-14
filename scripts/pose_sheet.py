"""blender -b --factory-startup -P pose_sheet.py -- <out_dir> <model> <first> <last> <step> [yaw deg]: workbench poses of the imported animation."""
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402

a = sys.argv[sys.argv.index("--") + 1:]
out, name, first, last, step = a[0], a[1], int(a[2]), int(a[3]), int(a[4])
yaw = math.radians(float(a[5])) if len(a) > 5 else math.radians(60)
sc = gc.reset_scene(name)
objs = gc.import_glb(os.path.join(gc.MODELS, f"{name}.glb"), hide=("Icosphere",))
root, _ = gc.normalize(objs, 7.0, rot=(0, 0, yaw), name="S")
for x in bpy.data.objects:
    if x.type == "CAMERA":
        x.hide_render = True
print("ACTIONS", [(x.name, tuple(int(v) for v in x.frame_range)) for x in bpy.data.actions], "markers", [(m.name, m.frame) for x in bpy.data.actions for m in x.pose_markers])
sc.render.engine = "BLENDER_WORKBENCH"
sc.display.shading.light, sc.display.shading.color_type = "STUDIO", "TEXTURE"
sc.render.resolution_x = sc.render.resolution_y = 260
sc.render.film_transparent = False
cam = gc.setup_camera(sc, elev_deg=8)
cam.data.lens = 34
os.makedirs(out, exist_ok=True)
for f in range(first, last + 1, step):
    sc.frame_set(f)
    sc.render.filepath = os.path.join(out, f"{name}_{f:04d}.png")
    bpy.ops.render.render(write_still=True)
