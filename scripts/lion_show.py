"""UZARO lion show (tier 3): walks in, stops, lowers its head, turns to camera and roars, walks out.

blender -b --factory-startup -P lion_show.py -- <show|icon> [f=20,64,86] [s=16] [nohair]
Rig: Tarun.Teja "Realistic Lion 3D Model" (CC BY). Its roar take drives head/jaw/tongue/ears and is
layered on a procedural walk (quadruped.py); particle-hair mane with hair dynamics, crown on the head.
"""
import math
import os
import sys

import bpy
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Quaternion, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402
import quadruped as qp  # noqa: E402
import show_common as sh  # noqa: E402
import show_fx as fx  # noqa: E402

ID = "lion"
R = math.radians
TOTAL = 168                       # 7 s @ 24 fps
LION_SIZE = 5.9                   # longest bbox side, world units (frame is 8.1 wide at y=0)
HEADING = R(28)                   # walk direction: screen right, turned this much toward camera
GROUND_Z = -1.9
STOP_X = 0.25
GAIT = qp.Gait(cycle_dist=130.0)
CYCLE_FRAMES = 20
STOP_F, ROAR_F, GO_F = 62, 64, 106   # stop, roar take frame 0, start walking out
DECEL, ACCEL = 14, 10
ROAR_LEN = 52
SHOCK_F = ROAR_F + 19             # jaw passes ~2/3 open: shockwave, shake
PEAK_F = ROAR_F + 25
JAW_GAIN = 1.3
TURN_DEG, LOWER_DEG = 38.0, 10.0
FWD, UP, LAT = Vector((0, 0, -1)), Vector((0, -1, 0)), Vector((1, 0, 0))   # armature space
HEAD_CHAIN = ("RigNeck1_017", "RigNeck2_018", "RigNeck3_019", "RigHead_020")
TURN_SPLIT = (0.2, 0.25, 0.25, 0.3)
FACE = ("RigJaw1_021", "RigTongue1_022", "RigTongue2_023", "RigTongue3_024", "RigLEar1_025",
        "RigREar1_026", "RigLEye1_027", "RigREye1_028", "RigLEyelid1_029", "RigREyelid1_030")
ROAR_BONES = HEAD_CHAIN + FACE
TAIL = tuple(f"RigTail{i}_{43 + i:03d}" for i in range(1, 10))
SPINE = ("RigSpine1_08", "RigSpine2_00")
BODY, EYES = "Object_7", "Object_8"
MANE_LEN = 0.5
MANE_GUIDES = 1400                # simulated guide hairs; children fill the density


def smooth(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


def env(f, a, b):
    return smooth((f - a) / (b - a))


def parse():
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    opts = {"mode": a[0] if a else "show", "test": None, "samples": 64, "hair": True, "dyn": False}
    for t in a[1:]:
        if t.startswith("f="):
            opts["test"] = [int(x) for x in t[2:].split(",")]
        elif t.startswith("s="):
            opts["samples"] = int(t[2:])
        elif t == "dyn":
            opts["dyn"] = True
        elif t == "nohair":
            opts["hair"] = False
    if opts["mode"] not in ("show", "icon"):
        raise SystemExit(f"mode must be show|icon, got {opts['mode']}")
    return opts


# ------------------------------------------------------------------ rig
def load_lion(sc):
    objs = gc.import_glb(os.path.join(gc.MODELS, "lion_roar.glb"))
    for o in objs:
        if o.type == "MESH" and o.name not in (BODY, EYES):
            o.hide_render = True           # LOD1-4 and a helper sphere
    root, _ = gc.normalize(objs, LION_SIZE, name="Lion")
    arm = next(o for o in objs if o.type == "ARMATURE")
    roar = sample_roar(sc, arm, arm.animation_data.action)
    arm.animation_data.action = None
    for pb in arm.pose.bones:
        pb.rotation_mode = "QUATERNION"
        pb.matrix_basis.identity()         # clearing the action leaves its last pose on the bones
    return root, arm, bpy.data.objects[BODY], bpy.data.objects[EYES], roar


def sample_roar(sc, arm, act):
    """Roar take as per-frame deltas from its first frame (closed mouth): q = q0 @ D, loc = l0 + dl."""
    frames = []
    for a in range(ROAR_LEN + 1):
        sc.frame_set(a)
        frames.append({n: (arm.pose.bones[n].rotation_quaternion.copy(), arm.pose.bones[n].location.copy())
                       for n in ROAR_BONES})
    q0 = {n: frames[0][n][0] for n in ROAR_BONES}
    l0 = {n: frames[0][n][1] for n in ROAR_BONES}
    deltas = [{n: (q0[n].inverted() @ fr[n][0], fr[n][1] - l0[n]) for n in ROAR_BONES} for fr in frames]
    return {"q0": q0, "l0": l0, "d": deltas}


def roar_delta(roar, name, a):
    if a <= 0 or a >= ROAR_LEN:
        return Quaternion(), Vector()
    i = int(a)
    t = a - i
    (qa, la), (qb, lb) = roar["d"][i][name], roar["d"][i + 1][name]
    q = qa.slerp(qb, t)
    if name == "RigJaw1_021" and q.angle > 1e-4:
        q = Quaternion(q.axis, q.angle * JAW_GAIN)
    return q, la.lerp(lb, t)


def local_axis(arm, name, v):
    return (arm.data.bones[name].matrix_local.to_3x3().inverted() @ v).normalized()


def apply_base(arm, roar):
    for pb in arm.pose.bones:
        pb.matrix_basis.identity()
    for n in ROAR_BONES:
        pb = arm.pose.bones[n]
        pb.rotation_quaternion, pb.location = roar["q0"][n], roar["l0"][n]


def probe(arm, bone, axis, tip):
    """World displacement of `tip` bone's tail when `bone` turns +0.2 rad about its local axis."""
    pb = arm.pose.bones[bone]
    old = pb.rotation_quaternion.copy()
    bpy.context.view_layer.update()
    p0 = arm.matrix_world @ arm.pose.bones[tip].tail
    pb.rotation_quaternion = Quaternion(axis, 0.2) @ old
    bpy.context.view_layer.update()
    p1 = arm.matrix_world @ arm.pose.bones[tip].tail
    pb.rotation_quaternion = old
    bpy.context.view_layer.update()
    return p1 - p0


def chains(arm):
    names = [b.name for b in arm.data.bones]
    order = ("Leg1", "Leg2", "Leg3", "LegAnkle")
    return {k: [next(n for n in names if n.startswith(f"Rig{k}{o}_")) for o in order]
            for k in ("LB", "LF", "RB", "RF")}


def eval_verts(ob):
    dg = bpy.context.evaluated_depsgraph_get()
    oe = ob.evaluated_get(dg)
    me = oe.to_mesh()
    pts = [oe.matrix_world @ v.co for v in me.vertices]
    oe.to_mesh_clear()
    return pts


def group_verts(ob, prefixes, min_w=0.3):
    ids = {g.index for g in ob.vertex_groups if g.name.startswith(prefixes)}
    return [v.index for v in ob.data.vertices if any(g.group in ids and g.weight >= min_w for g in v.groups)]


# ------------------------------------------------------------------ motion
class Motion:
    """Per-frame pose: walk (legs, bob, spine, tail), head turn/lower, roar layer on head and face."""

    def __init__(self, arm, roar, k, heading_dir, stop_loc):
        self.arm, self.roar, self.k = arm, roar, k
        self.dir, self.stop = heading_dir, stop_loc
        self.legs = qp.make_legs(arm, chains(arm), FWD, UP, LAT, GAIT)
        self.up = {n: local_axis(arm, n, UP) for n in HEAD_CHAIN + TAIL + SPINE}
        self.lat = {n: local_axis(arm, n, LAT) for n in HEAD_CHAIN}
        tip = "RigTongue3_024"
        self.turn_sign = 1.0 if probe(arm, HEAD_CHAIN[0], self.up[HEAD_CHAIN[0]], tip).y < 0 else -1.0
        self.lower_sign = 1.0 if probe(arm, HEAD_CHAIN[0], self.lat[HEAD_CHAIN[0]], tip).z < 0 else -1.0
        self.v_full = GAIT.cycle_dist * k / CYCLE_FRAMES
        self.s = self._distance()
        self.prev = {}

    @staticmethod
    def speed(f):
        if f <= STOP_F - DECEL:
            return 1.0
        if f <= STOP_F:
            return 1.0 - smooth((f - (STOP_F - DECEL)) / DECEL)
        if f < GO_F:
            return 0.0
        return smooth((f - GO_F) / ACCEL)

    def _distance(self):
        s = {1: 0.0}
        for f in range(1, TOTAL + 1):
            s[f + 1] = s[f] + self.v_full * (self.speed(f) + self.speed(f + 1)) / 2
        return s

    def root_loc(self, f, feet_rel, bob):
        p = self.stop + self.dir * (self.s[f] - self.s[STOP_F])
        return Vector((p.x, p.y, GROUND_Z - feet_rel + bob * self.k))

    def pose(self, f, a_roar):
        amp = self.speed(f) ** 0.5
        dist = self.s[f] / self.k
        cyc = dist / GAIT.cycle_dist
        bob = qp.pose_walk(self.legs, GAIT, dist, amp)
        turn = TURN_DEG * (env(f, STOP_F - 10, STOP_F + 4) - env(f, GO_F - 6, GO_F + 8))
        lower = LOWER_DEG * (env(f, STOP_F - 6, ROAR_F + 2) - env(f, ROAR_F + 8, ROAR_F + 22))
        nod = 1.5 * amp * math.cos(4 * math.pi * cyc)
        pbs = self.arm.pose.bones
        for i, n in enumerate(HEAD_CHAIN):
            d, dl = roar_delta(self.roar, n, a_roar)
            pitch = (lower / 3 if i < 3 else 0.0) + (nod if i == 0 else 0.0)
            pbs[n].rotation_quaternion = (Quaternion(self.up[n], self.turn_sign * R(turn * TURN_SPLIT[i]))
                                          @ Quaternion(self.lat[n], self.lower_sign * R(pitch))
                                          @ self.roar["q0"][n] @ d)
            pbs[n].location = self.roar["l0"][n] + dl
        for n in FACE:
            d, dl = roar_delta(self.roar, n, a_roar)
            pbs[n].rotation_quaternion = self.roar["q0"][n] @ d
            pbs[n].location = self.roar["l0"][n] + dl
        t = f / 24.0
        for i, n in enumerate(TAIL):
            u = i / (len(TAIL) - 1)
            sway = (R(3.5) * (0.4 + 0.6 * u) * math.sin(2 * math.pi * (t / 1.6 - 0.08 * i))
                    + R(4.0) * amp * math.sin(2 * math.pi * (cyc - 0.06 * i)))
            pbs[n].rotation_quaternion = Quaternion(self.up[n], sway)
        for n in SPINE:
            pbs[n].rotation_quaternion = Quaternion(self.up[n], R(1.2) * amp * math.sin(2 * math.pi * cyc))
        return bob

    def key(self, f):
        for pb in self.arm.pose.bones:
            n = pb.name
            if n not in self._keyed:
                continue
            q = pb.rotation_quaternion
            p = self.prev.get(n)
            if p is not None and q.dot(p) < 0:
                pb.rotation_quaternion = Quaternion([-c for c in q])
            self.prev[n] = pb.rotation_quaternion.copy()
            pb.keyframe_insert("rotation_quaternion", frame=f, group=n)
            if n in ROAR_BONES:
                pb.keyframe_insert("location", frame=f, group=n)

    @property
    def _keyed(self):
        legs = {pb.name for leg in self.legs for pb in leg.bones}
        return legs | set(ROAR_BONES) | set(TAIL) | set(SPINE)


# ------------------------------------------------------------------ look
def fur_material(body, eyes):
    for m in body.data.materials:
        b = next((n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
        if b:
            for l in list(b.inputs["Roughness"].links):
                m.node_tree.links.remove(l)
            b.inputs["Roughness"].default_value = 0.72
            b.inputs["Sheen Weight"].default_value = 0.6
            b.inputs["Sheen Roughness"].default_value = 0.45
            b.inputs["Sheen Tint"].default_value = (1.0, 0.82, 0.55, 1.0)
            b.inputs["Specular IOR Level"].default_value = 0.3
    for m in eyes.data.materials:
        b = next((n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
        if b:
            b.inputs["Coat Weight"].default_value = 1.0
            b.inputs["Coat Roughness"].default_value = 0.03


def mane_weights(arm, body):
    """Neck + back of the head (behind the ears) + front of the chest."""
    bones = arm.data.bones
    gid = {g.name: g.index for g in body.vertex_groups}
    neck = [gid[n] for n in HEAD_CHAIN[:3] if n in gid]
    head, chest = gid.get("RigHead_020"), gid.get("RigChest_010")
    to_arm = arm.matrix_world.inverted() @ body.matrix_world
    ear_f = ((bones["RigLEar1_025"].head_local + bones["RigREar1_026"].head_local) / 2).dot(FWD)
    eye_f = bones["RigLEye1_027"].head_local.dot(FWD)
    chest_f = bones["RigLShoulderBlade_037"].head_local.dot(FWD)
    span = max(1e-3, eye_f - ear_f)
    neck_len = (bones["RigHead_020"].head_local - bones["RigNeck1_017"].head_local).length
    vg = body.vertex_groups.new(name="Mane")
    for v in body.data.vertices:
        gw = {g.group: g.weight for g in v.groups}
        f = (to_arm @ v.co).dot(FWD)
        w = sum(gw.get(i, 0.0) for i in neck)
        w += gw.get(head, 0.0) * smooth((ear_f - 0.1 * span - f) / (0.3 * span))
        w += 0.8 * gw.get(chest, 0.0) * smooth((f - chest_f) / (0.5 * neck_len))
        if w > 0.02:
            vg.add([v.index], min(1.0, w), "REPLACE")
    return vg


def hair_material():
    m = bpy.data.materials.new("Mane")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N, L = nt.nodes.new, nt.links.new
    out = N("ShaderNodeOutputMaterial")
    hair = N("ShaderNodeBsdfHairPrincipled")
    hair.parametrization = "MELANIN"
    info = N("ShaderNodeHairInfo")
    mr = N("ShaderNodeMapRange")                     # dark roots, golden tips
    mr.inputs["To Min"].default_value, mr.inputs["To Max"].default_value = 0.55, 0.22
    L(info.outputs["Intercept"], mr.inputs["Value"])
    L(mr.outputs["Result"], hair.inputs["Melanin"])
    hair.inputs["Melanin Redness"].default_value = 0.66
    hair.inputs["Roughness"].default_value = 0.38
    hair.inputs["Radial Roughness"].default_value = 0.5
    hair.inputs["Coat"].default_value = 0.15
    L(hair.outputs[0], out.inputs["Surface"])
    return m


def add_mane(sc, arm, body, dynamics):
    vg = mane_weights(arm, body)
    body.data.materials.append(hair_material())
    mod = body.modifiers.new("Mane", "PARTICLE_SYSTEM")
    ps = mod.particle_system
    st = ps.settings
    scale = body.matrix_world.to_scale()[0]      # hair settings live in the mesh's object space
    st.type, st.count = "HAIR", MANE_GUIDES
    st.use_advanced_hair = True
    st.length_random = 0.35
    st.emit_from, st.use_emit_random = "FACE", True
    to_local = (body.matrix_world.inverted().to_3x3() @ arm.matrix_world.to_3x3()).normalized()
    back, down = to_local @ -FWD, to_local @ -UP
    g = MANE_LEN / 2.76          # measured: these factors grow 2.76-unit strands; hair_length is ignored
    st.normal_factor = 0.55 * g
    st.object_align_factor = tuple(g * (0.65 * back + 0.35 * down))
    st.hair_step = 6
    st.child_type = "INTERPOLATED"
    st.child_percent, st.rendered_child_count = 10, 90
    st.child_radius = 0.5
    st.clump_factor, st.clump_shape = 0.12, 0.0
    st.roughness_1, st.roughness_1_size = 0.09, 0.5
    st.roughness_endpoint = 0.04
    st.kink, st.kink_amplitude, st.kink_frequency = "WAVE", 0.012 / scale, 2.5
    st.root_radius, st.tip_radius, st.radius_scale = 1.0, 0.1, 0.0045 / scale
    st.material = len(body.data.materials)          # 1-based slot of the Mane material just appended
    ps.vertex_group_density = vg.name
    ps.vertex_group_length = vg.name
    if dynamics:
        ps.use_hair_dynamics = True
        cs = ps.cloth.settings
        cs.quality, cs.mass = 3, 0.25
        cs.bending_stiffness, cs.bending_damping = 0.9, 0.6
        cs.air_damping, cs.pin_stiffness = 1.5, 1.2
        ps.point_cache.frame_start, ps.point_cache.frame_end = 1, TOTAL
    sub = body.modifiers.new("Subsurf", "SUBSURF")
    sub.levels, sub.render_levels = 0, 1
    return ps


def add_crown(sc, arm, body, heading_yaw):
    """Crown sized to the head, sitting between the ears, following the head bone."""
    pb = arm.pose.bones
    mw = arm.matrix_world
    ear_l, ear_r = mw @ pb["RigLEar1_025"].head, mw @ pb["RigREar1_026"].head
    head_ids = set(group_verts(body, ("RigHead",), 0.6))
    pts = eval_verts(body)
    top = max((pts[i] for i in head_ids), key=lambda p: p.z)
    mid = (ear_l + ear_r) / 2
    width = (ear_l - ear_r).length * 0.95
    objs = gc.import_glb(os.path.join(gc.MODELS, "golden_crown.glb"))
    croot, _ = gc.normalize(objs, width, name="Crown")
    lo, hi = gc.world_bbox(objs)
    croot.location = (mid.x, mid.y, top.z + (hi.z - lo.z) / 2 + 0.02 * width)
    croot.rotation_euler = (R(-6), 0.0, heading_yaw)
    bpy.context.view_layer.update()
    c = croot.constraints.new("CHILD_OF")
    c.target, c.subtarget = arm, "RigHead_020"
    c.inverse_matrix = (mw @ pb["RigHead_020"].matrix).inverted()
    for o in objs:
        for m in (o.data.materials if o.type == "MESH" else []):
            b = next((n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
            if b and b.inputs["Metallic"].default_value > 0.5:
                for l in list(b.inputs["Roughness"].links):
                    m.node_tree.links.remove(l)
                b.inputs["Roughness"].default_value = 0.12
    return croot


def add_fx(sc, cam, arm, mouth_dir, head_ground):
    gold = (1.0, 0.68, 0.24)
    dust = fx.fade_material("DustGold", (1.0, 0.58, 0.14), 3.0, 1.0, 1.4)
    fx.particle_burst(sc, "Dust", fx.ring_mesh("DustRing", 1.0), dust, 1600, (SHOCK_F, SHOCK_F + 3), 26,
                      0.018, 6.0, rand=0.6, align=(0, 0, 1.4), damping=0.07,
                      location=(head_ground.x, head_ground.y, GROUND_Z + 0.02))
    puff = fx.fade_material("DustPuff", (1.0, 0.8, 0.5), 0.9, 0.45, 1.2)
    fx.particle_burst(sc, "Puff", fx.ring_mesh("PuffRing", 0.6), puff, 500, (SHOCK_F, SHOCK_F + 4), 30,
                      0.08, 3.5, rand=0.5, align=(0, 0, 0.6), damping=0.1,
                      location=(head_ground.x, head_ground.y, GROUND_Z + 0.02))
    fx.shock_ring(sc, "Shock", (head_ground.x, head_ground.y, GROUND_Z + 0.015), (SHOCK_F, SHOCK_F + 14),
                  3.6, gold, 4.0)
    breath = fx.fade_material("Breath", (1.0, 0.84, 0.58), 1.2, 0.16, 1.6)
    em = fx.particle_burst(sc, "Breath", fx.point_mesh("BreathSrc", 0.1), breath, 1400,
                           (SHOCK_F - 2, SHOCK_F + 12), 16, 0.032, 0.4, rand=0.8,
                           align=tuple(4.5 * mouth_dir), damping=0.06, emit_from="VOLUME")
    c = em.constraints.new("COPY_LOCATION")
    c.target, c.subtarget, c.head_tail = arm, "RigTongue2_023", 1.0
    sh.camera_shake(cam, SHOCK_F, 18, amp=0.07, rot_deg=0.6)


# ------------------------------------------------------------------ build
def build_show(sc, opts):
    root, arm, body, eyes, roar = load_lion(sc)
    yaw = R(90) - HEADING
    root.rotation_euler = (0, 0, yaw)
    heading_dir = Vector((math.cos(HEADING), -math.sin(HEADING), 0.0))
    bpy.context.view_layer.update()
    k = (arm.matrix_world.to_3x3() @ Vector((0, 0, 1))).length
    apply_base(arm, roar)
    bpy.context.view_layer.update()
    feet = group_verts(body, ("RigLBLegDigit", "RigLFLegDigit", "RigRBLegDigit", "RigRFLegDigit",
                              "RigLBLegAnkle", "RigLFLegAnkle", "RigRBLegAnkle", "RigRFLegAnkle"))
    pts = eval_verts(body)
    feet_rel = min(pts[i].z for i in feet) - root.location.z
    stop = Vector((STOP_X, 0.0, 0.0))
    mo = Motion(arm, roar, k, heading_dir, stop)
    root.location = mo.root_loc(STOP_F, feet_rel, 0.0)
    bpy.context.view_layer.update()
    crown = add_crown(sc, arm, body, yaw)
    for f in range(1, TOTAL + 1):
        bob = mo.pose(f, f - ROAR_F)
        root.location = mo.root_loc(f, feet_rel, bob)
        root.keyframe_insert("location", frame=f)
        mo.key(f)
    fur_material(body, eyes)
    sh.setup_cycles(sc, (1, TOTAL), samples=opts["samples"])
    sh.shadow_catcher(sc, GROUND_Z, 60)
    gc.setup_world(sc, strength=0.5)
    cam = gc.setup_camera(sc, elev_deg=7)
    gc.setup_lights(sc, follow=root, scale=1.2)
    sh.setup_comp(sc, fog_threshold=1.6, fog_size=7, streak_threshold=5.0)
    sc.frame_set(PEAK_F)
    pb = arm.pose.bones
    mw = arm.matrix_world
    mouth = (mw @ pb["RigTongue3_024"].tail) - (mw @ pb["RigHead_020"].head)
    mouth_dir = Vector((mouth.x, mouth.y, max(0.0, mouth.z) * 0.3)).normalized()
    hg = mw @ pb["RigJaw1_021"].tail
    add_fx(sc, cam, arm, mouth_dir, Vector((hg.x, hg.y, 0)))
    if opts["hair"]:
        add_mane(sc, arm, body, dynamics=opts["test"] is None or opts["dyn"])
    report(sc, cam, [body, eyes], crown)
    return sc


def report(sc, cam, obs, crown):
    for f in (1, STOP_F, PEAK_F, GO_F, TOTAL):
        sc.frame_set(f)
        co = [world_to_camera_view(sc, cam, p) for ob in obs for p in eval_verts(ob)]
        print(f"EXTENT f{f}: x {min(c.x for c in co):.3f}..{max(c.x for c in co):.3f}"
              f"  y {min(c.y for c in co):.3f}..{max(c.y for c in co):.3f}")


def build_icon(sc, opts):
    root, arm, body, eyes, roar = load_lion(sc)
    h = R(58)                                        # 3/4 front
    root.rotation_euler = (0, 0, R(90) - h)
    bpy.context.view_layer.update()
    apply_base(arm, roar)
    bpy.context.view_layer.update()
    pts = eval_verts(body)
    lo_z = min(p.z for p in pts)
    root.location.z -= lo_z
    bpy.context.view_layer.update()
    add_crown(sc, arm, body, R(90) - h)
    n_frames = 30
    for i in range(1, n_frames + 1):
        a = (i - 1) * ROAR_LEN / n_frames            # one roar per loop: frame 31 == frame 1
        for n in ROAR_BONES:
            d, dl = roar_delta(roar, n, a)
            pb = arm.pose.bones[n]
            pb.rotation_quaternion = roar["q0"][n] @ d
            pb.location = roar["l0"][n] + dl
            pb.keyframe_insert("rotation_quaternion", frame=i)
            pb.keyframe_insert("location", frame=i)
    fur_material(body, eyes)
    sh.setup_cycles(sc, (1, n_frames), samples=opts["samples"], res=(384, 384))
    sc.render.fps = sh.ICON_FPS
    gc.setup_world(sc, strength=0.5)
    cam = gc.setup_camera(sc, elev_deg=8)
    lo, hi = gc.world_bbox([body])
    c = (lo + hi) / 2
    half = max(hi.x - lo.x, hi.z - lo.z) / 2 * 1.18
    cam.location = (c.x, c.y - gc.CAM_DIST * math.cos(R(8)), c.z + gc.CAM_DIST * math.sin(R(8)))
    cam.data.lens = gc.CAM_DIST * 18.0 / half
    gc.setup_lights(sc, follow=root, scale=1.2)
    sh.setup_comp(sc, fog_threshold=1.6, fog_size=6, streak_threshold=5.0)
    if opts["hair"]:
        add_mane(sc, arm, body, dynamics=False)      # rigid mane keeps the loop seamless
    return sc


def bake(sc):
    """Run the hair sim frame by frame (ptcache.bake_all hangs in background mode), then freeze it."""
    sims = [ps for ob in sc.objects for ps in getattr(ob, "particle_systems", []) if ps.use_hair_dynamics]
    for ps in sims:
        ps.point_cache.use_disk_cache = True     # the render depsgraph only reads a disk cache; needs the saved .blend
    sc.frame_set(1)
    for f in range(1, TOTAL + 1):
        sc.frame_set(f)
    for ob in sc.objects:
        for ps in getattr(ob, "particle_systems", []):
            if ps.use_hair_dynamics:
                with bpy.context.temp_override(scene=sc, active_object=ob, object=ob, point_cache=ps.point_cache):
                    bpy.ops.ptcache.bake_from_cache()
                print("BAKE", ob.name, ps.name, "baked:", ps.point_cache.is_baked, ps.point_cache.info)
    sc.frame_set(1)


def main():
    opts = parse()
    sc = gc.reset_scene("Lion")
    sc.render.fps = sh.FPS
    if opts["mode"] == "show":
        build_show(sc, opts)
        if opts["hair"] and (not opts["test"] or opts["dyn"]):
            gc.save(sh.src_dir(ID) + os.sep + ("lion_dyn_test.blend" if opts["test"] else "lion_show.blend"))
            bake(sc)
        sh.render(sc, ID, "show", opts["test"])
    else:
        build_icon(sc, opts)
        if not opts["test"]:
            gc.save(sh.src_dir(ID) + os.sep + "lion_icon.blend")
        sh.render(sc, ID, "icon", opts["test"])


if __name__ == "__main__":
    main()
