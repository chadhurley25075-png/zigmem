#!/usr/bin/env bash
# finish qualify 22af993: stamp (with the recorded ruling) → seeded round trip on a SCRATCH home (fake systemctl) → final stamp →
# stage as deploy/release (files only; NO real deploy, NO unit, NO service — Alex's call).
set -uo pipefail
ZM=$HOME/zigmem; S=22af993e523a; CAND=$ZM/scratch/p8/cand-$S; SEED=$ZM/scratch/p8/shadow-$S/zigmem.db; cd $ZM
export ZM_RULINGS=$ZM/deploy/rulings_$S.json
G=(receipts/phase8/shadow_bench_$S.json receipts/phase8/safety_$S.json receipts/phase8/soak_$S.json)
deploy/build_release.sh stamp $CAND "${G[@]}" --seed $SEED > scratch/p8/stamp1_$S.out 2>&1 || { echo "STAMP1 RED"; tail -5 scratch/p8/stamp1_$S.out; exit 1; }
echo "stamp1 ok"
/usr/bin/python3 -I tests/phase8/roundtrip.py --release $CAND --tag $S --with-seed --required-kinds shadow_bench_,safety_,soak_ > scratch/p8/roundtrip_$S.log 2>&1; echo "roundtrip rc=$?"
grep -E "^RED|^PASS|^FAIL|RT2 \(gate 3|WARN" scratch/p8/roundtrip_$S.log | cut -c1-260
deploy/build_release.sh stamp $CAND "${G[@]}" receipts/phase8/roundtrip_$S.json --seed $SEED > scratch/p8/stamp2_$S.out 2>&1 || { echo "STAMP2 RED"; tail -5 scratch/p8/stamp2_$S.out; exit 1; }
echo "stamp2 ok"
[ -e deploy/release ] && mv deploy/release deploy/release.prev-$(date +%Y%m%d-%H%M%S)
cp -a $CAND deploy/release.tmp && mv deploy/release.tmp deploy/release
/usr/bin/python3 -I -c 'import json;r=json.load(open("deploy/release/RELEASE.json"));print({k:r[k] for k in ("sha256","commit","tested_sha256","gates","quality","seed_sha256")}); print("rulings:", [x["receipt"] for x in r["rulings"]])'
