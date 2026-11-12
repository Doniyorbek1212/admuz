"""python build_sound.py <id> <seconds> <clip>@<src_start>+<len>><at>[*gain][~fadein][/fadeout] ...

Mixes trimmed clips from gift_renders/source/<id>/sfx_src/ onto a silent timeline of exactly <seconds>,
then loudness-normalises (-16 LUFS, -1.5 dBTP) to gift_renders/<id>.mp3: mono, 96 kbps.
Two passes on purpose: loudnorm before the pad truncates the file (lion.mp3 came out 3.89 s that way).
Example: bkyte.mp3@0.4+3.2>3.15*1.0/0.8  = 3.2 s from 0.4 s of bkyte.mp3, placed at 3.15 s, gain 1, 0.8 s fade-out.
"""
import json
import os
import re
import subprocess
import sys

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "gift_renders")
LIMITS = (0.79, 0.63, 0.5, 0.4)   # alimiter ceilings tried in turn
MAX_DBTP = -1.0
SPEC = re.compile(r"^(?P<clip>[^@]+)@(?P<ss>[\d.]+)\+(?P<len>[\d.]+)>(?P<at>[\d.]+)(\*(?P<gain>[\d.]+))?(~(?P<fi>[\d.]+))?(/(?P<fo>[\d.]+))?$")


def parse(spec):
    m = SPEC.match(spec)
    if not m:
        raise SystemExit(f"bad clip spec: {spec}")
    d = m.groupdict()
    return d["clip"], float(d["ss"]), float(d["len"]), float(d["at"]), float(d["gain"] or 1), float(d["fi"] or 0.02), float(d["fo"] or 0.05)


def true_peak(path):
    r = subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-i", path, "-af", "ebur128=peak=true", "-f", "null", "-"],
                       capture_output=True, text=True, timeout=120)
    return float(re.findall(r"Peak:\s+(-?[\d.]+) dBFS", r.stderr)[-1])


def main():
    gid, dur, specs = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
    src = os.path.join(OUT, "source", gid, "sfx_src")
    args, chains = [], []
    for i, spec in enumerate(specs):
        clip, ss, ln, at, gain, fi, fo = parse(spec)
        path = os.path.join(src, clip)
        if not os.path.exists(path):
            raise SystemExit(f"missing clip {path}")
        args += ["-i", path]
        ms = int(at * 1000)
        chains.append(f"[{i}:a]atrim={ss}:{ss + ln},asetpts=PTS-STARTPTS,aformat=channel_layouts=mono,"
                      f"afade=t=in:d={fi},afade=t=out:st={max(0.0, ln - fo)}:d={fo},volume={gain},"
                      f"adelay={ms}|{ms}[c{i}]")
    mix = "".join(f"[c{i}]" for i in range(len(specs)))
    # count samples, not time: loudnorm's timestamps left files up to 70 ms short with atrim by seconds
    n = round(dur * 44100)
    exact = f"aresample=44100,asetpts=N/SR/TB,apad=whole_len={n},atrim=end_sample={n}"
    graph = ";".join(chains) + f";{mix}amix=inputs={len(specs)}:normalize=0,{exact}[m]"
    tmp = os.path.join(src, "_mix.wav")
    # an endless apad made ffmpeg hang forever on heart_balloons: pad to a finite length, and never wait without limit
    subprocess.run(["ffmpeg", "-y", "-nostdin", "-loglevel", "error", *args, "-filter_complex", graph, "-map", "[m]",
                    "-ac", "1", "-ar", "44100", tmp], check=True, timeout=120)
    dst = os.path.join(OUT, f"{gid}.mp3")
    # two-pass linear loudnorm: single-pass dynamic mode misses the target on short clips (-10 LUFS seen)
    target = "I=-16:TP=-1.5:LRA=11"
    r = subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-i", tmp, "-af", f"loudnorm={target}:print_format=json",
                        "-f", "null", "-"], capture_output=True, text=True, timeout=120)
    meas = json.loads(r.stderr[r.stderr.rindex("{"):r.stderr.rindex("}") + 1])
    lin = (f"loudnorm={target}:linear=true:measured_I={meas['input_i']}:measured_TP={meas['input_tp']}:"
           f"measured_LRA={meas['input_lra']}:measured_thresh={meas['input_thresh']}:offset={meas['target_offset']}")
    # bright noisy clips overshoot the limiter once MP3-coded (love_letter decoded at +0.9 dBTP): tighten until it holds
    for limit in LIMITS:
        subprocess.run(["ffmpeg", "-y", "-nostdin", "-loglevel", "error", "-i", tmp, "-af",
                        f"{lin},alimiter=limit={limit}:level=false,{exact}", "-ac", "1", "-ar", "44100",
                        "-c:a", "libmp3lame", "-b:a", "96k", dst], check=True, timeout=120)
        peak = true_peak(dst)
        if peak <= MAX_DBTP:
            break
    else:
        raise SystemExit(f"{dst}: true peak {peak:.1f} dBTP even at limit {LIMITS[-1]}")
    os.remove(tmp)
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", dst],
                       capture_output=True, text=True)
    got = float(r.stdout.strip())
    assert abs(got - dur) < 0.04, f"{dst}: {got:.2f} s, want {dur:.2f} s"
    print(f"SOUND {dst} {got:.2f} s")


if __name__ == "__main__":
    main()
