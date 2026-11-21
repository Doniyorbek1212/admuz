#!/bin/bash
# qtest.sh <id> <script> <show|icon> <frames csv> [samples] : test stills -> lookdev/<id>_<part>.jpg on #10141c
cd "/c/Users/Comp X/Desktop/UZARO/scripts" || exit 1
id=$1; script=$2; part=$3; frames=$4; s=${5:-16}
log="../lookdev/${id}_${part}.log"
d="../gift_renders/source/$id/${part}_test"
rm -f "$d"/f_*.png
"/c/Program Files/Blender Foundation/Blender 4.2/blender.exe" -b --factory-startup -P "$script" -- "$part" "f=$frames" "s=$s" > "$log" 2>&1
grep -E "^(ROSE|EXTENT|INFO_)|Traceback|Error:|^  File \"C:.*scripts" "$log" | cut -c1-220 | tail -25
python - <<EOF
from PIL import Image
import glob,os
files=sorted(glob.glob(r"$d/f_*.png"))
if not files: raise SystemExit("NO FRAMES")
ims=[Image.open(f).convert("RGBA") for f in files]
w,h=ims[0].size
s=min(1.0,380/w) if w>380 else 1.0
tw,th=int(w*s),int(h*s)
cols=min(6,len(ims)); rows=(len(ims)+cols-1)//cols
sheet=Image.new("RGB",(cols*tw,rows*th),(16,20,28))
for i,im in enumerate(ims):
    t=im.resize((tw,th),Image.LANCZOS); sheet.paste(t,((i%cols)*tw,(i//cols)*th),t)
sheet.save(r"../lookdev/${id}_${part}.jpg",quality=88)
print("SHEET",len(ims),sheet.size)
EOF
