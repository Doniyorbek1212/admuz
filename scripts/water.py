"""Ocean patch for yacht and dolphin: Ocean modifier surface that fades to alpha around a keyed centre, with foam."""
import bpy

WATER = (0.006, 0.075, 0.115)
FOAM = (0.86, 0.92, 0.95)


def _math(nt, op, a, b=None, clamp=False):
    n = nt.nodes.new("ShaderNodeMath")
    n.operation, n.use_clamp = op, clamp
    for i, v in enumerate((a, b)):
        if v is None:
            continue
        if isinstance(v, (int, float)):
            n.inputs[i].default_value = v
        else:
            nt.links.new(v, n.inputs[i])
    return n.outputs[0]


def _smooth(nt, value, lo, hi):
    n = nt.nodes.new("ShaderNodeMapRange")
    n.interpolation_type = "SMOOTHSTEP"
    n.inputs["From Min"].default_value, n.inputs["From Max"].default_value = lo, hi
    nt.links.new(value, n.inputs["Value"])
    return n.outputs[0]


def material(name, rx, ry, wake=False, center_keys=((1, 0.0),), wake_y=0.0, radius_keys=None):
    """rx, ry: fade radii about the keyed centre. wake: V of churned foam behind a hull travelling +X."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out = N("ShaderNodeOutputMaterial")
    geo, sep = N("ShaderNodeNewGeometry"), N("ShaderNodeSeparateXYZ")
    L(geo.outputs["Position"], sep.inputs[0])
    cx = N("ShaderNodeValue")
    cx.name = "CenterX"
    for f, v in center_keys:
        cx.outputs[0].default_value = v
        cx.outputs[0].keyframe_insert("default_value", frame=f)
    dx = _math(nt, "SUBTRACT", sep.outputs["X"], cx.outputs[0])
    nx = _math(nt, "DIVIDE", dx, rx)
    ny = _math(nt, "DIVIDE", sep.outputs["Y"], ry)
    r = _math(nt, "SQRT", _math(nt, "ADD", _math(nt, "MULTIPLY", nx, nx), _math(nt, "MULTIPLY", ny, ny)))
    if radius_keys:     # the patch grows out of nothing and shrinks away
        rad = N("ShaderNodeValue")
        rad.name = "Radius"
        for f, v in radius_keys:
            rad.outputs[0].default_value = v
            rad.outputs[0].keyframe_insert("default_value", frame=f)
        r = _math(nt, "DIVIDE", r, rad.outputs[0])
    edge = N("ShaderNodeMapRange")
    edge.interpolation_type = "SMOOTHSTEP"
    edge.inputs["From Min"].default_value, edge.inputs["From Max"].default_value = 0.45, 1.0
    edge.inputs["To Min"].default_value, edge.inputs["To Max"].default_value = 1.0, 0.0
    L(r, edge.inputs["Value"])
    b = N("ShaderNodeBsdfPrincipled")
    b.inputs["Base Color"].default_value = (*WATER, 1.0)
    b.inputs["Roughness"].default_value = 0.05
    b.inputs["IOR"].default_value = 1.33
    foam_attr = N("ShaderNodeAttribute")
    foam_attr.attribute_name = "foam"
    tex = N("ShaderNodeTexNoise")
    tex.inputs["Scale"].default_value = 7.0
    tex.inputs["Detail"].default_value = 8.0
    L(geo.outputs["Position"], tex.inputs["Vector"])
    breakup = _smooth(nt, tex.outputs["Fac"], 0.42, 0.62)
    foam = _math(nt, "MULTIPLY", _smooth(nt, foam_attr.outputs["Fac"], 0.25, 0.85), breakup)
    if wake:
        behind = _math(nt, "MULTIPLY", dx, -1.0)                 # distance behind the bow
        half = _math(nt, "ADD", _math(nt, "MULTIPLY", behind, 0.12), 0.3)
        dy = _math(nt, "ABSOLUTE", _math(nt, "SUBTRACT", sep.outputs["Y"], wake_y))
        side = _math(nt, "SUBTRACT", 1.0, _smooth(nt, _math(nt, "DIVIDE", dy, half), 0.7, 1.0))
        ahead = _smooth(nt, behind, -2.8, -2.2)
        trail = _math(nt, "MULTIPLY", side, ahead)
        churn = _math(nt, "MULTIPLY", trail, _smooth(nt, tex.outputs["Fac"], 0.47, 0.62))
        foam = _math(nt, "MAXIMUM", foam, churn)
    mixc = N("ShaderNodeMix")
    mixc.data_type = "RGBA"
    mixc.inputs["A"].default_value, mixc.inputs["B"].default_value = (*WATER, 1.0), (*FOAM, 1.0)
    L(foam, mixc.inputs["Factor"])
    L(mixc.outputs["Result"], b.inputs["Base Color"])
    rough = N("ShaderNodeMapRange")
    rough.inputs["To Min"].default_value, rough.inputs["To Max"].default_value = 0.05, 0.7
    L(foam, rough.inputs["Value"])
    L(rough.outputs["Result"], b.inputs["Roughness"])
    tr, mix = N("ShaderNodeBsdfTransparent"), N("ShaderNodeMixShader")
    L(edge.outputs["Result"], mix.inputs[0])
    L(tr.outputs[0], mix.inputs[1])
    L(b.outputs[0], mix.inputs[2])
    L(mix.outputs[0], out.inputs["Surface"])
    return m


def patch(sc, name, z, total, mat, span=30.0, wave=0.32, chop=0.9, res=9, x=0.0, wind=9.0, y=0.0, foam=True):
    """Static ocean grid with moving waves; the material decides which part is visible."""
    me = bpy.data.meshes.new(name)
    ob = bpy.data.objects.new(name, me)
    sc.collection.objects.link(ob)
    ob.location = (x, y, z)
    ob.cycles.use_motion_blur = False
    ob.visible_shadow = False
    mod = ob.modifiers.new("Ocean", "OCEAN")
    mod.geometry_mode = "GENERATE"
    mod.resolution, mod.viewport_resolution = res, 5
    mod.spatial_size, mod.repeat_x, mod.repeat_y = int(span), 1, 1
    mod.wave_scale, mod.choppiness, mod.wind_velocity = wave, chop, wind
    mod.wave_scale_min = 0.01
    mod.use_foam, mod.foam_layer_name, mod.foam_coverage = foam, "foam", 0.15
    mod.use_normals = True
    mod.time = 1.0
    ob.keyframe_insert('modifiers["Ocean"].time', frame=1)
    mod.time = 1.0 + total / 24.0
    ob.keyframe_insert('modifiers["Ocean"].time', frame=total)
    for fc in ob.animation_data.action.fcurves:
        for kp in fc.keyframe_points:
            kp.interpolation = "LINEAR"
    me.materials.append(mat)
    return ob
