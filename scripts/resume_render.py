"""blender -b <file.blend> -P resume_render.py -- <out_dir> <first> <last> [overwrite]
Continue an interrupted render from its saved .blend; finished frames are skipped, so it is safe to re-run after a crash."""
import os
import sys

import bpy

a = sys.argv[sys.argv.index("--") + 1:]
out, first, last = a[0], int(a[1]), int(a[2])
overwrite = "overwrite" in a[3:]
# compute device lives in user prefs, not the .blend
prefs = bpy.context.preferences.addons["cycles"].preferences
prefs.compute_device_type = "OPTIX"
prefs.get_devices()
for d in prefs.devices:
    d.use = d.type == "OPTIX"
assert any(d.use for d in prefs.devices), "no OptiX device"
sc = bpy.context.scene
assert sc.cycles.device == "GPU", sc.cycles.device
sc.frame_start, sc.frame_end = first, last
sc.render.filepath = os.path.join(out, "f_")
sc.render.use_overwrite = overwrite
sc.render.use_placeholder = False
bpy.ops.render.render(animation=True)
print("RESUME_DONE", out, first, last)
