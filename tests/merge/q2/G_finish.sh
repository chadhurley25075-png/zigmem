#!/usr/bin/env bash
# Merge lane G (after the soak): stamp the CANDIDATE dir (with the recorded ruling for 5f8f13c12a4b) → seeded round trip on a
# SCRATCH home (scratch/merge/rt_home, fake systemctl, 127.0.0.1:18233) → stamp again. Does NOT stage deploy/release (that is
# done only after every gate is green and master is fast-forwarded). Production (zigmem.service :8470, ~/zigmem_data) untouched.
set -uo pipefail
ZM=$HOME/zigmem; S=5f8f13c12a4b; M=$ZM/scratch/merge; T=$M/tree; CAND=$ZM/scratch/p8/cand-$S; SEED=$ZM/scratch/p8/shadow-$S/zigmem.db; cd $ZM
export ZM_RULINGS=$ZM/deploy/rulings_$S.json
G=(receipts/phase8/shadow_bench_$S.json receipts/phase8/safety_$S.json receipts/phase8/soak_$S.json)
deploy/build_release.sh stamp $CAND "${G[@]}" --seed $SEED > $M/logs2/stamp1_$S.out 2>&1 || { echo "STAMP1 RED"; tail -5 $M/logs2/stamp1_$S.out; exit 1; }
echo "stamp1 ok"
ZIGMEM_RT_HOME=$M/rt_home2 ZIGMEM_RT_RELDIR=$M/rt_rel2 /usr/bin/python3 -I $T/tests/phase8/roundtrip.py --release $CAND --tag $S --port 18233 --with-seed --required-kinds shadow_bench_,safety_,soak_ > $M/logs2/roundtrip_$S.log 2>&1; echo "roundtrip rc=$?"
grep -E "^RED|^PASS|^FAIL|RT2 \(gate 3|WARN" $M/logs2/roundtrip_$S.log | cut -c1-260
deploy/build_release.sh stamp $CAND "${G[@]}" receipts/phase8/roundtrip_$S.json --seed $SEED > $M/logs2/stamp2_$S.out 2>&1 || { echo "STAMP2 RED"; tail -5 $M/logs2/stamp2_$S.out; exit 1; }
echo "stamp2 ok"
echo "production after: $(systemctl --user show zigmem.service -p MainPID -p ActiveState | tr "\n" " ") listen8420=$(ss -Hltn "sport = :8470" | awk "{print \$4}")"
echo G_DONE
