#!/usr/bin/env bash
# Make hub homes for the shadow bench and the soak from COPIES of tonight's pristine import (the seed stays untouched).
#   prep_homes.sh BIN TAG [SEED_DB]   → scratch/p8/bench-TAG/ (seat 'shadow', scope household, read-only)
#                             scratch/p8/soak-TAG/  (seat 'soak', scopes syn-soak,household, writes)
set -euo pipefail
BIN="$1"; TAG="$2"; P="$HOME/zigmem/scratch/p8"; SEED="${3:-$P/shadow/zigmem.db}"
for d in bench soak; do
  H="$P/$d-$TAG"; [ -e "$H" ] && { echo "exists: $H"; exit 1; }
  mkdir -m 700 "$H"; cp --reflink=auto "$SEED" "$H/zigmem.db"; chmod 600 "$H/zigmem.db"
done
for d in bench soak; do "$BIN" household bootstrap --home "$P/$d-$TAG" --file "$HOME/zigmem/deploy/household.json" > /dev/null; done
"$BIN" token add --seat shadow --scopes "*" --home "$P/bench-$TAG" > "$P/bench-$TAG/shadow.token"; chmod 600 "$P/bench-$TAG/shadow.token"
"$BIN" token add --seat soak --scopes "*" --writes --home "$P/soak-$TAG" > "$P/soak-$TAG/soak.token"; chmod 600 "$P/soak-$TAG/soak.token"
ls -la "$P/bench-$TAG" "$P/soak-$TAG"
