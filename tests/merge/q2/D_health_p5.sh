#!/usr/bin/env bash
# Merge lane D: /health honesty (healthy 200, corrupt copy 503, doctor rc 1) on the CANDIDATE binary; p5 API + in-process on
# the lane build of the same commit. Ports 18230 (health), 18229 (p5). Synthetic data only. Servers stopped by exact PID.
set -u
ZM=$HOME/zigmem; S=5f8f13c12a4b; M=$ZM/scratch/merge; T=$M/tree; R=$ZM/receipts/merge2; B=$M/out2/bin; PY=python3
say() { echo "$(date "+%F %T") D $S: $* [load $(cut -d" " -f1-3 /proc/loadavg)]" | tee -a $M/logs2/lane.log; }
cd $T
say "health_test on candidate $(sha256sum $ZM/scratch/p8/cand-$S/zigmem | cut -c1-16)"
ZIGMEM_HEALTH_PORT=18230 bash tests/fixbatch/health_test.sh $ZM/scratch/p8/cand-$S/zigmem $R/health $M/run2/health fixed > $R/health.log 2>&1; say "health rc=$? $(tail -1 $R/health.log)"
say "p5 api (lane build $(sha256sum $B/zigmem | cut -c1-16))"
ZIGMEM_PORT=18229 ZIGMEM_BINDIR=$B ZIGMEM_BIN=$B/zigmem ZIGMEM_SCR=$M/run2/p5 ZIGMEM_REC=$R/p5 timeout 3000 $PY tests/integration/p5_api_gate.py > $R/p5_api.log 2>&1; say "p5 api rc=$? $(tail -1 $R/p5_api.log)"
mkdir -p $M/run2/p5inproc; $B/zigmem-household-gate --db $M/run2/p5inproc/final.db > $R/p5_inprocess_gate.json; say "p5 in-process rc=$? $(head -c 300 $R/p5_inprocess_gate.json)"
echo "listeners 18220-18239 after: $(ss -Hltn | awk "{print \$4}" | grep -E ":182[23][0-9]$" | tr "\n" " ")"
echo D_DONE
