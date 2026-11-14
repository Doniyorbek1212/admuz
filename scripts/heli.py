"""UZARO gift: helicopter. blender -b --factory-startup -P heli.py -- <main|icon> [test frames]

Main: flies in from the left (frames 10-45), hovers at centre for 2 s (45-105), leaves to the top right
(105-141). Frames 1-9 and 142-150 stay empty (added by encode.py).
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gift_common as gc  # noqa: E402

R = math.radians
NAME = "helicopter"
YAW_3Q = R(-120)        # nose to screen-right, turned 30 deg toward the camera
SIZE = 8.0              # largest bbox side incl. rotor disc (visible width at centre is 8.1)
TILT = R(9)             # (+ camera elevation) top toward the camera so the blurred rotor disc is seen, not edge-on
MAIN_ROTOR_RAD_PER_FRAME = 0.6   # 34 deg/frame: below the 45 deg wagon-wheel limit of 4 blades
TAIL_ROTOR_RAD_PER_FRAME = 1.4
HOVER_Z = 0.3


def spin_rotors(arm):
    arm.animation_data.action = None  # imported 24-frame loop is sampled too coarsely
    for bone, axis, speed in (("Rotor_Main_01", 2, MAIN_ROTOR_RAD_PER_FRAME),
                              ("Rotor_Rear_02", 0, TAIL_ROTOR_RAD_PER_FRAME)):
        pb = arm.pose.bones[bone]
        pb.rotation_mode = "XYZ"
        for f in (0, 200):
            rot = [0.0, 0.0, 0.0]
            rot[axis] = f * speed
            pb.rotation_euler = rot
            pb.keyframe_insert("rotation_euler", frame=f)
    for fc in arm.animation_data.action.fcurves:
        for kp in fc.keyframe_points:
            kp.interpolation = "LINEAR"


def paint_body():
    import bpy
    t = gc.TEXTURES
    for mat_name, tex in (("EC135_Body_Outer_Mat", "heli_outer"), ("EC135_Body_Back_Mat", "heli_back")):
        gc.repaint(bpy.data.materials[mat_name], os.path.join(t, f"{tex}.png"),
                   os.path.join(t, f"{tex}_mask.png"), metallic=0.85, roughness=0.22, coat=0.8)


def animate_main(root):
    gc.keyframes(root, "location", [
        (10, (-9.8, 0, 1.3)), (24, (-3.6, 0, 0.7)), (45, (0, 0, HOVER_Z)),
        (60, (0.05, 0, HOVER_Z + 0.12)), (75, (-0.05, 0, HOVER_Z - 0.08)), (90, (0.05, 0, HOVER_Z + 0.1)),
        (105, (0.15, 0, HOVER_Z + 0.05)), (120, (1.8, 0, 1.9)), (141, (9.8, 0, 10.5)),
    ])
    # pitch: nose down while flying, flare nose-up to stop, nose down to leave; slight banks
    gc.keyframes(root, "rotation_euler", [
        (10, (TILT, R(12), 0)), (34, (TILT, R(4), 0)), (42, (TILT + R(-3), R(-9), 0)), (54, (TILT, R(1), R(2))),
        (75, (TILT + R(1.5), 0, R(-2))), (98, (TILT, 0, 0)), (110, (TILT + R(4), R(14), R(4))), (141, (TILT + R(8), R(22), R(10))),
    ])


def animate_icon(root):
    gc.keyframes(root, "location", [(1, (0, 0, 0)), (31, (0, 0, 0.15)), (61, (0, 0, 0))])
    gc.keyframes(root, "rotation_euler", [(1, (TILT, 0, R(-8))), (31, (TILT, 0, R(8))), (61, (TILT, 0, R(-8)))])


def build(mode):
    sc = gc.reset_scene("Helicopter")
    objs = gc.import_glb(os.path.join(gc.MODELS, "ec_135.glb"), hide=("Icosphere",))
    root, _ = gc.normalize(objs, SIZE, rot=(0, 0, YAW_3Q), name="Heli")
    arm = next(o for o in objs if o.type == "ARMATURE")
    spin_rotors(arm)
    paint_body()
    gc.setup_render(sc, "", samples=48, shutter=0.6, blur_steps=3)
    gc.setup_world(sc, strength=0.9, hdri="city.exr")
    cam = gc.setup_camera(sc, elev_deg=10)
    gc.setup_lights(sc, follow=root)
    gc.setup_glow(sc, threshold=1.3, size=6)
    if mode == "icon":
        gc.icon_camera(sc, cam, half_extent=SIZE * 0.55)
        animate_icon(root)
    else:
        animate_main(root)
    return sc


if __name__ == "__main__":
    gc.run_cli(build, NAME)
