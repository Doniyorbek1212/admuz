#!/bin/bash
# qall.sh <id>:<script>:<frames> ... : test stills for many gifts, one after the other; never stops on a failing one
cd "/c/Users/Comp X/Desktop/UZARO/scripts" || exit 1
for item in "$@"; do
  IFS=: read -r id sc fr part <<< "$item"
  part=${part:-show}
  echo "=== $(date +%H:%M:%S) $id $part"
  ./qtest.sh "$id" "$sc" "$part" "$fr" 16 2>&1 | tail -n 14
done
echo QALL_DONE
