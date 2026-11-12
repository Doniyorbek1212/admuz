#!/bin/bash
# runq.sh <log> <id>:<script> ... : full show + icon + encode for each gift, one at a time
cd "/c/Users/Comp X/Desktop/UZARO/scripts" || exit 1
L="../lookdev/$1"; shift; : > "$L"
B="/c/Program Files/Blender Foundation/Blender 4.2/blender.exe"
step(){ echo "=== $(date +%H:%M:%S) $1" >> "$L"; shift; "$@" >> "$L" 2>&1; echo "--- exit $?" >> "$L"; }
for item in "$@"; do
  id=${item%%:*}; sc=${item##*:}
  step "$id show" "$B" -b --factory-startup -P "$sc" -- show s=${SHOW_S:-40}
  step "$id icon" "$B" -b --factory-startup -P "$sc" -- icon s=${ICON_S:-32}
  step "$id enc" python encode_show.py "$id"
done
grep -aE "^===|^--- exit|^RESULT|^SOUND|Traceback" "$L" | cut -c1-210
