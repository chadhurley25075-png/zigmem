#!/usr/bin/env bash
# Merge lane E (after the shadow import): homes → shadow bench (hub 127.0.0.1:18231) + seat rescore → SAFETY p4 gates on the
# candidate (ports 18220-18225) → 3 h soak, kill -9 at 30 min (127.0.0.1:18232). Same scripts/order as deploy/qualify.sh steps
# 3-6, but it does NOT stop at a RED (the lane reports every gate); nothing is stamped or installed here.
set -uo pipefail
ZM=$HOME/zigmem; S=5f8f13c12a4b; M=$ZM/scratch/merge; T=$M/tree; CAND=$ZM/scratch/p8/cand-$S; PY=python3
SEED=$ZM/scratch/p8/shadow-$S/zigmem.db
say() { echo "$(date "+%F %T") E $S: $* [load $(cut -d" " -f1-3 /proc/loadavg)]" | tee -a $M/logs2/lane.log; }
while ! grep -q C_DONE $M/logs2/C.out 2>/dev/null; do sleep 30; done
[ -s $ZM/scratch/p8/shadow-$S/finished ] || { say "import did not finish — stop"; exit 1; }
say "homes"; bash $ZM/tests/phase8/prep_homes.sh $CAND/zigmem $S $SEED > $ZM/scratch/p8/prep_$S.out 2>&1; say "homes rc=$?"
say "shadow bench (hub :18231)"; bash $T/tests/phase8/run_shadow_bench.sh $CAND $ZM/scratch/p8/bench-$S $S 18231 > $ZM/scratch/p8/bench_$S.out 2>&1
say "bench done: $(grep -E "hub stopped|STILL|listening on" $ZM/scratch/p8/bench_$S.out | tr "\n" " ")"
$PY $T/tests/phase8/rescore_seat.py $S >> $M/logs2/rescore_$S.log 2>&1; say "rescore rc=$?"
/usr/bin/python3 -I -c "import importlib.util,json,sys;s=importlib.util.spec_from_file_location(\"k\",sys.argv[2]);K=importlib.util.module_from_spec(s);s.loader.exec_module(K);r=json.load(open(sys.argv[1]));ok,sf,q=K.split_gates(r);print(\"SAFE\",ok,\"safety\",sf,\"quality\",q,K.gap_text(r))" $ZM/receipts/phase8/shadow_bench_$S.json $T/deploy/zm_kit.py 2>&1 | tee -a $M/logs2/lane.log
say "safety p4 (auth,bind,fuzz,latency,crash) on $(sha256sum $CAND/zigmem | cut -c1-16)"
ZIGMEM_PORT_BASE=18220 ZIGMEM_P8_SCRATCH=$M/run2/p8 $PY $T/tests/phase8/p4_safety.py --rel $CAND --tag $S > $M/logs2/safety_$S.out 2>&1; say "safety rc=$? $(grep ^GATE $M/logs2/safety_$S.out | cut -c1-40 | tr "\n" " ")"
touch $M/logs2/E_SAFETY_DONE
say "soak 10800 s, kill -9 at 1800 s (:18232)"
$PY $T/tests/phase8/soak.py --bin $CAND/zigmem --home $ZM/scratch/p8/soak-$S --src $ZM/scratch/p8/src-$S --tag $S --port 18232 --secs 10800 --kill-at 1800 > $M/logs2/soak_$S.out 2>&1
say "soak rc=$? pass=$(/usr/bin/python3 -I -c "import json,sys;print(json.load(open(sys.argv[1]))[\"pass\"])" $ZM/receipts/phase8/soak_$S.json)"
echo E_DONE
