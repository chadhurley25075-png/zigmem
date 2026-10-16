#!/usr/bin/env bash
# Merge lane F: mutation suite (9 mutants of the merged tree, each rebuilt -Drelease -j4 nice 10) — starts after the SAFETY
# gates so the latency gate ran on a quiet box. Ports: p4 auth 18220, proxy 18226-18228, p5 18229. Mutant trees in scratch/merge/run/mut.
set -u
ZM=$HOME/zigmem; S=5f8f13c12a4b; M=$ZM/scratch/merge; T=$M/tree; R=$ZM/receipts/merge2; PY=python3
say() { echo "$(date "+%F %T") F $S: $* [load $(cut -d" " -f1-3 /proc/loadavg)]" | tee -a $M/logs2/lane.log; }
while [ ! -e $M/logs2/E_SAFETY_DONE ]; do sleep 30; done
say "mutants start"
cd $T && ZIGMEM_PORT_BASE=18220 ZIGMEM_PROXY_PORT_BASE=18226 ZIGMEM_PORT=18229 ZIGMEM_MUT_TREE=$T ZIGMEM_MUT_DIR=$M/run2/mut ZIGMEM_MUT_OUT=$R/mutations.json \
  ZIGMEM_MUT_NICE=1 ZIGMEM_STOREBENCH=$ZM/scratch/p8/cand-$S/zigmem-storebench timeout 9000 $PY tests/integration/mutate.py > $R/mutate.log 2>&1
say "mutants rc=$? caught $(grep -c CAUGHT $R/mutate.log)/9"
echo "listeners 18220-18229 after: $(ss -Hltn | awk "{print \$4}" | grep -E ":1822[0-9]$" | tr "\n" " ")"
echo F_DONE
