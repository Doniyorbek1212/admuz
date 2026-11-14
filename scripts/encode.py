"""python encode.py <name>
frames/<name>_main (f_0010..f_0141) -> gift_renders/<name>.webp  (720x1280 or 540x960, 150 frames, loop once)
frames/<name>_icon (f_0001..f_0060) -> gift_renders/<name>_icon.webp (192x192, 2 s at 15 fps, endless loop)
Pads 9 transparent frames at both ends of the main clip, then prints size / canvas / frame count."""
import os
import struct
import subprocess
import sys

UZARO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(UZARO, "gift_renders")
FRAMES = os.path.join(UZARO, "frames")
MAIN_LIMIT = 3 * 1024 * 1024
ICON_LIMIT = 200 * 1024
PAD = 9
FIRST, LAST = 10, 141


def webp_info(path):
    """(width, height, stored frames, total ms, loop_count) from the RIFF chunks of an animated WebP.
    libwebp merges identical consecutive frames (e.g. the empty pads) into one longer frame."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        raise ValueError(f"{path}: WebP emas")
    pos = 12
    w = h = loop = None
    frames = ms = 0
    while pos + 8 <= len(data):
        tag, size = data[pos:pos + 4], struct.unpack("<I", data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + size]
        if tag == b"VP8X":
            w = 1 + int.from_bytes(body[4:7], "little")
            h = 1 + int.from_bytes(body[7:10], "little")
        elif tag == b"ANIM":
            loop = struct.unpack("<H", body[4:6])[0]
        elif tag == b"ANMF":
            frames += 1
            ms += int.from_bytes(body[12:15], "little")
        pos += 8 + size + (size & 1)
    return w, h, frames, ms, loop


def ffmpeg(args):
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *args], check=True)


def encode_main(name):
    src = os.path.join(FRAMES, f"{name}_main", "f_%04d.png")
    dst = os.path.join(OUT, f"{name}.webp")
    for scale, q in (("720:1280", 80), ("720:1280", 75), ("540:960", 80), ("540:960", 75)):
        ffmpeg(["-framerate", "30", "-start_number", str(FIRST), "-i", src,
                "-frames:v", str(LAST - FIRST + 1),
                "-vf", f"format=rgba,scale={scale}:flags=lanczos,"
                       f"tpad=start={PAD}:stop={PAD}:color=0x00000000,format=yuva420p",
                "-c:v", "libwebp_anim", "-lossless", "0", "-quality", str(q),
                "-compression_level", "6", "-loop", "1", dst])
        if os.path.getsize(dst) <= MAIN_LIMIT:
            return dst
    raise SystemExit(f"{dst}: 3 MB dan katta hatto 540x960 q75 da ham")


def encode_icon(name):
    src = os.path.join(FRAMES, f"{name}_icon", "f_%04d.png")
    dst = os.path.join(OUT, f"{name}_icon.webp")
    for q in (80, 70, 60, 50):
        ffmpeg(["-framerate", "30", "-start_number", "1", "-i", src, "-frames:v", "60",
                # 15 fps keeps the 2 s loop under 200 KB (30 fps: ~250 KB even at q70)
                "-vf", "fps=15,format=rgba,scale=192:192:flags=lanczos,format=yuva420p",
                "-c:v", "libwebp_anim", "-lossless", "0", "-quality", str(q),
                "-compression_level", "6", "-loop", "0", dst])
        if os.path.getsize(dst) <= ICON_LIMIT:
            return dst
    raise SystemExit(f"{dst}: 200 KB dan katta")


def main():
    name = sys.argv[1]
    os.makedirs(OUT, exist_ok=True)
    for path in (encode_main(name), encode_icon(name)):
        w, h, n, ms, loop = webp_info(path)
        fps = 15 if path.endswith("_icon.webp") else 30
        print(f"RESULT {os.path.basename(path)} | {os.path.getsize(path) / 1024:.0f} KB | {w}x{h} | "
              f"{round(ms / 1000 * fps)} kadr ({ms / 1000:.2f} s @ {fps} fps; {n} ta saqlangan kadr) | loop={loop}")


if __name__ == "__main__":
    main()
