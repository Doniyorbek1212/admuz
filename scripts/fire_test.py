"""blender -b dragon_show.blend -P fire_test.py -- <out_dir> <frame>: fire ramp variants on the baked dragon, stills only."""
import os
import sys

import bpy

a = sys.argv[sys.argv.index("--") + 1:]
out, frame = a[0], int(a[1])
prefs = bpy.context.preferences.addons["cycles"].preferences
prefs.compute_device_type = "OPTIX"
prefs.get_devices()
for d in prefs.devices:
    d.use = d.type == "OPTIX"
sc = bpy.context.scene
sc.cycles.samples = 24
nt = bpy.data.materials["DragonFire"].node_tree
ramp_node = next(n for n in nt.nodes if n.type == "VALTORGB")
ramp = ramp_node.color_ramp
mult = [n for n in nt.nodes if n.type == "MATH"]
emul = next(m for m in mult if m.inputs[1].default_value == 9.0)
flame = next(n for n in nt.nodes if n.type == "ATTRIBUTE" and n.attribute_name == "flame")
pw = nt.nodes.new("ShaderNodeMath")
pw.operation = "POWER"
nt.links.new(flame.outputs["Fac"], pw.inputs[0])
nt.links.new(pw.outputs[0], ramp_node.inputs["Fac"])
nt.links.new(pw.outputs[0], emul.inputs[0])
ORANGE = ((0.12, (0.85, 0.07, 0.005)), (0.45, (1.0, 0.28, 0.01)), (0.8, (1.0, 0.62, 0.08)))
VARIANTS = {
    "a": ("Filmic", "Medium High Contrast", 12.0, 1.0, ORANGE),
    "b": ("Filmic", "Medium High Contrast", 30.0, 2.0, ORANGE),
    "c": ("Standard", "None", 4.0, 1.6, ORANGE),
}
for name, (view, look, em, power, cols) in VARIANTS.items():
    sc.view_settings.view_transform, sc.view_settings.look = view, look
    pw.inputs[1].default_value = power
    emul.inputs[1].default_value = em
    els = sorted(ramp.elements, key=lambda e: e.position)
    for e, (pos, c) in zip(els[1:-1], cols):
        e.position, e.color = pos, (*c, 1.0)
    sc.frame_set(frame)
    sc.render.filepath = os.path.join(out, f"fire_{name}.png")
    bpy.ops.render.render(write_still=True)
print("FIRE_DONE")
