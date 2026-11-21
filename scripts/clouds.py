"""Procedural cloud volumes for balloon and castle: noise shaped by an ellipsoid falloff, so edges never show the box."""
import bpy


def material(name, rgb=(1.0, 0.98, 0.95), density=6.0, scale=2.4, threshold=0.46, drift=None, fade=None, glow=None):
    """drift: [(frame, (x, y, z))] noise offset keys so the shape billows. fade: [(frame, value)] keys a density multiplier."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out, vol = N("ShaderNodeOutputMaterial"), N("ShaderNodeVolumePrincipled")
    vol.inputs["Color"].default_value = (*rgb, 1.0)
    vol.inputs["Anisotropy"].default_value = 0.4
    tc = N("ShaderNodeTexCoord")
    add = N("ShaderNodeVectorMath")
    L(tc.outputs["Object"], add.inputs[0])
    if drift:
        for f, v in drift:
            add.inputs[1].default_value = v
            add.inputs[1].keyframe_insert("default_value", frame=f)
    noise = N("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = scale
    noise.inputs["Detail"].default_value = 7.0
    noise.inputs["Roughness"].default_value = 0.56
    L(add.outputs[0], noise.inputs["Vector"])
    ln = N("ShaderNodeVectorMath")
    ln.operation = "LENGTH"
    L(tc.outputs["Object"], ln.inputs[0])
    shape = N("ShaderNodeMapRange")           # unit cube object space: 1 at the centre, 0 before the faces
    shape.interpolation_type = "SMOOTHSTEP"
    shape.inputs["From Min"].default_value, shape.inputs["From Max"].default_value = 0.2, 0.98
    shape.inputs["To Min"].default_value, shape.inputs["To Max"].default_value = 1.0, 0.0
    L(ln.outputs["Value"], shape.inputs["Value"])
    cut = N("ShaderNodeMapRange")
    cut.inputs["From Min"].default_value, cut.inputs["From Max"].default_value = threshold, threshold + 0.22
    cut.clamp = True
    L(noise.outputs["Fac"], cut.inputs["Value"])
    mul = N("ShaderNodeMath")
    mul.operation = "MULTIPLY"
    L(cut.outputs[0], mul.inputs[0])
    L(shape.outputs[0], mul.inputs[1])
    gain = N("ShaderNodeMath")
    gain.operation = "MULTIPLY"
    gain.inputs[1].default_value = density
    L(mul.outputs[0], gain.inputs[0])
    if fade:
        for f, v in fade:
            gain.inputs[1].default_value = density * v
            gain.inputs[1].keyframe_insert("default_value", frame=f)
    L(gain.outputs[0], vol.inputs["Density"])
    if glow:
        vol.inputs["Emission Color"].default_value = (*glow[0], 1.0)
        L(gain.outputs[0], (s := N("ShaderNodeMath")).inputs[0])
        s.operation, s.inputs[1].default_value = "MULTIPLY", glow[1]
        L(s.outputs[0], vol.inputs["Emission Strength"])
    L(vol.outputs[0], out.inputs["Volume"])
    return m


def layer(name, half, rgb=(1.0, 0.98, 0.95), density=5.0, detail=1.1, lump=0.32, threshold=0.36, drift=None, fade=None, glow=None):
    """One sheet of cumulus in a box of half extents `half`: a lumpy top from a coarse noise, fine detail cut from a second
    noise, and a soft edge to nothing on every side. Noise runs in world units, so it is not stretched by the box."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new

    def math_node(op, a, b=None):
        n = N("ShaderNodeMath")
        n.operation = op
        for i, v in enumerate((a, b)):
            if isinstance(v, (int, float)):
                n.inputs[i].default_value = v
            elif v is not None:
                L(v, n.inputs[i])
        return n.outputs[0]

    def ramp(v, lo, hi, to=(0.0, 1.0)):
        n = N("ShaderNodeMapRange")
        n.interpolation_type = "SMOOTHSTEP"
        n.inputs["From Min"].default_value, n.inputs["From Max"].default_value = lo, hi
        n.inputs["To Min"].default_value, n.inputs["To Max"].default_value = to
        L(v, n.inputs["Value"])
        return n.outputs[0]

    out, vol, tc, sep = N("ShaderNodeOutputMaterial"), N("ShaderNodeVolumePrincipled"), N("ShaderNodeTexCoord"), N("ShaderNodeSeparateXYZ")
    vol.inputs["Color"].default_value = (*rgb, 1.0)
    vol.inputs["Anisotropy"].default_value = 0.4
    L(tc.outputs["Object"], sep.inputs[0])
    world = N("ShaderNodeVectorMath")
    world.operation = "MULTIPLY"
    world.inputs[1].default_value = half
    L(tc.outputs["Object"], world.inputs[0])
    add = N("ShaderNodeVectorMath")
    L(world.outputs[0], add.inputs[0])
    if drift:
        for f, v in drift:
            add.inputs[1].default_value = v
            add.inputs[1].keyframe_insert("default_value", frame=f)
    coarse, fine = N("ShaderNodeTexNoise"), N("ShaderNodeTexNoise")
    coarse.inputs["Scale"].default_value, coarse.inputs["Detail"].default_value = 0.42, 2.0
    fine.inputs["Scale"].default_value, fine.inputs["Detail"].default_value, fine.inputs["Roughness"].default_value = detail, 8.0, 0.58
    L(add.outputs[0], coarse.inputs["Vector"])
    L(add.outputs[0], fine.inputs["Vector"])
    # top surface height in box space, and how far under it this point is
    top = math_node("ADD", math_node("MULTIPLY", math_node("SUBTRACT", coarse.outputs["Fac"], 0.5), lump / 0.25), 0.25)
    under = math_node("SUBTRACT", top, sep.outputs["Z"])
    body = ramp(under, 0.0, 0.3)
    floor = ramp(sep.outputs["Z"], -0.62, -0.12)
    side = math_node("MULTIPLY", ramp(math_node("ABSOLUTE", sep.outputs["X"]), 0.5, 0.97, (1.0, 0.0)), ramp(math_node("ABSOLUTE", sep.outputs["Y"]), 0.6, 0.97, (1.0, 0.0)))
    cut = N("ShaderNodeMapRange")
    cut.inputs["From Min"].default_value, cut.inputs["From Max"].default_value = threshold, threshold + 0.16
    cut.clamp = True
    L(fine.outputs["Fac"], cut.inputs["Value"])
    total = math_node("MULTIPLY", math_node("MULTIPLY", math_node("MULTIPLY", body, floor), side), cut.outputs[0])
    gain = N("ShaderNodeMath")
    gain.operation = "MULTIPLY"
    gain.inputs[1].default_value = density
    L(total, gain.inputs[0])
    if fade:
        for f, v in fade:
            gain.inputs[1].default_value = density * v
            gain.inputs[1].keyframe_insert("default_value", frame=f)
    L(gain.outputs[0], vol.inputs["Density"])
    if glow:
        vol.inputs["Emission Color"].default_value = (*glow[0], 1.0)
        L(math_node("MULTIPLY", gain.outputs[0], glow[1]), vol.inputs["Emission Strength"])
    L(vol.outputs[0], out.inputs["Volume"])
    return m


def cloud(sc, name, location, half, mat, keys=None):
    """A cube of half extents `half`. keys: [(frame, (x, y, z))] for its location."""
    bpy.ops.mesh.primitive_cube_add(size=2.0, location=location)
    ob = bpy.context.active_object
    ob.name = name
    ob.scale = half
    ob.data.materials.append(mat)
    ob.cycles.use_motion_blur = False
    ob.visible_shadow = True
    if keys:
        for f, loc in keys:
            ob.location = loc
            ob.keyframe_insert("location", frame=f)
    return ob
