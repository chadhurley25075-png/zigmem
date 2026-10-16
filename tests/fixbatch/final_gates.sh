#!/bin/bash
# Fix batch: the integration gates on the branch binary (built once from the branch commit into ../out-final).
# Receipts → receipts/fixbatch/final/*; scratch → ../run/final. Ports: auth 18180, p5 18190, proxy probe 18187-18189.
set -u
T=$(cd "$(dirname "$0")/../.." && pwd); cd "$T"
FB=$(cd "$T/.." && pwd); B=$FB/out-final/bin; R=$T/receipts/fixbatch/final; S=$FB/run/final; mkdir -p $R $S
PY=python3
echo "== binary $(sha256sum $B/zigmem | cut -c1-64) load $(cut -d' ' -f1-3 /proc/loadavg)"
ZIGMEM_BIN=$B/zigmem ZIGMEM_SCR=$S/p4 ZIGMEM_REC=$R/p4 timeout 1800 python3 tests/integration/p4_gates.py auth > $R/auth.log 2>&1; echo "== p4 auth rc=$? $(grep -E '^AUTH' $R/auth.log)"
ZIGMEM_BINDIR=$B ZIGMEM_SCR=$S/p5 ZIGMEM_REC=$R/p5 timeout 3000 $PY tests/integration/p5_api_gate.py > $R/p5_api.log 2>&1; echo "== p5 api rc=$? $(tail -1 $R/p5_api.log)"
mkdir -p $S/p5inproc; $B/zigmem-household-gate --db $S/p5inproc/final.db > $R/p5_inprocess_gate.json; echo "== p5 in-process rc=$?"
ZIGMEM_MUT_TREE=$T ZIGMEM_MUT_DIR=$S/mut ZIGMEM_MUT_OUT=$R/mutations.json ZIGMEM_MUT_NICE=1 ZIGMEM_STOREBENCH=$B/zigmem-storebench \
  timeout 7200 $PY tests/integration/mutate.py > $R/mutate.log 2>&1; echo "== mutants rc=$? caught $(grep -c CAUGHT $R/mutate.log)/9"
echo "== listeners after"; ss -Hltn | grep -E ":(1818[0-9]|18190) " || echo none
echo FINAL_DONE
