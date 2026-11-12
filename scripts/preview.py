"""python preview.py <frames_dir> <out.jpg> [scale_height]
Contact sheet: every PNG in the folder over a dark row and a light row, with safe-zone guides."""
import glob
import os
import subprocess
import sys

frames_dir, out = sys.argv[1], sys.argv[2]
h = int(sys.argv[3]) if len(sys.argv) > 3 else 480
files = sorted(glob.glob(os.path.join(frames_dir, "*.png")))
if not files:
    raise SystemExit(f"PNG topilmadi: {frames_dir}")
n = len(files)
inputs = []
for f in files:
    inputs += ["-i", f]
chains = []
for i in range(n):
    chains.append(f"[{i}]scale=-2:{h},split[a{i}][b{i}]")
    for tag, color in (("d", "0x141414"), ("l", "0xE6E6E6")):
        src = f"a{i}" if tag == "d" else f"b{i}"
        # guides: top 8% and bottom 10% bands must stay free of important content
        chains.append(
            f"color=c={color}:s={h * 9 // 16 // 2 * 2}x{h}[bg{tag}{i}];"
            f"[bg{tag}{i}][{src}]overlay=format=auto,"
            f"drawbox=y=ih*0.08:w=iw:h=1:color=red@0.6,drawbox=y=ih*0.90:w=iw:h=1:color=red@0.6[{tag}{i}]")
row_d = "".join(f"[d{i}]" for i in range(n))
row_l = "".join(f"[l{i}]" for i in range(n))
if n > 1:
    chains.append(f"{row_d}hstack={n}[rd];{row_l}hstack={n}[rl];[rd][rl]vstack")
else:
    chains.append("[d0][l0]vstack")
cmd = ["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", ";".join(chains), "-frames:v", "1", out]
subprocess.run(cmd, check=True)
print("PREVIEW", out, n)
