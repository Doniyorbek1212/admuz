"""blender -b --factory-startup -P inspect_all.py -- a.glb b.glb ...: one line of facts per model."""
import sys, os, bpy
from mathutils import Vector
for path in sys.argv[sys.argv.index("--") + 1:]:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=path)
    bpy.context.view_layer.update()
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    arms = [o for o in bpy.data.objects if o.type == "ARMATURE"]
    pts = [o.matrix_world @ Vector(c) for o in meshes for c in o.bound_box]
    lo = [round(min(p[i] for p in pts), 2) for i in range(3)]; hi = [round(max(p[i] for p in pts), 2) for i in range(3)]
    tris = sum(len(o.data.polygons) for o in meshes)
    print("MODEL", os.path.basename(path), "meshes", len(meshes), "polys", tris, "bbox", lo, hi)
    print("  names", [o.name for o in meshes][:14])
    print("  mats", sorted({s.name for o in meshes for s in o.data.materials})[:14])
    for a in arms:
        print("  arm", a.name, "bones", len(a.data.bones), [b.name for b in a.data.bones][:40])
    print("  anims", [(x.name, tuple(int(v) for v in x.frame_range)) for x in bpy.data.actions][:12])
