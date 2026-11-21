"""blender -b --factory-startup -P grid_sheet.py -- <out_dir> <model> <size> <rx> <ry> <rz> [hide substrings]: normalized side + front stills with 0.5-unit grid labels."""
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402

a = sys.argv[sys.argv.index("--") + 1:]
out, name, size = a[0], a[1], float(a[2])
rot = tuple(math.radians(float(x)) for x in a[3:6])
sc = gc.reset_scene(name)
objs = gc.import_glb(os.path.join(gc.MODELS, f"{name}.glb"), hide=("Icosphere", *a[6:]))
for o in objs:   # autorig uses the bind pose, so measure it
    if o.type == "MESH":
        for mod in [m for m in o.modifiers if m.type == "ARMATURE"]:
            o.modifiers.remove(mod)
root, model = gc.normalize(objs, size, rot=rot)
meshes = [o for o in objs if o.type == "MESH" and not o.hide_render]
print("MESHES", [(o.name, len(o.data.vertices), [s.name for s in o.data.materials]) for o in meshes])
print("BBOX", gc.world_bbox(meshes))
sc.render.engine = "BLENDER_WORKBENCH"
sc.display.shading.light, sc.display.shading.color_type = "STUDIO", "TEXTURE"
sc.render.resolution_x = sc.render.resolution_y = 800
sc.render.film_transparent = True
half = size * 0.56
cam = bpy.data.objects.new("C", bpy.data.cameras.new("C"))
sc.collection.objects.link(cam)
sc.camera = cam
cam.data.type, cam.data.ortho_scale = "ORTHO", 2 * half
cam.data.clip_end = 1000.0
for label, loc, rot_e in (("xz", (0, -size * 3, 0), (math.pi / 2, 0, 0)), ("yz", (size * 3, 0, 0), (math.pi / 2, 0, math.pi / 2)), ("xy", (0, 0, size * 3), (0, 0, 0))):
    cam.location, cam.rotation_euler = loc, rot_e
    sc.render.filepath = os.path.join(out, f"{name}_{label}.png")
    bpy.ops.render.render(write_still=True)
print("GRID half", half)
