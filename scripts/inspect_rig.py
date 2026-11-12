"""blender -b -P inspect_rig.py -- <model.glb>: armature bones, actions (frame ranges, animated bones), shape keys."""
import sys

import bpy

glb = sys.argv[sys.argv.index("--") + 1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=glb)
for a in bpy.data.actions:
    bones = sorted({fc.data_path.split('"')[1] for fc in a.fcurves if fc.data_path.startswith("pose.bones")})
    print("ACTION", a.name, tuple(a.frame_range), "bones", len(bones))
for o in bpy.data.objects:
    if o.type == "ARMATURE":
        print("ARMATURE", o.name, len(o.data.bones), "dims", tuple(round(d, 2) for d in o.dimensions))
        for b in o.data.bones:
            print("  BONE", b.name, "<-", b.parent.name if b.parent else "-")
    elif o.type == "MESH":
        sk = [k.name for k in o.data.shape_keys.key_blocks] if o.data.shape_keys else []
        print("MESH", o.name, len(o.data.vertices), [m.name for m in o.data.materials], "shapekeys", sk[:20])
