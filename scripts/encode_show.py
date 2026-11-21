"""python encode_show.py <id>   (contract v2)

gift_renders/source/<id>/show/f_*.png (540x960 @24) -> gift_renders/<id>.webp   loop flag 1, size budget by tier
gift_renders/source/<id>/icon/f_*.png (384x384)     -> gift_renders/<id>_icon.webp  192x192 @15, loop 0, <=150 KB
also <id>_preview.jpg (12 frames, 6x2 on #10141c), manifest.json entry, CREDITS.txt lines, and the checks:
size / frames / fps / loop flag, corner alpha 0, first+last frame empty or subject at the edge, no full-frame haze,
sound length = show length. Over budget: lower quality only (resolution stays).
"""
import glob
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageChops, ImageDraw

import sheet
from encode import webp_info

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(SCRIPTS), "gift_renders")
SHOW_FPS, ICON_FPS = 24, 15
SHOW_RES, ICON_RES = (540, 960), (192, 192)
BUDGET = {1: 2.5, 2: 2.5, 3: 4.0, 4: 4.0}         # MB
ICON_BUDGET = 150 * 1024
QUALITIES = (20, 30, 40, 45, 50, 55, 60, 65, 70, 72, 75, 78, 82, 85, 90)
# (alpha levels, lowest RGB quality worth keeping them for): alpha is most of the bytes, and too few levels band on a light
# background while low RGB quality only softens, so levels go first. An earlier ladder kept q90 with 12 levels (chest rays).
ALPHA_LADDER = ((96, 60), (56, 55), (32, 50), (24, 45), (16, 40), (12, 30), (8, 20), (6, 20), (4, 20))
HAZE_MAX = 0.5                                   # max fraction of a frame with alpha > 0
ALPHA_FLOOR = 16       # shadow-catcher residue below this: invisible, noisy, costs most of the bytes, breaks corner alpha 0
# faint nebula rim / god-ray haze held cover at 0.518 / 0.535 once alpha stopped being lossy: measured floors for <= 0.47
FLOOR_BY_GIFT = {"universe": 42, "treasure_chest": 28}
EDGE_FADE = 6          # show frames faded at each end: an offscreen subject still casts a shadow into the first/last frame
CORNER_RADIUS = 10     # px at source resolution: corners stay alpha 0 even when the subject flies through one


def clean_frames(files, gift_id, part, size, edge_fade=0):
    """Floor the alpha and mask the corners into source/<id>/<part>_clean; the original PNGs stay untouched."""
    out = os.path.join(OUT, "source", gift_id, f"{part}_clean")
    os.makedirs(out, exist_ok=True)
    floor = FLOOR_BY_GIFT.get(gift_id, ALPHA_FLOOR)
    lut = [0 if v <= floor else round((v - floor) * 255 / (255 - floor)) for v in range(256)]
    mask, cleaned = None, []
    for i, path in enumerate(files):
        dst = os.path.join(out, os.path.basename(path))
        cleaned.append(dst)
        fade = min(1.0, i / edge_fade, (len(files) - 1 - i) / edge_fade) if edge_fade else 1.0
        if (fade == 1.0 and os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(path)
                and Image.open(dst).size == size):
            continue
        im = Image.open(path).convert("RGBA").resize(size, Image.LANCZOS)  # PIL premultiplies; ffmpeg scale left alpha=1 everywhere
        if mask is None:
            mask = Image.new("L", im.size, 0)
            ImageDraw.Draw(mask).rounded_rectangle((0, 0, im.width - 1, im.height - 1), CORNER_RADIUS, fill=255)
        r, g, b, a = im.split()
        a = ImageChops.multiply(a.point(lut), mask).point(lambda v: round(v * fade))
        Image.merge("RGBA", (r, g, b, a)).save(dst, compress_level=1)
    return cleaned


def frames_of(gift_id, part):
    files = sorted(glob.glob(os.path.join(OUT, "source", gift_id, part, "f_*.png")))
    if not files:
        raise SystemExit(f"no frames for {gift_id}/{part}")
    return files


BAYER4 = np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]], dtype=np.float32)
BAYER8 = np.block([[4 * BAYER4, 4 * BAYER4 + 2], [4 * BAYER4 + 3, 4 * BAYER4 + 1]])


def quantise_alpha(im, levels):
    """Ordered-dither alpha onto N levels and rescale RGB to match: premultiplied colour stays continuous (no bands on
    dark), and on a light background the steps become a fixed fine grain instead of contour rings. 4 dithered levels
    cost about what 6 plain ones did (hot_air_balloon clouds)."""
    arr = np.asarray(im, dtype=np.float32)
    a = arr[..., 3]
    step = 255.0 / (levels - 1)
    h, w = a.shape
    threshold = (np.tile(BAYER8, (h // 8 + 1, w // 8 + 1))[:h, :w] + 0.5) / 64.0   # fixed per pixel: frames stay alike
    rounded = np.minimum(np.floor(a / step + threshold) * step, 255.0)
    rgb = arr[..., :3] * (a / np.maximum(rounded, 1.0))[..., None]
    return Image.fromarray(np.dstack((np.clip(rgb + 0.5, 0, 255), np.round(rounded))).astype(np.uint8), "RGBA")


def encode(files, dst, fps, loop, budget):
    """Most alpha levels, then highest RGB quality, that fit the budget; resolution kept. Returns (levels, q)."""
    frames = [Image.open(f).convert("RGBA") for f in files]
    durations = [round((i + 1) * 1000 / fps) - round(i * 1000 / fps) for i in range(len(frames))]

    def attempt(quantised, q, method=4, alpha_quality=100):
        # searching runs at method 4 (several times faster); the final save at method 6 is smaller still
        quantised[0].save(dst, save_all=True, append_images=quantised[1:], duration=durations, loop=loop, lossless=False,
                          quality=q, alpha_quality=alpha_quality, method=method)
        return os.path.getsize(dst) <= budget

    def first_true(n, ok):
        """Smallest i in [0, n) with ok(i), ok monotone False..True; n if none."""
        lo, hi = 0, n
        while lo < hi:
            mid = (lo + hi) // 2
            if ok(mid):
                hi = mid
            else:
                lo = mid + 1
        return lo

    cache = {}

    def quantised_at(i):
        if i not in cache:
            cache.clear()
            cache[i] = [quantise_alpha(f, ALPHA_LADDER[i][0]) for f in frames]
        return cache[i]

    # size falls as the ladder descends: the first level whose q floor fits is the most levels that fit
    i = first_true(len(ALPHA_LADDER), lambda k: attempt(quantised_at(k), ALPHA_LADDER[k][1]))
    if i == len(ALPHA_LADDER):
        # last resort (phoenix icon): libwebp's own lossy alpha, which bands on light backgrounds but is smaller
        for aq in (80, 60, 40, 20):
            if attempt(frames, QUALITIES[0], alpha_quality=aq):
                if not attempt(frames, QUALITIES[0], method=6, alpha_quality=aq):
                    attempt(frames, QUALITIES[0], alpha_quality=aq)
                return f"lossy aq{aq}", QUALITIES[0]
        raise SystemExit(f"{dst}: over {budget / 1024:.0f} KB even at the lowest quality")
    levels, q_min = ALPHA_LADDER[i]
    quantised = quantised_at(i)
    ups = [v for v in QUALITIES if v > q_min]
    # size rises with q: the first quality that misses ends the climb
    j = first_true(len(ups), lambda k: not attempt(quantised, ups[k]))
    best = ups[j - 1] if j else q_min
    if not attempt(quantised, best, method=6):
        attempt(quantised, best)
    return levels, best


def alpha_checks(path):
    """Corner alpha, first/last frame emptiness or edge contact, max covered fraction."""
    im = Image.open(path)
    n, corner_max, cover_max = 0, 0, 0.0
    first = last = None
    for i in range(im.n_frames):
        im.seek(i)
        a = im.convert("RGBA").getchannel("A")
        w, h = a.size
        corner_max = max(corner_max, *(a.getpixel(p) for p in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1))))
        hist = a.histogram()
        cover_max = max(cover_max, 1 - hist[0] / (w * h))
        box = a.point(lambda v: 255 if v > 8 else 0).getbbox()
        state = "empty" if box is None else ("at edge" if box[0] == 0 or box[2] == w or box[1] == 0 or box[3] == h
                                             else f"INSIDE {box}")
        first = state if i == 0 else first
        last = state
        n += 1
    return {"corner_alpha_max": corner_max, "cover_max": round(cover_max, 3), "first": first, "last": last}


def audio_len(path):
    r = subprocess.run(["ffmpeg", "-v", "info", "-i", path, "-f", "null", "-"], capture_output=True, text=True)
    t = [l for l in r.stderr.splitlines() if "time=" in l][-1].split("time=")[1].split()[0]
    hh, mm, ss = t.split(":")
    return int(hh) * 3600 + int(mm) * 60 + float(ss)


def update_manifest(gift, duration_ms):
    path = os.path.join(OUT, "manifest.json")
    data = json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {"gifts": []}
    entry = {"id": gift["id"], "tier": gift["tier"], "price_uzs": gift["price_uzs"], "duration_ms": duration_ms,
             "title": gift["title"],
             "files": {"show": f"{gift['id']}.webp", "icon": f"{gift['id']}_icon.webp", "sound": f"{gift['id']}.mp3"}}
    data["gifts"] = [g for g in data["gifts"] if g["id"] != gift["id"]] + [entry]
    order = [g["id"] for g in catalogue()]
    data["gifts"].sort(key=lambda g: order.index(g["id"]))
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def update_credits(gift):
    path = os.path.join(OUT, "CREDITS.txt")
    lines = open(path, encoding="utf-8").read().splitlines() if os.path.exists(path) else []
    lines = [l for l in lines if not l.startswith(f"{gift['id']}: ")]
    lines += [f"{gift['id']}: {c}" for c in gift.get("credits", [])]
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def catalogue():
    return json.load(open(os.path.join(SCRIPTS, "gifts.json"), encoding="utf-8"))["gifts"]


def main():
    gid = sys.argv[1]
    gift = next(g for g in catalogue() if g["id"] == gid)
    show_files = clean_frames(frames_of(gid, "show"), gid, "show", SHOW_RES, EDGE_FADE)
    icon_files = clean_frames(frames_of(gid, "icon"), gid, "icon", ICON_RES)
    show = os.path.join(OUT, f"{gid}.webp")
    icon = os.path.join(OUT, f"{gid}_icon.webp")
    q_show = encode(show_files, show, SHOW_FPS, 1, BUDGET[gift["tier"]] * 1024 * 1024)
    q_icon = encode(icon_files, icon, ICON_FPS, 0, ICON_BUDGET)
    duration_ms = round(len(show_files) * 1000 / SHOW_FPS)
    sys.argv = ["sheet", os.path.dirname(show_files[0]), os.path.join(OUT, f"{gid}_preview.jpg"), "6", "12", "480"]
    sheet.main()
    update_manifest(gift, duration_ms)
    update_credits(gift)
    for path, fps, (levels, q) in ((show, SHOW_FPS, q_show), (icon, ICON_FPS, q_icon)):
        w, h, stored, ms, loop = webp_info(path)
        checks = alpha_checks(path)
        print(f"RESULT {os.path.basename(path)} | {os.path.getsize(path) / 1024:.0f} KB (q{q}, {levels} alpha levels) | {w}x{h} | "
              f"{round(ms * fps / 1000)} frames = {ms / 1000:.2f} s @ {fps} fps ({stored} stored) | loop={loop} | "
              f"{checks}")
        if checks["corner_alpha_max"] > 0:
            raise SystemExit(f"{path}: corner alpha {checks['corner_alpha_max']}, contract says 0")
    snd = os.path.join(OUT, f"{gid}.mp3")
    if os.path.exists(snd):
        print(f"SOUND {gid}.mp3 | {os.path.getsize(snd) / 1024:.0f} KB | {audio_len(snd):.2f} s vs show {duration_ms / 1000:.2f} s")
    else:
        print(f"SOUND missing: {snd}")


if __name__ == "__main__":
    main()
