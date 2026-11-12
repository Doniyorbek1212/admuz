#!/bin/bash
# after the decoded check: universe planets now swallowed before the flash, then all 30 re-encoded on the alpha-level ladder
cd "/c/Users/Comp X/Desktop/UZARO/scripts" || exit 1
L=../lookdev/qfix2.log; : > "$L"
B="/c/Program Files/Blender Foundation/Blender 4.2/blender.exe"
step(){ echo "=== $(date +%H:%M:%S) $1" >> "$L"; shift; "$@" >> "$L" 2>&1; echo "--- exit $?" >> "$L"; }
step "universe show" "$B" -b --factory-startup -P universe_show.py -- show s=40
for id in love_letter rose_bloom heart_balloons kitten puppy butterflies fireworks champagne birthday_cake teddy_bear sports_car motorbike helicopter plane yacht hot_air_balloon horse eagle dolphin rocket lion tiger dragon phoenix castle golden_crown diamond_ring treasure_chest universe pegasus; do
  step "$id enc" python encode_show.py "$id"
done
echo QFIX2_DONE
grep -aE "^--- exit [1-9]|Traceback|SystemExit" "$L"
