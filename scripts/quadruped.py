"""Procedural quadruped walk for an imported rig: planted paws, analytic 2-bone IK per leg.

Works in armature space. A leg is 4 bones whose heads are the joints hip/shoulder -> knee/elbow ->
hock/wrist -> ankle (paw). The leg is solved in the sagittal plane (forward, up) and each bone gets a
rotation about the lateral axis, so it works whatever the bone rolls are (Unreal/Maya exports too).
The gait phase is driven by distance travelled, so paws stay planted when the speed changes.
"""
import math
from dataclasses import dataclass

from mathutils import Quaternion, Vector


@dataclass(frozen=True)
class Gait:
    cycle_dist: float          # body travel per full cycle (armature units)
    duty: float = 0.64         # fraction of the cycle a paw is on the ground
    lift: float = 9.0          # paw lift at mid-swing (armature units)
    bob: float = 1.6           # body up/down (armature units), twice per cycle
    hind_flex: float = 28.0    # extra hock flex during swing (deg)
    fore_flex: float = 40.0    # extra wrist flex during swing (deg)


# lateral-sequence walk: left hind, left fore, right hind, right fore
WALK_PHASES = {"LB": 0.0, "LF": 0.25, "RB": 0.5, "RF": 0.75}


class Leg:
    def __init__(self, arm, bones, fwd, up, lat, phase, flex_deg):
        self.bones = [arm.pose.bones[b] for b in bones]
        self.fwd, self.up, self.lat = fwd, up, lat
        self.phase, self.flex = phase, math.radians(flex_deg)
        joints = [arm.data.bones[b].head_local.copy() for b in bones]
        self.j = [self._2d(p) for p in joints]
        self.len = [(self.j[i + 1] - self.j[i]).length for i in range(3)]
        self.rest_ang = [self._ang(self.j[i + 1] - self.j[i]) for i in range(3)]
        # which way the middle joint bends (keep the rest-pose side)
        a, k, q = self.j[0], self.j[1], self.j[2]
        self.bend = math.copysign(1.0, (q - a).x * (k - a).y - (q - a).y * (k - a).x)
        self.axis = []
        for b in bones:
            m = arm.data.bones[b].matrix_local.to_3x3().inverted()
            self.axis.append((m @ lat).normalized())
        # rotating about +lat changes the 2D angle by sign * theta
        probe = Quaternion(lat, 0.1) @ fwd
        self.sign = 1.0 if self._ang(probe) > 0 else -1.0
        for pb in self.bones:
            pb.rotation_mode = "QUATERNION"

    def _2d(self, v):
        return Vector((v.dot(self.fwd), v.dot(self.up)))

    @staticmethod
    def _ang(v):
        return math.atan2(v.y, v.x)

    def solve(self, paw_offset, body_offset, flex, paw_curl):
        """paw_offset/body_offset: 2D (fwd, up) offsets from rest in armature units."""
        hip = self.j[0] + body_offset
        paw = self.j[3] + paw_offset
        a2 = self.rest_ang[2] + flex
        q = paw - self.len[2] * Vector((math.cos(a2), math.sin(a2)))
        l0, l1 = self.len[0], self.len[1]
        d = max(abs(l0 - l1) + 1e-3, min((q - hip).length, (l0 + l1) * 0.999))
        base = self._ang(q - hip)
        phi = math.acos(max(-1.0, min(1.0, (l0 * l0 + d * d - l1 * l1) / (2 * l0 * d))))
        a0 = base + self.bend * phi
        knee = hip + l0 * Vector((math.cos(a0), math.sin(a0)))
        a1 = self._ang(q - knee)
        d0 = a0 - self.rest_ang[0]
        d1 = a1 - self.rest_ang[1] - d0
        d2 = a2 - self.rest_ang[2] - d0 - d1
        d3 = -(d0 + d1 + d2) + paw_curl          # paw keeps its rest orientation, plus curl in swing
        self.last = tuple(math.degrees(_wrap(x)) for x in (d0, d1, d2, d3))
        for pb, axis, delta in zip(self.bones, self.axis, (d0, d1, d2, d3)):
            pb.rotation_quaternion = Quaternion(axis, self.sign * _wrap(delta))


def _wrap(a):
    return (a + math.pi) % (2 * math.pi) - math.pi


def _smooth(x):
    return x * x * (3 - 2 * x)


def paw_path(p, gait, amp):
    """Paw offset (fwd, up) and swing amount 0..1 for leg phase p in [0,1)."""
    s = gait.cycle_dist * gait.duty * amp
    if p < gait.duty:
        return Vector((s / 2 - s * p / gait.duty, 0.0)), 0.0
    q = (p - gait.duty) / (1 - gait.duty)
    return Vector((-s / 2 + s * _smooth(q), gait.lift * amp * math.sin(math.pi * q))), math.sin(math.pi * q)


def pose_walk(legs, gait, dist, amp, crouch=0.0):
    """Pose all legs for travelled distance `dist`; amp 0..1 blends stride to standing.
    crouch: paws drawn up by this much; the caller lowers the rig by it, so legs bend at a stalk.
    Returns the body bob (armature units, up): the caller must lift the whole rig by it."""
    cyc = dist / gait.cycle_dist
    bob = -gait.bob * amp * math.cos(4 * math.pi * cyc)
    for leg in legs:
        p = (cyc + leg.phase) % 1.0
        off, swing = paw_path(p, gait, amp)
        off.y += crouch - bob                   # the rig is lifted by bob, the ground is not
        leg.solve(off, Vector((0.0, 0.0)), leg.flex * swing, -0.5 * leg.flex * swing)
    return bob


def make_legs(arm, chains, fwd, up, lat, gait):
    """chains: {"LB": [4 bone names], ...}; hind legs are the keys ending in 'B'."""
    return [Leg(arm, bones, fwd, up, lat, WALK_PHASES[key],
                gait.hind_flex if key.endswith("B") else gait.fore_flex)
            for key, bones in chains.items()]
