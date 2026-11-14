"""python grid_overlay.py <dir> <name> <size>: tile <name>_xz/yz/xy.png on grey with coordinate grid lines labelled in world units."""
import os
import sys

from PIL import Image, ImageDraw

d, name, size = sys.argv[1], sys.argv[2], float(sys.argv[3])
half = size * 0.56
step = 0.5 if size <= 8 else 1.0
views = [("xz", "x", "z"), ("yz", "y", "z"), ("xy", "x", "y")]
sheet = Image.new("RGB", (2400, 800), (120, 120, 125))
draw = ImageDraw.Draw(sheet)
for i, (v, h, ve) in enumerate(views):
    p = os.path.join(d, f"{name}_{v}.png")
    if not os.path.exists(p):
        continue
    im = Image.open(p).convert("RGBA")
    sheet.paste(im, (i * 800, 0), im)
    k = 800 / (2 * half)
    u = -half + (half % step)
    while u <= half:
        x = i * 800 + (u + half) * k
        y = 800 - (u + half) * k
        major = abs(round(u) - u) < 1e-6
        col = (255, 255, 0) if abs(u) < 1e-6 else (40, 40, 40) if major else (85, 85, 85)
        draw.line((x, 0, x, 800), fill=col)
        draw.line((i * 800, y, i * 800 + 800, y), fill=col)
        if major:
            draw.text((x + 2, 2), f"{h}{u:g}", fill=(255, 255, 255))
            draw.text((i * 800 + 2, y + 1), f"{ve}{u:g}", fill=(255, 255, 255))
        u += step
sheet.save(os.path.join(d, f"{name}_grid.jpg"), quality=88)
