"""blender -b dragon_{show,icon}.blend -P fix_dragon.py -- <out_dir> <first> <last>: re-render a baked dragon with the final fire look."""
import os
import sys

import bpy

a = sys.argv[sys.argv.index("--") + 1:]
out, first, last = a[0], int(a[1]), int(a[2])
prefs = bpy.context.preferences.addons["cycles"].preferences
prefs.compute_device_type = "OPTIX"
prefs.get_devices()
for d in prefs.devices:
    d.use = d.type == "OPTIX"
sc = bpy.context.scene
sc.view_settings.view_transform, sc.view_settings.look = "Filmic", "Medium High Contrast"
nt = bpy.data.materials["DragonFire"].node_tree
ramp = next(n for n in nt.nodes if n.type == "VALTORGB")
flame = next(n for n in nt.nodes if n.type == "ATTRIBUTE" and n.attribute_name == "flame")
emul = next(m for m in nt.nodes if m.type == "MATH" and m.inputs[1].default_value not in (0.9,) and any(l.to_socket.name == "Emission Strength" for l in m.outputs[0].links))
pw = nt.nodes.new("ShaderNodeMath")
pw.operation, pw.inputs[1].default_value = "POWER", 2.0
nt.links.new(flame.outputs["Fac"], pw.inputs[0])
nt.links.new(pw.outputs[0], ramp.inputs["Fac"])
nt.links.new(pw.outputs[0], emul.inputs[0])
emul.inputs[1].default_value = 30.0
sc.frame_start, sc.frame_end = first, last
sc.render.filepath = os.path.join(out, "f_")
sc.render.use_overwrite = True
bpy.ops.render.render(animation=True)
print("FIX_DONE")
