"""Quick orientation check: blender -b -P lookdev.py -- <model.glb> <out_dir> [hide,names]"""
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402

args = sys.argv[sys.argv.index("--") + 1:]
glb, out_dir = args[0], args[1]
hide = tuple(h for h in (args[2].split(",") if len(args) > 2 else []) if h)
name = os.path.splitext(os.path.basename(glb))[0]

sc = gc.reset_scene("Lookdev")
objs = gc.import_glb(glb, hide)
root, model = gc.normalize(objs, 7.0, name="Look")
lo, hi, size = gc.bbox_of(objs)
print("NORM_BBOX", tuple(round(v, 2) for v in lo), tuple(round(v, 2) for v in hi))
gc.setup_render(sc, "", res=(360, 640), samples=16)
gc.setup_world(sc)
gc.setup_camera(sc)
gc.setup_lights(sc, follow=root)
sc.frame_set(1)
for deg in (0, 90, 180, 270):
    root.rotation_euler = (0, 0, math.radians(deg))
    sc.render.filepath = os.path.join(out_dir, f"{name}_z{deg:03d}.png")
    bpy.ops.render.render(write_still=True)
