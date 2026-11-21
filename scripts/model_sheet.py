"""blender -b --factory-startup -P model_sheet.py -- <out_dir> name1 name2 ...: front (-Y) and side (+X) workbench stills per model."""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402

TILE = 300


def still(sc, cam, c, half, direction, path):
    d = Vector(direction).normalized()
    cam.location = c + d * half * 6
    cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
    cam.data.lens = 36 / 2 * 6 / (half * 1.1) * half
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


def main():
    a = sys.argv[sys.argv.index("--") + 1:]
    out, names = a[0], a[1:]
    os.makedirs(out, exist_ok=True)
    for name in names:
        sc = gc.reset_scene(name)
        objs = gc.import_glb(os.path.join(gc.MODELS, f"{name}.glb"))
        for o in objs:   # glTF "Icosphere" light-probe stand-ins and huge skyboxes hide the subject
            if o.name.startswith("Icosphere"):
                o.hide_render = True
        meshes = [o for o in objs if o.type == "MESH" and not o.hide_render]
        lo, hi = gc.world_bbox(meshes)
        c, half = (lo + hi) / 2, max(hi - lo) / 2
        sc.render.engine = "BLENDER_WORKBENCH"
        sc.display.shading.light = "STUDIO"
        sc.display.shading.color_type = "TEXTURE"
        sc.render.resolution_x = sc.render.resolution_y = TILE
        sc.render.film_transparent = False
        sc.display.render_aa = "FXAA"
        cam = bpy.data.objects.new("C", bpy.data.cameras.new("C"))
        sc.collection.objects.link(cam)
        sc.camera = cam
        cam.data.clip_end = half * 40
        cam.data.clip_start = half * 0.05
        still(sc, cam, c, half, (0, -1, 0.0), os.path.join(out, f"{name}_front.png"))
        still(sc, cam, c, half, (1, 0, 0.0), os.path.join(out, f"{name}_side.png"))
        print("SHEET_OK", name, flush=True)


main()
