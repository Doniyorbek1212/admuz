#!/bin/bash
# the rest of qfix2's re-encode, 3 gifts at a time (encode is single-core CPU work; 16 cores here), heavy gifts first
cd "/c/Users/Comp X/Desktop/UZARO/scripts" || exit 1
D=../lookdev/qfix3; mkdir -p "$D"
one(){ echo "=== $(date +%H:%M:%S) $1 enc" > "$D/$1.log"; python encode_show.py "$1" >> "$D/$1.log" 2>&1; echo "--- exit $?" >> "$D/$1.log"; }
export -f one; export D
printf '%s\n' universe treasure_chest pegasus phoenix dragon castle golden_crown lion tiger eagle horse dolphin rocket diamond_ring \
  | xargs -P 3 -I{} bash -c 'one {}'
# manifest.json / CREDITS.txt are read-modify-write: parallel runs can drop an entry, so rebuild both once, serially
python - <<'EOF'
import glob, os
import encode_show as e
for g in e.catalogue():
    n = len(glob.glob(os.path.join(e.OUT, "source", g["id"], "show_clean", "f_*.png")))
    e.update_manifest(g, round(n * 1000 / e.SHOW_FPS))
    e.update_credits(g)
print("manifest + credits rebuilt for", len(e.catalogue()), "gifts")
EOF
cat "$D"/*.log > ../lookdev/qfix3.log
echo QFIX3_DONE
grep -aE "^--- exit [1-9]|Traceback|SystemExit" ../lookdev/qfix3.log
