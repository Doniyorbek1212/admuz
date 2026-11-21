"""Mantaflow gas helpers shared by rocket, phoenix and hot-air-balloon: domain, moving flow, fire and smoke material.

Always keep use_motion_blur off on the domain: velocity blur dilates the volume mesh by the flow speed and one frame
then takes 10+ minutes in "Computing Volume Mesh". Bake with `bake(sc, dom)`; "Invalid dt" prints are not fatal.
"""
import os

import bpy

import gift_common as gc
import show_common as sh


def domain(sc, gift_id, center, half, total, mat, res=128, vorticity=0.6, burn=0.55, flame_smoke=0.15, flame_vort=1.2, max_temp=3.0,
           dissolve=18, alpha=0.0, beta=0.0, name="GasDomain"):
    """Cube domain with half extents `half`; returns the object. alpha/beta: smoke buoyancy; dissolve frames, 0 keeps smoke."""
    bpy.ops.mesh.primitive_cube_add(size=2.0, location=center)
    dom = bpy.context.active_object
    dom.name = name
    dom.scale = half
    mod = dom.modifiers.new("Fluid", "FLUID")
    mod.fluid_type = "DOMAIN"
    ds = mod.domain_settings
    ds.domain_type = "GAS"
    ds.resolution_max = res
    ds.vorticity = vorticity
    ds.alpha, ds.beta = alpha, beta
    ds.burning_rate, ds.flame_smoke, ds.flame_vorticity = burn, flame_smoke, flame_vort
    ds.flame_max_temp = max_temp
    ds.use_dissolve_smoke = dissolve > 0
    if dissolve:
        ds.dissolve_speed = dissolve
    ds.cache_directory = os.path.join(sh.src_dir(gift_id), f"cache_{name}")
    ds.cache_type = "ALL"
    ds.cache_frame_start, ds.cache_frame_end = 1, total
    dom.data.materials.append(mat)
    dom.cycles.use_motion_blur = False
    return dom


def flow(sc, name, radius, location, velocity=None, behavior="BOTH", surface=0.12, parent=None, subdiv=2):
    """Invisible inflow ball. Key fuel/density with key_flow."""
    src = bpy.data.objects.new(name, gc.ico_mesh(name, radius, subdiv))
    sc.collection.objects.link(src)
    src.hide_render = True
    src.location = location
    if parent:
        src.parent = parent
    fm = src.modifiers.new("Fluid", "FLUID")
    fm.fluid_type = "FLOW"
    fs = fm.flow_settings
    fs.flow_type, fs.flow_behavior, fs.flow_source = behavior, "INFLOW", "MESH"
    fs.surface_distance = surface
    if velocity is not None:
        fs.use_initial_velocity = True
        fs.velocity_coord = velocity
    return src


def key_flow(src, keys):
    """keys: [(frame, fuel, density)]"""
    fs = src.modifiers["Fluid"].flow_settings
    for f, fuel, dens in keys:
        fs.fuel_amount, fs.density = fuel, dens
        src.keyframe_insert('modifiers["Fluid"].flow_settings.fuel_amount', frame=f)
        src.keyframe_insert('modifiers["Fluid"].flow_settings.density', frame=f)


def bake(sc, dom):
    with bpy.context.temp_override(scene=sc, object=dom, active_object=dom):
        bpy.ops.fluid.bake_all()


def filmic(sc):
    """AgX turns fire salmon; Filmic keeps it orange. Call on every show with real fire."""
    sc.view_settings.view_transform, sc.view_settings.look = "Filmic", "Medium High Contrast"


def material(name, smoke_rgb=(0.12, 0.1, 0.09), density=0.9, emission=30.0, ramp=None, edge_fade=None, anisotropy=0.0, flame_power=2.0, smoke_glow=0.0):
    """Principled volume driven by density/flame attributes. ramp: [(pos, rgba)] fire colours.
    edge_fade: (x, y, z) width in domain 0..1 of a soft border on that axis, so smoke never ends at a hard box edge."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out = N("ShaderNodeOutputMaterial")
    vol = N("ShaderNodeVolumePrincipled")
    vol.inputs["Color"].default_value = (*smoke_rgb, 1.0)
    vol.inputs["Anisotropy"].default_value = anisotropy
    dens = N("ShaderNodeAttribute")
    dens.attribute_name = "density"
    dmul = N("ShaderNodeMath")
    dmul.operation, dmul.inputs[1].default_value = "MULTIPLY", density
    L(dens.outputs["Fac"], dmul.inputs[0])
    d_out = dmul.outputs[0]
    if edge_fade:
        tc = N("ShaderNodeTexCoord")
        sep = N("ShaderNodeSeparateXYZ")
        L(tc.outputs["Generated"], sep.inputs[0])
        for axis, width in zip("XYZ", edge_fade):
            if not width:
                continue
            for lo, hi in ((0.0, width), (1.0, 1.0 - width)):
                mr = N("ShaderNodeMapRange")
                mr.interpolation_type = "SMOOTHSTEP"
                mr.inputs["From Min"].default_value, mr.inputs["From Max"].default_value = lo, hi
                L(sep.outputs[axis], mr.inputs["Value"])
                mul = N("ShaderNodeMath")
                mul.operation = "MULTIPLY"
                L(d_out, mul.inputs[0])
                L(mr.outputs[0], mul.inputs[1])
                d_out = mul.outputs[0]
    L(d_out, vol.inputs["Density"])
    if emission:
        flame = N("ShaderNodeAttribute")
        flame.attribute_name = "flame"
        pw = N("ShaderNodeMath")     # contrast: hot core, licking edges
        pw.operation, pw.inputs[1].default_value = "POWER", flame_power
        L(flame.outputs["Fac"], pw.inputs[0])
        r = N("ShaderNodeValToRGB")
        els = r.color_ramp.elements
        els[0].position, els[0].color = 0.0, (0.0, 0.0, 0.0, 1.0)
        els[1].position, els[1].color = 1.0, (1.0, 0.92, 0.7, 1.0)
        for pos, col in (ramp or ((0.12, (0.85, 0.07, 0.005, 1.0)), (0.45, (1.0, 0.28, 0.01, 1.0)), (0.8, (1.0, 0.62, 0.08, 1.0)))):
            e = els.new(pos)
            e.color = col
        L(pw.outputs[0], r.inputs["Fac"])
        L(r.outputs["Color"], vol.inputs["Emission Color"])
        fmul = N("ShaderNodeMath")
        fmul.operation, fmul.inputs[1].default_value = "MULTIPLY", emission
        L(pw.outputs[0], fmul.inputs[0])
        L(fmul.outputs[0], vol.inputs["Emission Strength"])
    if smoke_glow:
        glow, add, g = N("ShaderNodeEmission"), N("ShaderNodeAddShader"), N("ShaderNodeMath")
        g.operation, g.inputs[1].default_value = "MULTIPLY", smoke_glow
        L(d_out, g.inputs[0])
        L(g.outputs[0], glow.inputs["Strength"])
        glow.inputs["Color"].default_value = (*smoke_rgb, 1.0)
        L(vol.outputs[0], add.inputs[0])
        L(glow.outputs[0], add.inputs[1])
        L(add.outputs[0], out.inputs["Volume"])
    else:
        L(vol.outputs[0], out.inputs["Volume"])
    return m
