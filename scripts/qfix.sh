#!/bin/bash
# after final QA: re-render the six fixed shows (kitten icon too: its lids changed), then re-encode all 30 at the better alpha ladder
cd "/c/Users/Comp X/Desktop/UZARO/scripts" || exit 1
L=../lookdev/qfix.log; : > "$L"
B="/c/Program Files/Blender Foundation/Blender 4.2/blender.exe"
step(){ echo "=== $(date +%H:%M:%S) $1" >> "$L"; shift; "$@" >> "$L" 2>&1; echo "--- exit $?" >> "$L"; }
for id in diamond_ring heart_balloons yacht rose_bloom universe kitten; do
  step "$id show" "$B" -b --factory-startup -P "${id}_show.py" -- show s=40
done
step "kitten icon" "$B" -b --factory-startup -P kitten_show.py -- icon s=32
for id in rose_bloom heart_balloons love_letter kitten puppy butterflies fireworks champagne birthday_cake teddy_bear sports_car motorbike helicopter plane yacht hot_air_balloon horse eagle dolphin rocket lion tiger dragon phoenix castle golden_crown diamond_ring treasure_chest universe pegasus; do
  step "$id enc" python encode_show.py "$id"
done
echo QFIX_DONE
