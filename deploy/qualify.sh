#!/usr/bin/env bash
# Qualify a zigmem COMMIT for deploy — the whole phase-8 gate pipeline, one command, nothing switched live:
#   ~/zigmem/deploy/qualify.sh <commit> [--soak-secs 10800] [--seed DB]     (default: a FRESH shadow import with this commit's loader)
# 1 build -Drelease from git archive → scratch/p8/cand-<sha12>/
# 2 shadow import (same sources + exclusions as phase 3) with the candidate's zigmem-recall → scratch/p8/shadow-<sha12>/
# 3 bench + soak homes from COPIES of that store, household bootstrapped (deploy/household.json)
# 4 shadow bench (hub HTTP + phase-3 CLI + live-local the reranked lane; 130-q, family 93, 300 real seat prompts). SAFETY: 0 leaks
#   on every zigmem lane, all HTTP 200; gate 3 (hub 130-q >= live) recorded, required only by --wire
# 5 SAFETY on this exact binary: auth, bind, fuzz, p95 latency, kill -9 (tests/integration/p4_gates.py), load recorded
# 6 soak 3 h, kill -9 at 30 min — LEAK gate: ceiling computed before the workload, last-60-min slope <= 1 MB/h, restart within
# 7 stamp → 8 deploy+rollback round trip on a scratch HOME WITH the seed (fake systemctl, port 18190) → stamp again
# 9 only if every SAFETY gate is green: deploy/release ← candidate (old one kept as deploy/release.prev-<ts>).
# Any safety RED stops the pipeline; deploy/release is left as it was. Receipts: receipts/phase8/*_<sha12>.json.
set -uo pipefail
ZM="$HOME/zigmem"; COMMIT="${1:?commit}"; shift
SOAK=10800; KILL_AT=1800; SEED=""   # 3 h, kill -9 at 30 min: the last-60-min window starts 90 min after the restart
while [ $# -gt 0 ]; do case "$1" in --soak-secs) SOAK="$2"; shift ;; --seed) SEED="$2"; shift ;; *) echo "unknown $1"; exit 64 ;; esac; shift; done
SHA=$(git -C "$ZM" rev-parse --verify "$COMMIT^{commit}") || exit 1; S=${SHA:0:12}
CAND="$ZM/scratch/p8/cand-$S"; PY="python3"; LOG="$ZM/scratch/p8/qualify_$S.log"
say() { echo "$(date '+%F %T') qualify $S: $* [load $(cut -d' ' -f1-3 /proc/loadavg)]" | tee -a "$LOG"; }
red() { say "RED: $* — stopped; deploy/release unchanged"; exit 1; }
SAFE='import importlib.util,json,sys;s=importlib.util.spec_from_file_location("k",sys.argv[2]);K=importlib.util.module_from_spec(s);s.loader.exec_module(K);r=json.load(open(sys.argv[1]));ok,sf,q=K.split_gates(r);print("safety",sf,"quality",q,K.gap_text(r));sys.exit(0 if ok else 1)'
[ -e "$CAND" ] && red "$CAND exists (one qualification per commit)"
say "build"; "$ZM/deploy/build_release.sh" build "$SHA" --out "$CAND" > "$ZM/scratch/p8/qualify_$S.build.log" 2>&1 || red "build"
BSHA=$(sha256sum < "$CAND/zigmem" | cut -d' ' -f1); say "binary $BSHA"
if [ -z "$SEED" ]; then
  say "shadow import (fresh, this commit's loader)"
  bash "$ZM/tests/phase8/shadow_import.sh" "$ZM/scratch/p8/shadow-$S" "$CAND/zigmem-recall" > "$ZM/scratch/p8/shadow_import_$S.out" 2>&1 || red "shadow import"
  SEED="$ZM/scratch/p8/shadow-$S/zigmem.db"; say "import $(cat "$ZM/scratch/p8/shadow-$S/load.json")"
fi
say "homes"; bash "$ZM/tests/phase8/prep_homes.sh" "$CAND/zigmem" "$S" "$SEED" > "$ZM/scratch/p8/prep_$S.out" 2>&1 || red "prep homes"
say "shadow bench"; bash "$ZM/tests/phase8/run_shadow_bench.sh" "$CAND" "$ZM/scratch/p8/bench-$S" "$S" > "$ZM/scratch/p8/bench_$S.out" 2>&1
grep -q "hub stopped" "$ZM/scratch/p8/bench_$S.out" || red "bench hub did not stop cleanly"
$PY "$ZM/tests/phase8/rescore_seat.py" "$S" >> "$LOG" 2>&1
/usr/bin/python3 -I -c "$SAFE" "$ZM/receipts/phase8/shadow_bench_$S.json" "$ZM/deploy/zm_kit.py" | tee -a "$LOG" || red "shadow bench SAFETY gate (leaks/http) — receipts/phase8/shadow_bench_$S.json"
say "safety gates (auth, bind, fuzz, latency, kill -9) on this exact binary"
$PY "$ZM/tests/phase8/p4_safety.py" --rel "$CAND" --tag "$S" > "$ZM/scratch/p8/safety_$S.out" 2>&1 || red "safety gates (receipts/phase8/safety_$S.json; latency RED under load → re-run that gate when quiet: p4_safety.py --rel $CAND --tag $S --gates latency)"
say "soak ${SOAK}s, kill -9 at ${KILL_AT}s"
$PY "$ZM/tests/phase8/soak.py" --bin "$CAND/zigmem" --home "$ZM/scratch/p8/soak-$S" --src "$ZM/scratch/p8/src-$S" --tag "$S" --secs "$SOAK" --kill-at "$KILL_AT" > "$ZM/scratch/p8/soak_$S.out" 2>&1
/usr/bin/python3 -I -c 'import json,sys;sys.exit(0 if json.load(open(sys.argv[1]))["pass"] else 1)' "$ZM/receipts/phase8/soak_$S.json" || red "soak / leak gate (receipts/phase8/soak_$S.json)"
G=("receipts/phase8/shadow_bench_$S.json" "receipts/phase8/safety_$S.json" "receipts/phase8/soak_$S.json")
say "stamp"; "$ZM/deploy/build_release.sh" stamp "$CAND" "${G[@]}" --seed "$SEED" > /dev/null || red "stamp"
say "round trip (with seed)"; /usr/bin/python3 -I "$ZM/tests/phase8/roundtrip.py" --release "$CAND" --tag "$S" --with-seed --required-kinds shadow_bench_,safety_,soak_ > "$ZM/scratch/p8/roundtrip_$S.log" 2>&1 || red "round trip (scratch/p8/roundtrip_$S.log)"
"$ZM/deploy/build_release.sh" stamp "$CAND" "${G[@]}" "receipts/phase8/roundtrip_$S.json" --seed "$SEED" > /dev/null || red "final stamp"
[ -e "$ZM/deploy/release" ] && mv "$ZM/deploy/release" "$ZM/deploy/release.prev-$(date +%Y%m%d-%H%M%S)"
cp -a "$CAND" "$ZM/deploy/release.tmp" && mv "$ZM/deploy/release.tmp" "$ZM/deploy/release" || red "install release"
Q=$(/usr/bin/python3 -I -c 'import json,sys
q=json.load(open(sys.argv[1])).get("quality",{})
print("; ".join(v["score"] + (" green" if all(v["gates"].values()) else " RED") for v in q.values()) or "n/a")' "$ZM/deploy/release/RELEASE.json")
say "gate 3 (quality, needed only for --wire): $Q"
say "GREEN (safety) — deploy/release = $S (binary ${BSHA:0:16}). Deploy: ~/zigmem/deploy/deploy.sh   Undo: ~/zigmem/deploy/rollback.sh"
