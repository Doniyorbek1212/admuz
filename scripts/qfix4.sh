#!/bin/bash
# dithered alpha for the gifts that ended on few levels (contour rings on a light chat background); one at a time (RAM is tight)
cd "/c/Users/Comp X/Desktop/UZARO/scripts" || exit 1
D=../lookdev/qfix4; mkdir -p "$D"
until grep -aq "^--- exit" ../lookdev/qfix3/treasure_chest.log; do sleep 30; done   # the cover-floor run still writes the chest
for id in hot_air_balloon universe castle pegasus phoenix dolphin golden_crown treasure_chest; do
  { echo "=== $(date +%H:%M:%S) $id enc (dithered alpha)"; python encode_show.py "$id"; echo "--- exit $?"; } > "$D/$id.log" 2>&1
done
cat "$D"/*.log > ../lookdev/qfix4.log
echo QFIX4_DONE
grep -aE "^RESULT [a-z_]+(_icon)?\.webp|^--- exit [1-9]|Traceback|SystemExit" ../lookdev/qfix4.log | sed -E 's/\| [0-9]+x[0-9]+ \|.*cover_max/| cover_max/'
