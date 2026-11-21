"""Shared gold and gem materials for crown and ring: spectral dispersion by three glass lobes at different IOR."""
import bpy

import stage


def gold(name="Gold", roughness=0.14):
    return stage.pbr(name, (1.0, 0.68, 0.25), metallic=1.0, roughness=roughness)


def diamond(name="Diamond", tint=(1.0, 1.0, 1.0), spread=0.05, ior=2.42):
    """Add three tinted Glass BSDFs (R/G/B at IOR -spread/0/+spread): each colour bends differently, which is what gives fire."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out = N("ShaderNodeOutputMaterial")
    lobes = []
    for rgb, d in (((1, 0, 0), -spread), ((0, 1, 0), 0.0), ((0, 0, 1), spread)):
        g = N("ShaderNodeBsdfGlass")
        g.inputs["Color"].default_value = (rgb[0] * tint[0], rgb[1] * tint[1], rgb[2] * tint[2], 1.0)
        g.inputs["Roughness"].default_value = 0.0
        g.inputs["IOR"].default_value = ior + d
        lobes.append(g)
    a1, a2 = N("ShaderNodeAddShader"), N("ShaderNodeAddShader")
    L(lobes[0].outputs[0], a1.inputs[0])
    L(lobes[1].outputs[0], a1.inputs[1])
    L(a1.outputs[0], a2.inputs[0])
    L(lobes[2].outputs[0], a2.inputs[1])
    L(a2.outputs[0], out.inputs["Surface"])
    return m


def setup_gems(sc):
    """Gems must see the world through themselves: transparent glass would punch holes in the alpha."""
    sc.cycles.film_transparent_glass = False
    sc.cycles.max_bounces, sc.cycles.transmission_bounces, sc.cycles.glossy_bounces = 14, 14, 10
    sc.cycles.sample_clamp_indirect = 40.0
