"""blender -b -P dump_textures.py -- <model.glb> <out_dir> : save every base-color texture (max 1024 px) + material map."""
import os
import sys

import bpy

args = sys.argv[sys.argv.index("--") + 1:]
glb, out_dir = args[0], args[1]
os.makedirs(out_dir, exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=glb)
for m in bpy.data.materials:
    if not m.use_nodes:
        continue
    for n in m.node_tree.nodes:
        if n.type != "TEX_IMAGE" or not n.image:
            continue
        links = [l.to_socket.name for l in n.outputs["Color"].links]
        print("MATTEX", m.name, "|", n.image.name, "|", n.image.size[:], "|", links)
        if "Base Color" not in links:
            continue
        img = n.image.copy()
        w, h = img.size
        k = min(1.0, 1024 / max(w, h))
        img.scale(max(1, int(w * k)), max(1, int(h * k)))
        img.filepath_raw = os.path.join(out_dir, f"{m.name}__{n.image.name}.png".replace("/", "_"))
        img.file_format = "PNG"
        img.save()
