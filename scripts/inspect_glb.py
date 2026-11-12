import bpy, sys
from mathutils import Vector
path = sys.argv[sys.argv.index("--") + 1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=path)
dg = bpy.context.evaluated_depsgraph_get()
lo, hi = Vector((1e9,) * 3), Vector((-1e9,) * 3)
for o in bpy.context.scene.objects:
    if o.type == "MESH":
        for c in o.bound_box:
            w = o.matrix_world @ Vector(c)
            lo = Vector(map(min, lo, w)); hi = Vector(map(max, hi, w))
print("FILE", path.split("\\")[-1])
print("BBOX min", tuple(round(v, 2) for v in lo), "max", tuple(round(v, 2) for v in hi), "size", tuple(round(v, 2) for v in hi - lo))
print("ACTIONS", [(a.name, tuple(map(int, a.frame_range))) for a in bpy.data.actions])
for o in bpy.context.scene.objects:
    if o.type in ("MESH", "ARMATURE") or o.animation_data:
        dims = tuple(round(v, 2) for v in o.dimensions)
        loc = tuple(round(v, 2) for v in o.matrix_world.translation)
        mats = [m.name for m in getattr(o.data, "materials", []) if m] if o.type == "MESH" else []
        nverts = len(o.data.vertices) if o.type == "MESH" else 0
        print(f"OBJ {o.type:8} {o.name[:40]:40} v={nverts:7} dims={dims} loc={loc} anim={bool(o.animation_data and o.animation_data.action)} mats={mats[:4]}")
for m in bpy.data.materials:
    imgs = [n.image.name for n in m.node_tree.nodes if n.type == "TEX_IMAGE" and n.image] if m.use_nodes else []
    print("MAT", m.name, imgs)
