"""python encode_frames.py <id> [<id> ...] | all

frame_renders/source/<id>/ring/f_*.png + plate/f_0001.png ->
  frame_renders/<id>.webp        384x384 @15, plate over ring, loop 0 (forever), <= FULL_BUDGET   (profile, headers)
  frame_renders/<id>_small.webp  176x176 @15, ring only,       loop 0,          <= SMALL_BUDGET  (chat lists)
  frame_renders/<id>_preview.png the frame round a stand-in photo at 160/74/52 px on dark and light
and the manifest.json entry. Checks, failing loudly: the photo hole (r < HOLE_R) has alpha 0 in every frame, the
corners have alpha 0, the loop seam (last -> first frame) changes no more than an ordinary step, sizes fit.
"""
import glob
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

from encode_show import encode

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(SCRIPTS), "frame_renders")
FPS = 15
FULL, SMALL = 384, 176
FULL_BUDGET, SMALL_BUDGET = int(os.environ.get("FULL_KB", 600)) * 1024, int(os.environ.get("SMALL_KB", 240)) * 1024
HOLE_R = 0.74            # of the half-size: must match frame_common.HOLE_R
PHOTO_R = 0.76           # where the app draws the photo edge
ALPHA_FLOOR = 10         # glow residue below this is invisible noise that costs bytes
SEAM_RATIO = 2.0         # last->first change vs the median frame-to-frame change


def masks(size):
    """Alpha multiplier: 0 inside the photo hole and outside the canvas circle (so the corners are always empty)."""
    yy, xx = np.mgrid[0:size, 0:size]
    r = np.hypot(xx + 0.5 - size / 2, yy + 0.5 - size / 2) / (size / 2)
    outer = np.clip((1.0 - r) * size / 4, 0.0, 1.0)       # ~2 px soft edge at the canvas circle
    return np.where(r < HOLE_R, 0.0, outer)


def clean(im, mask):
    arr = np.asarray(im, dtype=np.float32)
    a = arr[..., 3]
    a = np.where(a <= ALPHA_FLOOR, 0.0, (a - ALPHA_FLOOR) * 255.0 / (255.0 - ALPHA_FLOOR)) * mask
    out = np.dstack((arr[..., :3], np.round(a))).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def build_frames(fid):
    ring = sorted(glob.glob(os.path.join(OUT, "source", fid, "ring", "f_*.png")))
    plate = os.path.join(OUT, "source", fid, "plate", "f_0001.png")
    if not ring or not os.path.exists(plate):
        raise SystemExit(f"{fid}: render ring and plate first")
    plate_im = Image.open(plate).convert("RGBA")
    full_mask, small_mask = masks(FULL), masks(SMALL)
    full_dir = os.path.join(OUT, "source", fid, "full_clean")
    small_dir = os.path.join(OUT, "source", fid, "small_clean")
    os.makedirs(full_dir, exist_ok=True)
    os.makedirs(small_dir, exist_ok=True)
    full, small = [], []
    for path in ring:
        im = Image.open(path).convert("RGBA")
        name = os.path.basename(path)
        f_path, s_path = os.path.join(full_dir, name), os.path.join(small_dir, name)
        clean(Image.alpha_composite(im, plate_im).resize((FULL, FULL), Image.LANCZOS), full_mask).save(f_path)
        clean(im.resize((SMALL, SMALL), Image.LANCZOS), small_mask).save(s_path)
        full.append(f_path)
        small.append(s_path)
    return full, small


def decoded(path):
    im = Image.open(path)
    frames = []
    for i in range(im.n_frames):
        im.seek(i)
        frames.append(np.asarray(im.convert("RGBA"), dtype=np.float32))
    return frames, im.info.get("loop")


def check(path, size, budget):
    frames, loop = decoded(path)
    yy, xx = np.mgrid[0:size, 0:size]
    r = np.hypot(xx + 0.5 - size / 2, yy + 0.5 - size / 2) / (size / 2)
    hole = r < HOLE_R - 2.0 / size                      # a pixel of slack for the lossy edge
    hole_max = max(float(f[..., 3][hole].max()) for f in frames)
    corner_max = max(float(f[..., 3][[0, 0, -1, -1], [0, -1, 0, -1]].max()) for f in frames)

    def step(a, b):
        pa, pb = a[..., :3] * a[..., 3:] / 255, b[..., :3] * b[..., 3:] / 255   # premultiplied: what shows
        return float(np.abs(pa - pb).mean())

    steps = [step(frames[i], frames[i + 1]) for i in range(len(frames) - 1)]
    seam = step(frames[-1], frames[0])
    median = float(np.median(steps)) or 1e-6
    result = {"bytes": os.path.getsize(path), "frames": len(frames), "loop": loop, "hole_alpha_max": hole_max,
              "corner_alpha_max": corner_max, "seam": round(seam, 3), "median_step": round(median, 3)}
    problems = []
    if result["bytes"] > budget:
        problems.append("over budget")
    if hole_max > 0 or corner_max > 0:
        problems.append("alpha in the photo hole or a corner")
    if seam > SEAM_RATIO * median + 0.05:
        problems.append("loop seam jumps")
    if loop != 0:
        problems.append("not looping forever")
    return result, problems


def preview(fid):
    """The frame as the app shows it: photo stand-in under the frame, profile and list sizes, dark and light."""
    full = Image.open(os.path.join(OUT, f"{fid}.webp")).convert("RGBA")
    small = Image.open(os.path.join(OUT, f"{fid}_small.webp")).convert("RGBA")
    sheet = Image.new("RGBA", (2 * 300, 240), (0, 0, 0, 0))
    for k, bg in enumerate(((16, 20, 28, 255), (244, 245, 247, 255))):
        tile = Image.new("RGBA", (300, 240), bg)
        x = 6
        for asset, px in ((full, 200), (small, 74), (small, 52)):
            photo = Image.new("RGBA", (px, px), (0, 0, 0, 0))
            rr = PHOTO_R * px / 2
            ImageDraw.Draw(photo).ellipse((px / 2 - rr, px / 2 - rr, px / 2 + rr, px / 2 + rr), fill=(118, 140, 176, 255))
            tile.alpha_composite(Image.alpha_composite(photo, asset.resize((px, px), Image.LANCZOS)), (x, (240 - px) // 2))
            x += px + 6
        sheet.alpha_composite(tile, (k * 300, 0))
    sheet.save(os.path.join(OUT, f"{fid}_preview.png"))


def catalogue():
    return json.load(open(os.path.join(SCRIPTS, "frames.json"), encoding="utf-8"))["frames"]


def update_manifest(entry):
    path = os.path.join(OUT, "manifest.json")
    data = json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {"frames": []}
    item = {"id": entry["id"], "tier": entry["tier"], "price_uzs": entry["price_uzs"], "title": entry["title"],
            "files": {"full": f"{entry['id']}.webp", "small": f"{entry['id']}_small.webp"}}
    order = [e["id"] for e in catalogue()]
    data["frames"] = sorted([f for f in data["frames"] if f["id"] != entry["id"]] + [item], key=lambda f: order.index(f["id"]))
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def main():
    entries = {e["id"]: e for e in catalogue()}
    ids = list(entries) if sys.argv[1:] == ["all"] else sys.argv[1:]
    failed = []
    for fid in ids:
        full_files, small_files = build_frames(fid)
        full, small = os.path.join(OUT, f"{fid}.webp"), os.path.join(OUT, f"{fid}_small.webp")
        q_full = encode(full_files, full, FPS, 0, FULL_BUDGET)
        q_small = encode(small_files, small, FPS, 0, SMALL_BUDGET)
        (r_full, p_full), (r_small, p_small) = check(full, FULL, FULL_BUDGET), check(small, SMALL, SMALL_BUDGET)
        preview(fid)
        print(f"{fid}: full {r_full} q{q_full} {p_full or 'OK'}\n{' ' * len(fid)}  small {r_small} q{q_small} {p_small or 'OK'}")
        if p_full or p_small:
            failed.append(fid)
        else:
            update_manifest(entries[fid])
    if failed:
        raise SystemExit(f"failed checks: {', '.join(failed)}")


if __name__ == "__main__":
    main()
