#!/usr/bin/env bash
# qualify 22af993 stopped RED at the shadow-bench leak check (seat item 160: ledger keyword "oct 1" matched "Oct 12").
# That needs a ruling; meanwhile run the REMAINING gates on the same candidate so only stamp + round trip are left. No stamping here.
set -uo pipefail
ZM=$HOME/zigmem; S=22af993e523a; CAND=$ZM/scratch/p8/cand-$S; PY=python3; LOG=$ZM/scratch/p8/qualify_$S.log
say() { echo "$(date '+%F %T') continue $S: $* [load $(cut -d' ' -f1-3 /proc/loadavg)]" | tee -a "$LOG"; }
say "safety gates (auth, bind, fuzz, latency, kill -9)"
$PY $ZM/tests/phase8/p4_safety.py --rel $CAND --tag $S > $ZM/scratch/p8/safety_$S.out 2>&1; say "safety rc=$?"
say "soak 10800 s, kill -9 at 1800 s"
$PY $ZM/tests/phase8/soak.py --bin $CAND/zigmem --home $ZM/scratch/p8/soak-$S --src $ZM/scratch/p8/src-$S --tag $S --secs 10800 --kill-at 1800 > $ZM/scratch/p8/soak_$S.out 2>&1
say "soak rc=$? — stopped before stamp (needs the leak-metric ruling)"
