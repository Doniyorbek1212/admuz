#!/bin/bash
# full production run: dragon relight, then every remaining gift in spec order, one at a time
cd "/c/Users/Comp X/Desktop/UZARO/scripts" || exit 1
B="/c/Program Files/Blender Foundation/Blender 4.2/blender.exe"
S="C:/Users/Comp X/Desktop/UZARO/gift_renders/source/dragon"
L=../lookdev/dragon_fix.log; : > "$L"
"$B" -b "$S/dragon_show.blend" -P fix_dragon.py -- "$S/show" 1 156 >> "$L" 2>&1
"$B" -b "$S/dragon_icon.blend" -P fix_dragon.py -- "$S/icon" 1 30 >> "$L" 2>&1
python encode_show.py dragon >> "$L" 2>&1
./runq.sh full.log helicopter:heli_show.py rose_bloom:rose_bloom_show.py heart_balloons:heart_balloons_show.py love_letter:love_letter_show.py kitten:kitten_show.py puppy:puppy_show.py butterflies:butterflies_show.py fireworks:fireworks_show.py champagne:champagne_show.py birthday_cake:birthday_cake_show.py teddy_bear:teddy_bear_show.py motorbike:motorbike_show.py yacht:yacht_show.py hot_air_balloon:hot_air_balloon_show.py horse:horse_show.py eagle:eagle_show.py dolphin:dolphin_show.py rocket:rocket_show.py tiger:tiger_show.py phoenix:phoenix_show.py castle:castle_show.py golden_crown:golden_crown_show.py diamond_ring:diamond_ring_show.py treasure_chest:treasure_chest_show.py universe:universe_show.py pegasus:pegasus_show.py
echo QFULL_DONE
