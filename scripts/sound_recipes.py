"""Builds every remaining gift's <id>.mp3 from trims chosen with earshot (see lookdev/sfx_listen.json), synced to the show's frames.
`python sound_recipes.py` builds all, `python sound_recipes.py kitten puppy` builds those. Also copies extra CC0 clips and keeps gifts.json credits true."""
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), "gift_renders", "source")
LIB = os.path.expanduser("~/Sounds/openverse")
FPS = 24

WINDY = (f"{LIB}/swoosh/swoosh-15-windy__qubodup__7843f159-688.mp3", '"Swoosh 15 Windy" by qubodup, CC0 1.0, https://freesound.org/s/60002/')
AIR = (f"{LIB}/swoosh/swosh-swoosh-whoosh-air-sound-free-high__qubodup__f1dc6045-796.mp3", '"Swosh swoosh whoosh air sound, free, high quality" by qubodup, CC0 1.0, https://freesound.org/s/60026/')
SPACE_SW = (f"{LIB}/swoosh/space-swoosh-brighter__gameaudio__7941e04f-292.mp3", '"Space Swoosh - brighter" by GameAudio, CC0 1.0, https://freesound.org/s/220191/')
WOOD = (f"{LIB}/hit/wood-block-hit__thomasjaunism__c807c3a5-6cb.mp3", '"Wood block hit" by thomasjaunism, CC0 1.0, https://freesound.org/s/218460/')
IMPACT = (f"{LIB}/impact/impact__chriskalos__210a2965-240.mp3", '"Impact" by chriskalos, CC0 1.0, https://freesound.org/s/172779/')
CHIME = (os.path.join(SRC, "rose_bloom", "sfx_src", "chime.mp3"), '"GLEAM-GLOW-SFX-CHIME.wav" by newagesoup, CC0 1.0, https://freesound.org/s/351408/')
POP = (os.path.join(SRC, "heart_balloons", "sfx_src", "pop.mp3"), '"Balloon Pop" by Lukeo135, CC0 1.0, https://freesound.org/s/563197/')
WAVES = (os.path.join(SRC, "yacht", "sfx_src", "waves.mp3"), '"Ocean Waves Rough.mp3" by SomeoneCool15, CC0 1.0, https://freesound.org/s/418366/')
BKYTE = (os.path.join(SRC, "lion", "sfx_src", "bkyte_lion_roar_510476.mp3"), '"lion roar" by bkyte, CC0 1.0, https://freesound.org/s/510476/')

FW_BOOM = (os.path.join(SRC, "fireworks", "sfx_src", "boom1.mp3"), '"Firework Explosion 1" by deleted_user_3544904, CC0 1.0, https://freesound.org/s/212678/')
# gift: {name in sfx_src: (source, credit)}
EXTRAS = {
    "rose_bloom": {"windy.mp3": WINDY},
    "heart_balloons": {"chime.mp3": CHIME},
    "love_letter": {"wood.mp3": WOOD, "chime.mp3": CHIME},
    "birthday_cake": {"pop.mp3": POP},
    "motorbike": {"impact.mp3": IMPACT},
    "horse": {"impact.mp3": IMPACT},
    "eagle": {"windy.mp3": WINDY},
    "dolphin": {"waves.mp3": WAVES},
    "tiger": {"bkyte.mp3": BKYTE, "air.mp3": AIR},
    "castle": {"fw_boom.mp3": FW_BOOM},
    "golden_crown": {"chime.mp3": CHIME},
    "diamond_ring": {"chime.mp3": CHIME},
    "universe": {"swoosh.mp3": SPACE_SW},
    "pegasus": {"windy.mp3": WINDY, "impact.mp3": IMPACT},
}
# Castle boom read as a snare (z 1.18 for fireworks) and is no longer in its mix. Downloaded, then rejected by listening: the horn reads as an error buzz (z +3.1), "a ship horn" only z +2.16, p_real 0.18; light flap on a huge wing reads as a keyboard.
DROPPED = {"yacht": ["Ship Horn Distant"], "pegasus": ["Light Wing Flap"], "castle": ["Firework Explosion 3"]}


def t(frame):
    return round(frame / FPS, 3)


def clip(name, start, length, at, gain=1.0, fade_in=None, fade_out=None):
    s = f"{name}.mp3@{start}+{length}>{at}"
    if gain != 1.0:
        s += f"*{gain}"
    if fade_in is not None:
        s += f"~{fade_in}"
    if fade_out is not None:
        s += f"/{fade_out}"
    return s


def flaps(name, start, length, frames, gain):
    return [clip(name, start, length, t(f), gain, 0.03, 0.12) for f in frames]


RECIPES = {
    "rose_bloom": (84, [clip("chime", 1.3, 3.0, t(10), 1.0, None, 0.6), clip("windy", 0, 0.41, t(56), 0.06, 0.05, 0.15)]),
    "heart_balloons": (90, [clip("pop", 0, 0.4, t(56)), clip("chime", 1.4, 1.3, t(57), 0.5, None, 0.5)]),
    "love_letter": (96, [clip("paper", 0.13, 1.0, t(10), 1.6, 0.1, 0.2), clip("wood", 0, 0.25, t(38), 0.5), clip("paper", 0.13, 0.65, t(52), 1.6, 0.05, 0.2),
                         clip("chime", 1.4, 1.1, t(68), 0.9, None, 0.5), clip("glimmer", 0, 1.1, t(68), 0.8, None, 0.5)]),
    "kitten": (96, [clip("meow", 0, 0.6, t(26)), clip("meow", 0, 0.6, t(80), 0.85)]),
    "puppy": (90, [clip("bark", 0.01, 0.29, t(6)), clip("bark", 0.01, 0.29, t(20), 0.85), clip("bark", 0.01, 0.29, t(33)), clip("whine", 0, 1.0, t(54), 0.35, None, 0.4)]),
    "butterflies": (96, [clip("glimmer", 0, 3.5, t(6), 3.0, 0.2, 1.0), clip("flap", 0.09, 2.0, t(8), 0.45, 0.3, 0.4), clip("flap", 0.09, 1.3, t(58), 0.35, 0.3, 0.5)]),
    "fireworks": (96, [clip("boom1", 0, 1.8, t(24)), clip("boom3", 0, 1.4, t(38), 0.75), clip("boom4", 0, 1.5, t(50), 0.7), clip("boom1", 0, 1.35, t(62), 1.0, None, 0.4)]),
    "champagne": (96, [clip("cork", 0.138, 0.3, t(18)), clip("pour", 0.5, 1.0, t(30), 8.0, 0.1, 0.2), clip("pour", 0.6, 0.7, t(48), 8.0, 0.1, 0.2), clip("clink", 0.0, 0.66, t(80), 0.8, 0.005, 0.25)]),
    "birthday_cake": (96, [clip("match", 2.2, 1.43, t(18), 1.0, None, 0.3), clip("pop", 0, 0.4, t(44), 0.2), clip("horn", 0, 1.05, t(45), 1.0, None, 0.3)]),
    "teddy_bear": (96, [clip("squeak", 0.06, 0.24, t(f), 0.6) for f in (10, 22, 34)] + [clip("squeak", 0.445, 0.22, t(54)), clip("squeak", 0.06, 0.24, t(76), 0.8)]),
    "motorbike": (120, [clip("engine", 1.75, 3.35, 0, 1.0, 0.05, 0.4), clip("impact", 0, 0.8, t(84), 0.8, None, 0.3), clip("engine", 2.2, 1.4, t(85), 0.8, 0.05, 0.6)]),
    "yacht": (120, [clip("waves", 0.96, 4.6, 0.2, 1.0, 0.6, 1.0)]),
    "hot_air_balloon": (120, [clip("burner", 0.63, 1.3, t(28), 1.0, 0.08, 0.35), clip("burner", 5.08, 1.27, t(68), 1.0, 0.08, 0.4)]),
    "horse": (132, [clip("gallop", 0.25, 2.3, 0, 1.0, 0.1, 0.25), clip("neigh", 0.3, 2.6, t(65), 1.0, None, 0.5), clip("impact", 0, 0.5, t(100), 0.35, None, 0.2), clip("gallop", 0.25, 1.3, t(100), 1.0, None, 0.4)]),
    "eagle": (120, [clip("windy", 0, 0.41, t(20), 0.2, 0.05, 0.15), clip("windy", 0, 0.41, t(40), 0.15, 0.05, 0.15), clip("cry", 5.23, 1.35, t(53), 2.5, None, 0.2), clip("cry", 2.3, 0.92, t(90), 2.0, None, 0.3)]
              + flaps("windy", 0, 0.41, (76, 89, 102), 0.08)),
    "dolphin": (120, [clip("waves", 0.96, 4.6, 0.2, 0.25, 0.6, 1.0), clip("splash", 1.1, 1.3, t(18), 1.0, None, 0.5), clip("splash", 1.1, 1.3, t(34), 0.75, None, 0.5), clip("call", 1.58, 0.9, t(38), 0.25, 0.1, 0.3),
                      clip("splash", 1.1, 1.0, t(69), 1.0, None, 0.4), clip("splash", 1.1, 1.0, t(82), 0.8, None, 0.4)]),
    "rocket": (120, [clip("launch", 0.46, 4.4, t(14), 1.0, 0.05, 1.8)]),
    "tiger": (144, [clip("roar", 0.9, 1.6, t(50), 1.0, 0.1, 0.4), clip("air", 0, 0.45, t(74), 0.7, 0.03, 0.12), clip("bkyte", 0.4, 2.4, t(78), 0.7, None, 0.8)]),
    "phoenix": (144, [clip("whoosh", 0.17, 1.8, 0.2, 0.5, 0.4, 0.5), clip("whoosh", 0.17, 1.8, t(52), 0.6, 0.2, 0.5), clip("cry", 1.0, 1.0, t(62), 0.7, 0.03, 0.3), clip("whoosh", 0.17, 1.2, t(110), 1.0, 0.05, 0.5), clip("cry", 3.0, 1.0, t(114), 0.9, 0.03, 0.3)]),
    "castle": (156, [clip("bell", 0, 1.4, 0.5, 0.4, None, 0.5), clip("bell", 0, 1.9, t(58), 1.0, None, 0.9), clip("fw_boom", 0, 1.8, t(88), 1.0, None, 0.5), clip("fw_boom", 0, 1.8, t(102), 0.8, None, 0.5), clip("fw_boom", 0, 1.5, t(114), 0.8, None, 0.5), clip("fw_boom", 0, 1.3, t(124), 1.0, None, 0.5)]),
    "golden_crown": (144, [clip("shimmer", 0, 5.0, 0.7, 1.0, 1.0, 1.5), clip("chime", 1.4, 1.77, t(40), 0.8, None, 0.5)]),
    "diamond_ring": (144, [clip("box", 0.927, 0.43, t(30)), clip("shimmer", 0, 1.95, t(46), 0.6, 0.1, 0.5), clip("chime", 1.4, 1.5, t(104), 1.0, None, 0.5), clip("shimmer", 0, 1.6, t(104), 0.5, None, 0.5)]),
    "treasure_chest": (144, [clip("chest", 3.496, 0.48, t(22)), clip("chest", 2.304, 0.62, t(50)), clip("coins1", 0, 1.0, t(61), 1.0, None, 0.2), clip("coins2", 0.5, 3.2, t(65), 0.9, None, 0.8)]),
    "universe": (168, [clip("space", 1.0, 6.0, 0, 1.0, 1.5, 1.0), clip("swoosh", 0, 1.0, t(80), 0.5, 0.1, 0.3), clip("boom", 0, 1.8, t(124) - 0.2, 1.0, None, 0.7)]),
    "pegasus": (168, flaps("windy", 0, 0.41, range(14, 126, 14), 0.5) + [clip("neigh", 0.3, 1.25, t(52), 0.7, None, 0.3), clip("impact", 0, 0.7, t(130), 0.3, None, 0.3), clip("chime", 1.4, 1.5, t(130)), clip("windy", 0, 0.41, t(150), 0.7, 0.03, 0.12)]),
}


def install_extras():
    path = os.path.join(HERE, "gifts.json")
    d = json.load(open(path, encoding="utf8"))
    by_id = {g["id"]: g for g in d["gifts"]}
    for gift, extras in EXTRAS.items():
        for name, (src, credit) in extras.items():
            dst = os.path.join(SRC, gift, "sfx_src", name)
            if not os.path.exists(dst):
                shutil.copy(src, dst)
            if credit not in by_id[gift]["credits"]:
                by_id[gift]["credits"].append(credit)
    for gift, titles in DROPPED.items():
        by_id[gift]["credits"] = [c for c in by_id[gift]["credits"] if not any(x in c for x in titles)]
    tmp = path + ".tmp"
    json.dump(d, open(tmp, "w", encoding="utf8"), ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def main():
    install_extras()
    for gift in sys.argv[1:] or RECIPES:
        frames, specs = RECIPES[gift]
        for s in specs:
            at = float(s.split(">")[1].split("*")[0].split("~")[0].split("/")[0])
            ln = float(s.split("+")[1].split(">")[0])
            assert at + ln <= frames / FPS + 0.001, (gift, s)
        subprocess.run([sys.executable, os.path.join(HERE, "build_sound.py"), gift, str(frames / FPS), *specs], check=True)


if __name__ == "__main__":
    main()
