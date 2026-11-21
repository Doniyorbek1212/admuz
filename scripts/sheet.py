"""python sheet.py <frames_dir> <out.jpg> [cols=6] [count=12] [tile_h=480]
Contact sheet over #10141c: `count` evenly spaced PNGs from the folder, `cols` per row, frame number on each."""
import glob
import os
import sys

from PIL import Image, ImageDraw

BG = (0x10, 0x14, 0x1C)


def pick(files, count):
    if len(files) <= count:
        return files
    return [files[round(i * (len(files) - 1) / (count - 1))] for i in range(count)]


def main():
    src, out = sys.argv[1], sys.argv[2]
    cols = int(sys.argv[3]) if len(sys.argv) > 3 else 6
    count = int(sys.argv[4]) if len(sys.argv) > 4 else 12
    tile_h = int(sys.argv[5]) if len(sys.argv) > 5 else 480
    files = pick(sorted(glob.glob(os.path.join(src, "*.png"))), count)
    if not files:
        raise SystemExit(f"no PNG in {src}")
    first = Image.open(files[0])
    tile_w = round(first.width * tile_h / first.height)
    rows = (len(files) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * tile_w, rows * tile_h), BG)
    draw = ImageDraw.Draw(sheet)
    for i, f in enumerate(files):
        im = Image.open(f).convert("RGBA").resize((tile_w, tile_h), Image.LANCZOS)
        x, y = (i % cols) * tile_w, (i // cols) * tile_h
        sheet.paste(im, (x, y), im)
        draw.text((x + 6, y + 4), os.path.splitext(os.path.basename(f))[0], fill=(120, 130, 150))
    sheet.save(out, quality=88)
    print("SHEET", out, len(files))


if __name__ == "__main__":
    main()
