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
SHIMMER = (os.path.join(SRC, "golden_crown", "sfx_src", "shimmer.mp3"), '"Shimmery.wav" by opticaillusions, CC0 1.0, https://freesound.org/s/521886/')
FIRE_WHOOSH = (os.path.join(SRC, "phoenix", "sfx_src", "whoosh.mp3"), '"fire-whoosh.wav" by hnhnh, CC0 1.0, https://freesound.org/s/244926/')
GALLOP = (os.path.join(SRC, "horse", "sfx_src", "gallop.mp3"), '"Horse Gallop - Loopable.mp3" by HebronTheatre, CC0 1.0, https://freesound.org/s/197212/')
NEIGH = (os.path.join(SRC, "horse", "sfx_src", "neigh.mp3"), '"Horse_neighing.wav" by Lydmakeren, CC0 1.0, https://freesound.org/s/510903/')
SPACE_HUM = (os.path.join(SRC, "universe", "sfx_src", "space.mp3"), '"Low spacey sound" by User391915396, CC0 1.0, https://freesound.org/s/495010/')
DEEP_BOOM = (os.path.join(SRC, "universe", "sfx_src", "boom.mp3"), '"Deep Boom" by Za-Games, CC0 1.0, https://freesound.org/s/539968/')
# gift: {name in sfx_src: (source, credit)}
SPLASH = (os.path.join(SRC, "dolphin", "sfx_src", "splash.mp3"), '"water splash" by audiosmedia, CC0 1.0, https://freesound.org/s/243519/')
WHALE_SONG = (f"{LIB}/humpback-whale/lowwhalesong-wav__rebekahday__a899c175-3ea.mp3", '"LowWhalesong.wav" by RebekahDay, CC0 1.0, https://freesound.org/s/171945/')
BIG_SPLASH = (f"{LIB}/big-splash-water/big-splash-wav__bird-man__60466366-6eb.mp3", '"Big Splash.wav" by Bird_man, CC0 1.0, https://freesound.org/s/316744/')

B2 = f"{LIB}/batch2"
TRUMPET = (f"{B2}/trumpet.mp3", '"Elephant Trumpets Growls.flac" by D.jones, CC0 1.0, https://freesound.org/s/527845/')
WHISTLE = (f"{B2}/whistle.mp3", '"Steam Whistle.mp3" by Bidone, CC0 1.0, https://freesound.org/s/71778/')
CHUFF = (f"{B2}/chuff.mp3", '"Big Steam Engine Perfect Loop (24bit flac)" by steaq, CC0 1.0, https://freesound.org/s/594215/')
HOWL = (f"{B2}/howl.mp3", '"wolf-howling-sound-effect.mp3" by cactustt, CC0 1.0, https://freesound.org/s/490256/')
PEACOCK = (f"{B2}/peacock.mp3", '"Bird, Peacock Call" by Kinoton, CC0 1.0, https://freesound.org/s/688203/')
CAMEL = (f"{B2}/camel.mp3", '"Camels - Dromedary; Single; Close Perspective" by TheKingOfGeeks360, CC0 1.0, https://freesound.org/s/801959/')
PENGUIN = (f"{B2}/penguin.mp3", '"Penguin Squeak" by Breviceps, CC0 1.0, https://freesound.org/s/705839/')
PLUCK = (f"{B2}/pluck.mp3", '"Guitar Pluck" by Baconation, CC0 1.0, https://freesound.org/s/592442/')
BITE = (f"{B2}/bite.mp3", '"Apple Bite" by phatcorns, CC0 1.0, https://freesound.org/s/250106/')
CHEW = (f"{B2}/chew.mp3", '"Chomp Chew Bite.wav" by bbrocer, CC0 1.0, https://freesound.org/s/382650/')
POUR = (os.path.join(SRC, "champagne", "sfx_src", "pour.mp3"), '"Pouring Champagne" by snakebarney, CC0 1.0, https://freesound.org/s/138125/')
CLINK = (os.path.join(SRC, "champagne", "sfx_src", "clink.mp3"), '"Wine glass clink deeper.wav" by lmr9, CC0 1.0, https://freesound.org/s/178178/')
GLIMMER = (os.path.join(SRC, "butterflies", "sfx_src", "glimmer.mp3"), '"Glimmer.wav" by opticaillusions, CC0 1.0, https://freesound.org/s/521873/')
BELL = (os.path.join(SRC, "castle", "sfx_src", "bell.mp3"), '"Church Bell 1" by nomiqbomi, CC0 1.0, https://freesound.org/s/578543/')
CHORD = (f"{B2}/guitar_dist_chord_speedy.mp3", '"Dist_Chr_A&D_strs_pm.wav" by SpeedY, CC0 1.0, https://freesound.org/s/11918/')
RIFF = (f"{B2}/guitar_riff_rizzard.mp3", '"E Guitar Riff" by Rizzard, CC0 1.0, https://freesound.org/s/563588/')
BEAT120 = (f"{B2}/beat120_djgriffin.mp3", '"calculus 120 phosocyn.wav" by djgriffin, CC0 1.0, https://freesound.org/s/64612/')
KICK = (f"{B2}/kick_laya.mp3", '"trance_kick01.wav" by laya, CC0 1.0, https://freesound.org/s/33325/')

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
    "golden_carriage": {"gallop.mp3": GALLOP, "neigh.mp3": NEIGH, "chime.mp3": CHIME, "shimmer.mp3": SHIMMER},
    "starship": {"space.mp3": SPACE_HUM, "boom.mp3": DEEP_BOOM, "swoosh.mp3": SPACE_SW},
    "whale": {"waves.mp3": WAVES, "splash.mp3": SPLASH, "song.mp3": WHALE_SONG, "crash.mp3": BIG_SPLASH, "chime.mp3": CHIME},
    "elephant": {"trumpet.mp3": TRUMPET, "pour.mp3": POUR, "glimmer.mp3": GLIMMER},
    "latte": {"clink.mp3": CLINK, "pour.mp3": POUR, "chime.mp3": CHIME},
    "tulips": {"glimmer.mp3": GLIMMER, "windy.mp3": WINDY, "chime.mp3": CHIME},
    "pomegranate": {"wood.mp3": WOOD, "bite.mp3": BITE, "glimmer.mp3": GLIMMER},
    "dutor": {"pluck.mp3": PLUCK, "glimmer.mp3": GLIMMER},
    "magic_carpet": {"windy.mp3": WINDY, "shimmer.mp3": SHIMMER, "air.mp3": AIR},
    "steam_train": {"chuff.mp3": CHUFF, "whistle.mp3": WHISTLE},
    "timurid_palace": {"shimmer.mp3": SHIMMER, "chime.mp3": CHIME, "fw_boom.mp3": FW_BOOM},
    "camel": {"camel.mp3": CAMEL, "clink.mp3": CLINK, "windy.mp3": WINDY},
    "bunny": {"glimmer.mp3": GLIMMER, "chime.mp3": CHIME, "air.mp3": AIR},
    "panda": {"chew.mp3": CHEW, "glimmer.mp3": GLIMMER},
    "penguin": {"penguin.mp3": PENGUIN, "air.mp3": AIR, "glimmer.mp3": GLIMMER},
    "wolf": {"howl.mp3": HOWL, "windy.mp3": WINDY},
    "peacock": {"peacock.mp3": PEACOCK, "air.mp3": AIR, "glimmer.mp3": GLIMMER, "shimmer.mp3": SHIMMER},
    "swans": {"waves.mp3": WAVES, "glimmer.mp3": GLIMMER, "chime.mp3": CHIME, "shimmer.mp3": SHIMMER},
    "guitar": {"chord.mp3": CHORD, "riff.mp3": RIFF, "air.mp3": AIR, "glimmer.mp3": GLIMMER},
    "headphones": {"beat.mp3": BEAT120, "kick.mp3": KICK, "air.mp3": AIR, "glimmer.mp3": GLIMMER},
    "uzaro": {"air.mp3": AIR, "glimmer.mp3": GLIMMER, "shimmer.mp3": SHIMMER, "chime.mp3": CHIME, "wood.mp3": WOOD,
              "boom.mp3": DEEP_BOOM},
    "humo": {"windy.mp3": WINDY, "chime.mp3": CHIME, "shimmer.mp3": SHIMMER, "whoosh.mp3": FIRE_WHOOSH},
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
    # batch 2. snow_leopard: wind bed, paw crunches through the stalk, a snarl into the takeoff whoosh and powder burst
    # golden_carriage: a gallop bed swelling as the team nears, a neigh at the closest pass, the road's shimmer, a chime as it leaves
    "golden_carriage": (168, [clip("gallop", 0.25, 2.4, 0.0, 0.45, 0.6, 0.2), clip("gallop", 0.25, 2.4, 2.25, 0.85, 0.15, 0.2),
                              clip("gallop", 0.25, 2.4, 4.5, 0.7, 0.15, 0.9), clip("neigh", 0.3, 1.6, t(70), 0.6, None, 0.5),
                              clip("shimmer", 0, 5.5, 0.4, 0.45, 1.0, 1.5), clip("chime", 1.4, 2.0, t(118), 0.6, None, 0.9)]),
    # humo: a rising whoosh, one huge downbeat as the halo blooms on a chime, a shimmer bed, slow glide beats, a driving climb out
    "starship": (168, [clip("swoosh", 0, 1.0, t(4), 0.8, 0.1, 0.2), clip("boom", 0, 1.6, t(12), 0.45, None, 0.6), clip("space", 1.0, 5.6, t(16), 0.7, 0.8, 0.8),
                       clip("swoosh", 0, 1.0, t(116), 0.7, 0.3, 0.1), clip("boom", 0, 1.6, t(128), 0.9, None, 0.8)]),
    "humo": (168, [clip("whoosh", 0.17, 1.6, 0.3, 0.35, 0.5, 0.5), clip("whoosh", 0.4, 0.9, 1.5, 0.3, 0.25, 0.3), clip("windy", 0, 0.41, t(56), 0.9, 0.03, 0.12), clip("chime", 1.4, 2.4, t(60), 0.9, None, 0.9),
                   clip("shimmer", 0, 4.4, t(60), 0.7, 0.4, 1.4)] + flaps("windy", 0, 0.41, (86, 112, 118, 134, 150), 0.45)
                  + [clip("whoosh", 0.17, 1.2, t(138), 0.5, 0.1, 0.4)]),
    "snow_leopard": (144, [clip("wind", 2.0, 5.9, 0.05, 0.6, 0.8, 1.2), clip("steps", 0.0, 2.3, 0.05, 0.45, 0.3, 0.4),
                           clip("roar", 0.9, 0.75, t(82), 0.8, 0.08, 0.3), clip("air", 0, 0.45, t(84), 0.55, 0.03, 0.12),
                           clip("crunch", 0, 0.6, t(85), 0.25, 0.01, 0.25), clip("air", 0, 0.45, t(118), 0.35, 0.05, 0.15)]),
    "pegasus": (168, flaps("windy", 0, 0.41, range(14, 126, 14), 0.5) + [clip("neigh", 0.3, 1.25, t(52), 0.7, None, 0.3), clip("impact", 0, 0.7, t(130), 0.3, None, 0.3), clip("chime", 1.4, 1.5, t(130)), clip("windy", 0, 0.41, t(150), 0.7, 0.03, 0.12)]),
    # elephant: trumpet as the trunk tops out (earshot 0.087-1.325 z +5.0), the spray as water and glitter
    "elephant": (144, [clip("trumpet", 0.087, 1.238, t(72), 1.0, None, 0.3), clip("pour", 0.5, 1.0, t(80), 6.0, 0.1, 0.3),
                       clip("glimmer", 0, 2.0, t(82), 2.0, 0.1, 0.8)]),
    # latte: glass settles on the saucer, milk pours twice, a chime as the steam heart closes
    "latte": (96, [clip("clink", 0.0, 0.66, t(16), 0.5, 0.005, 0.25), clip("pour", 0.5, 1.0, t(22), 8.0, 0.1, 0.2),
                   clip("pour", 0.6, 0.7, t(36), 8.0, 0.1, 0.2), clip("chime", 1.3, 1.0, t(72), 0.5, None, 0.6)]),
    # tulips: a glimmer bed as they grow and open, a chime at the first bloom, breeze puffs as petals blow away
    "tulips": (96, [clip("glimmer", 0, 3.4, t(4), 2.5, 0.3, 1.0), clip("chime", 1.3, 1.5, t(30), 0.6, None, 0.6),
                    clip("windy", 0, 0.41, t(58), 0.3, 0.05, 0.15), clip("windy", 0, 0.41, t(66), 0.25, 0.05, 0.15)]),
    # pomegranate: settles, cracks (earshot "a crunchy fruit bite crack" 0-1.02 z +3.6), bursts, seeds glint
    "pomegranate": (96, [clip("wood", 0, 0.25, t(22), 0.4), clip("bite", 0, 1.02, t(26), 1.0, None, 0.2),
                         clip("bite", 0, 0.6, t(36), 0.8, None, 0.15), clip("glimmer", 0, 2.0, t(44), 1.5, 0.1, 0.8),
                         clip("glimmer", 0, 0.45, t(84), 1.2, 0.02, 0.25)]),  # the sparkle dissolve
    # dutor: one pluck per string hit (earshot "a single plucked string note ringing" 0.032-1.71 z +4.3)
    "dutor": (120, [clip("pluck", 0.032, 1.6, t(f), 0.8, None, 0.4) for f in (34, 46, 58, 66)]
                   + [clip("pluck", 0.032, 1.3, t(f), 0.8, None, 0.4) for f in (78, 86)]
                   + [clip("glimmer", 0, 1.0, t(96), 1.5, 0.1, 0.6)]),
    # magic_carpet: wind in, a shimmer bed under the flight, a swoosh through the loop, wind out
    "magic_carpet": (120, [clip("windy", 0, 0.41, t(4), 0.5, 0.05, 0.15), clip("shimmer", 0, 4.6, 0.2, 0.5, 0.6, 1.0),
                           clip("air", 0, 0.45, t(30), 0.6, 0.03, 0.12), clip("windy", 0, 0.41, t(80), 0.5, 0.05, 0.15)]),
    # steam_train: chuffing bed (earshot "a steam engine chuffing" z +3.5-4.2, realness uncertain 0.58), whistle at the burst (z +4.8)
    "steam_train": (120, [clip("chuff", 0, 3.4, 0.05, 0.9, 0.6, 0.2), clip("chuff", 0, 1.5, 3.45, 0.9, 0.1, 0.8),
                          clip("whistle", 0.0, 2.0, t(64), 0.8, None, 0.5)]),
    # timurid_palace: shimmer as it rises, a chime as the light wave starts, three firework booms
    "timurid_palace": (156, [clip("shimmer", 0, 5.0, 0.5, 0.6, 1.0, 1.5), clip("chime", 1.3, 1.6, t(62), 0.7, None, 0.6),
                             clip("fw_boom", 0, 1.8, t(98), 1.0, None, 0.5), clip("fw_boom", 0, 1.6, t(110), 0.8, None, 0.5),
                             clip("fw_boom", 0, 1.3, t(122), 0.9, None, 0.5)]),
    # whale (earshot: song 5.73-9.37 z +4.7, crash splash 0.005-1.67 z +5.0): sea bed, a splash as it breaks the surface,
    # its song through the hang, the huge crash, a chime as the rainbow forms
    "whale": (144, [clip("waves", 0.96, 5.6, 0.2, 0.25, 0.6, 1.0), clip("splash", 1.1, 1.3, t(16), 0.9, None, 0.5),
                    clip("song", 5.725, 3.64, t(30), 0.8, 0.3, 0.8), clip("crash", 0.005, 1.665, t(84), 1.0, None, 0.4),
                    clip("chime", 1.3, 1.6, t(100), 0.4, None, 0.6)]),
    # camel: breeze in, a grunt mid-stride (earshot "a camel grunting" 0.102-1.102 z +2.8), small bell clinks on the sway
    "camel": (120, [clip("windy", 0, 0.41, t(4), 0.3, 0.05, 0.15), clip("clink", 0, 0.4, t(22), 0.2, 0.005, 0.2),
                    clip("camel", 0.102, 1.0, t(48), 1.0, 0.02, 0.3), clip("clink", 0, 0.4, t(58), 0.2, 0.005, 0.2),
                    clip("clink", 0, 0.4, t(94), 0.18, 0.005, 0.2)]),
    # bunny: glitter as it sits, a soft chime on the ear flop, a little air as it hops off
    "bunny": (96, [clip("glimmer", 0, 1.6, t(36), 1.5, 0.05, 0.7), clip("chime", 1.3, 1.0, t(50), 0.35, None, 0.5),
                   clip("air", 0, 0.45, t(70), 0.3, 0.03, 0.15)]),
    # panda: chewing while it sits (earshot "chewing crunchy food" 7.843-9.804 z +5.5), a glimmer on the wave
    "panda": (96, [clip("glimmer", 0, 0.6, t(1), 1.0, 0.02, 0.3), clip("chew", 7.843, 1.96, t(40), 1.0, 0.05, 0.3),
                   clip("glimmer", 0, 1.2, t(54), 1.2, 0.05, 0.6), clip("glimmer", 0, 0.4, t(86), 1.0, 0.02, 0.25)]),
    # penguin: squeak at the flop (earshot "a small squeak" 0-0.6 z +2.9), air through the slide, sparkle, proud squeak
    "penguin": (96, [clip("penguin", 0, 0.6, t(20), 0.9, None, 0.15), clip("air", 0, 0.45, t(40), 0.5, 0.03, 0.15),
                     clip("glimmer", 0, 1.4, t(42), 1.2, 0.05, 0.6), clip("penguin", 0, 0.6, t(80), 1.0, None, 0.15),
                     clip("glimmer", 0, 0.6, t(1), 1.0, 0.02, 0.3), clip("glimmer", 0, 0.32, t(88), 1.0, 0.02, 0.2)]),
    # wolf: night breeze, the howl as the head lifts (earshot "a single long wolf howl" 0.462-2.462 z +4.6)
    "wolf": (120, [clip("windy", 0, 0.41, t(4), 0.25, 0.05, 0.15), clip("howl", 0.462, 2.0, t(62), 1.0, 0.1, 0.5),
                   clip("windy", 0, 0.41, t(106), 0.3, 0.05, 0.2)]),  # it fades into the night
    # peacock: sparkle as it appears, a swish as the train fans open, its call when the fan is up (earshot "a single
    # loud peacock call" 1.155-2.015 z +5.4, clean), glimmer on the eye wave, shimmer as it dissolves
    "peacock": (120, [clip("shimmer", 0, 0.9, t(2), 0.45, 0.05, 0.4), clip("air", 0, 0.45, t(26), 0.5, 0.03, 0.15),
                      clip("peacock", 1.155, 0.86, t(44), 0.9, 0.01, 0.2), clip("glimmer", 0, 1.4, t(58), 1.1, 0.05, 0.6),
                      clip("shimmer", 0, 0.8, t(100), 0.5, 0.05, 0.4)]),
    # swans: soft lake bed under everything, glints as they meet, a chime when the beaks touch, shimmer on the dissolve
    "swans": (144, [clip("waves", 0, 5.9, 0.05, 0.18, 0.8, 1.2), clip("glimmer", 0, 1.6, t(54), 1.0, 0.1, 0.7),
                    clip("chime", 1.3, 1.5, t(100), 0.6, None, 0.6), clip("shimmer", 0, 1.05, t(118), 0.5, 0.1, 0.6)]),
    # guitar (earshot "a distorted electric guitar power chord strum": SpeedY 0-2.015 z +5.0, Rizzard 5.34-6.69 z +4.9):
    # whoosh in, glimmer as the stars light, chord on the first strum, riff on the second, whoosh out
    "guitar": (120, [clip("air", 0, 0.45, t(2), 0.6, 0.03, 0.15), clip("glimmer", 0, 1.2, t(30), 1.2, 0.05, 0.6),
                     clip("chord", 0.0, 1.0, t(46), 0.9, 0.005, 0.3), clip("riff", 5.34, 1.35, t(70), 1.0, 0.005, 0.4),
                     clip("air", 0, 0.45, t(102), 0.6, 0.03, 0.15)]),
    # headphones (earshot: kick z +5.0; 120 bpm beat z +3.5, synthesized as electronic music is): drop-in whoosh,
    # glimmer as the neon draws on, the beat from the first thump, whoosh out
    "headphones": (120, [clip("air", 0, 0.45, t(2), 0.6, 0.03, 0.15), clip("glimmer", 0, 0.9, t(26), 1.0, 0.05, 0.5),
                         clip("kick", 0.011, 0.75, t(36), 1.0, None, 0.2), clip("beat", 0.0, 3.0, t(36), 0.9, None, 0.4),
                         clip("air", 0, 0.45, t(104), 0.6, 0.03, 0.15)]),
    # uzaro: a whoosh for each figure swinging in, glimmer as the heads pop, shimmer on the gold ribbon, a chime as the
    # chat bubble pops, three soft wood ticks for the dots, the deep boom and glimmer on the hero flare, shimmer out
    "uzaro": (168, [clip("air", 0, 0.45, t(3), 0.55, 0.03, 0.15), clip("air", 0, 0.45, t(7), 0.45, 0.03, 0.15),
                    clip("glimmer", 0, 0.9, t(14), 0.8, 0.05, 0.4), clip("shimmer", 0, 0.8, t(30), 0.5, 0.05, 0.3),
                    clip("chime", 1.3, 1.2, t(44), 0.7, None, 0.5)]
                   + [clip("wood", 0, 0.25, t(f), 0.3) for f in (54, 59, 64)]
                   + [clip("boom", 0, 1.8, t(78) - 0.05, 0.7, None, 0.6), clip("glimmer", 0, 1.4, t(80), 1.0, 0.05, 0.6),
                      clip("shimmer", 0, 1.1, t(136), 0.55, 0.05, 0.5)]),
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
