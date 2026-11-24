"""Render one UZARO animated avatar frame (designs in frame_designs.py, blocks in frame_common.py).

    blender -b --factory-startup -P frames.py -- <id> [ring|plate|both] [f=1,15] [s=32]

ring  : the animated frame without the label plate, N frames -> frame_renders/source/<id>/ring/f_####.png
plate : the static "UZARO" plate alone, frame 1     -> frame_renders/source/<id>/plate/f_0001.png
f=... renders only those frames into ring_test/ and plate_test/. encode_frames.py composites plate over ring for
the profile asset and uses the ring alone for chat lists.
"""
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import frame_common as fc  # noqa: E402
import gift_common as gc  # noqa: E402
from frame_designs import DESIGNS  # noqa: E402


def parse():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    opts = {"id": argv[0], "part": "both", "test": None, "samples": 32}
    for a in argv[1:]:
        if a in ("ring", "plate", "both"):
            opts["part"] = a
        elif a.startswith("f="):
            opts["test"] = [int(x) for x in a[2:].split(",")]
        elif a.startswith("s="):
            opts["samples"] = int(a[2:])
    return opts


def render_part(sc, frame_id, part, plate_obs, test):
    plate_set = {ob.name for ob in plate_obs} | {c.name for ob in plate_obs for c in ob.children_recursive}
    for ob in sc.objects:
        if ob.type not in ("LIGHT", "CAMERA"):
            ob.hide_render = (ob.name in plate_set) == (part == "ring")
    out = os.path.join(fc.OUT, "source", frame_id, part + ("_test" if test else ""))
    os.makedirs(out, exist_ok=True)
    for f in (test or (range(1, fc.N + 1) if part == "ring" else [1])):
        sc.frame_set(f)
        sc.render.filepath = os.path.join(out, f"f_{f:04d}.png")
        bpy.ops.render.render(write_still=True)
    print("FRAMES_DIR", out)


def main():
    opts = parse()
    frame_id = opts["id"]
    sc = gc.reset_scene(frame_id)
    fc.setup(sc, samples=opts["samples"])
    plate_obs = DESIGNS[frame_id](sc)
    for part in (("ring", "plate") if opts["part"] == "both" else (opts["part"],)):
        render_part(sc, frame_id, part, plate_obs, opts["test"])
    if not opts["test"]:
        gc.save(os.path.join(fc.OUT, "source", frame_id, f"{frame_id}.blend"))


if __name__ == "__main__":
    main()
