"""Reusable Cycles FX for the gift shows: particles that fade over their life, ground shockwave ring."""
import math

import bpy

import gift_common as gc


def fade_material(name, rgb, strength, alpha=1.0, power=1.5):
    """Emission that fades to transparent over each particle's life (Particle Info age / lifetime)."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out = N("ShaderNodeOutputMaterial")
    pi = N("ShaderNodeParticleInfo")
    div = N("ShaderNodeMath")
    div.operation = "DIVIDE"
    L(pi.outputs["Age"], div.inputs[0])
    L(pi.outputs["Lifetime"], div.inputs[1])
    inv = N("ShaderNodeMath")
    inv.operation, inv.use_clamp = "SUBTRACT", True
    inv.inputs[0].default_value = 1.0
    L(div.outputs[0], inv.inputs[1])
    pw = N("ShaderNodeMath")
    pw.operation = "POWER"
    pw.inputs[1].default_value = power
    L(inv.outputs[0], pw.inputs[0])
    mul = N("ShaderNodeMath")
    mul.operation = "MULTIPLY"
    mul.inputs[1].default_value = alpha
    L(pw.outputs[0], mul.inputs[0])
    # soft puff: opaque facing the camera, nothing at the silhouette, so instances never read as polygons
    lw = N("ShaderNodeLayerWeight")
    lw.inputs["Blend"].default_value = 0.5
    soft = N("ShaderNodeMapRange")
    soft.interpolation_type = "SMOOTHSTEP"
    soft.inputs["From Min"].default_value, soft.inputs["From Max"].default_value = 0.72, 0.1
    L(lw.outputs["Facing"], soft.inputs["Value"])
    mul2 = N("ShaderNodeMath")
    mul2.operation = "MULTIPLY"
    L(mul.outputs[0], mul2.inputs[0])
    L(soft.outputs[0], mul2.inputs[1])
    _emit_mix(nt, rgb, strength, mul2.outputs[0], out)
    return m


def _emit_mix(nt, rgb, strength, fac_socket, out):
    N, L = nt.nodes.new, nt.links.new
    em = N("ShaderNodeEmission")
    em.inputs["Color"].default_value = (*rgb, 1.0)
    em.inputs["Strength"].default_value = strength
    tr = N("ShaderNodeBsdfTransparent")
    mix = N("ShaderNodeMixShader")
    L(fac_socket, mix.inputs[0])
    L(tr.outputs[0], mix.inputs[1])
    L(em.outputs[0], mix.inputs[2])
    L(mix.outputs[0], out.inputs["Surface"])


def _no_shadow(ob):
    ob.visible_shadow = False


def particle_burst(sc, name, emitter_mesh, mat, count, frames, lifetime, size, speed, rand=0.5,
                   align=(0.0, 0.0, 0.0), damping=0.0, gravity=0.0, emit_from="FACE", location=(0, 0, 0)):
    """Glowing instanced particles; velocity = emitter normal * speed + align (emitter space)."""
    inst = bpy.data.objects.new(f"{name}Inst", gc.ico_mesh(f"{name}Inst", 1.0, 2))
    inst.data.polygons.foreach_set("use_smooth", [True] * len(inst.data.polygons))
    inst.data.materials.append(mat)
    sc.collection.objects.link(inst)
    inst.location = (0, 0, -1000)
    _no_shadow(inst)
    em = bpy.data.objects.new(f"{name}Emitter", emitter_mesh)
    sc.collection.objects.link(em)
    em.location = location
    em.show_instancer_for_render = em.show_instancer_for_viewport = False
    _no_shadow(em)
    em.modifiers.new(name, "PARTICLE_SYSTEM")
    st = em.particle_systems[0].settings
    st.count, st.frame_start, st.frame_end = count, frames[0], frames[1]
    st.lifetime, st.lifetime_random = lifetime, 0.5
    st.emit_from, st.use_emit_random = emit_from, True
    st.normal_factor, st.factor_random = speed, rand * max(speed, 1.0)
    st.object_align_factor = align
    st.damping = damping
    st.effector_weights.gravity = gravity
    st.render_type, st.instance_object = "OBJECT", inst
    st.particle_size, st.size_random = size, 0.7
    return em


def ring_mesh(name, radius, height=0.05, segs=96):
    """Open cylinder wall, normals outward: emits a radial burst."""
    verts, faces = [], []
    for i in range(segs):
        a = 2 * math.pi * i / segs
        c, s = radius * math.cos(a), radius * math.sin(a)
        verts += [(c, s, 0.0), (c, s, height)]
    for i in range(segs):
        j = (i + 1) % segs
        faces.append((2 * i, 2 * j, 2 * j + 1, 2 * i + 1))
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    return me


def point_mesh(name, radius=0.05):
    return gc.ico_mesh(name, radius, 1)


def shock_ring(sc, name, location, frames, r_end, rgb, strength, width=0.12):
    """Flat glowing ring on the ground that grows from 0 to r_end and fades out."""
    import bmesh
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_circle(bm, cap_ends=True, radius=1.0, segments=128)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    sc.collection.objects.link(ob)
    ob.location = location
    _no_shadow(ob)
    m = bpy.data.materials.new(f"{name}Mat")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out = N("ShaderNodeOutputMaterial")
    tc = N("ShaderNodeTexCoord")
    ln = N("ShaderNodeVectorMath")
    ln.operation = "LENGTH"
    L(tc.outputs["Object"], ln.inputs[0])
    d = N("ShaderNodeMath")                    # |r - edge| / width
    d.operation = "SUBTRACT"
    d.inputs[1].default_value = 1.0 - width
    L(ln.outputs["Value"], d.inputs[0])
    ab = N("ShaderNodeMath")
    ab.operation = "ABSOLUTE"
    L(d.outputs[0], ab.inputs[0])
    prof = N("ShaderNodeMapRange")              # 1 at the ring line, 0 one width away
    prof.inputs["From Min"].default_value = 0.0
    prof.inputs["From Max"].default_value = width
    prof.inputs["To Min"].default_value = 1.0
    prof.inputs["To Max"].default_value = 0.0
    L(ab.outputs[0], prof.inputs["Value"])
    sq = N("ShaderNodeMath")
    sq.operation = "POWER"
    sq.inputs[1].default_value = 3.0
    L(prof.outputs["Result"], sq.inputs[0])
    fade = N("ShaderNodeValue")
    fade.name = "Fade"
    mul = N("ShaderNodeMath")
    mul.operation, mul.use_clamp = "MULTIPLY", True
    L(sq.outputs[0], mul.inputs[0])
    L(fade.outputs[0], mul.inputs[1])
    _emit_mix(nt, rgb, strength, mul.outputs[0], out)
    ob.data.materials.append(m)
    f0, f1 = frames
    for f, s, v in ((f0 - 1, 0.01, 0.0), (f0, 0.05, 1.0), (f1, r_end, 0.0)):
        ob.scale = (s, s, s)
        ob.keyframe_insert("scale", frame=f)
        fade.outputs[0].default_value = v
        fade.outputs[0].keyframe_insert("default_value", frame=f)
    for fc in ob.animation_data.action.fcurves:   # fast out, slow in: a shockwave decelerates
        for kp in fc.keyframe_points:
            kp.interpolation, kp.easing = "EXPO", "EASE_OUT"
    return ob
