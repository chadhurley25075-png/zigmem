#!/bin/bash
# Re-run the phase-3 differential parity gate (a) against the INTEGRATED privacy code (regex start prefilter, ledger
# memo + ASCII prefilters, calendar/escape prefilters): same runs as phase 3, receipts → receipts/integration/p3diff/.
set -u
T=~/zigmem/scratch/integ/tree
R=~/zigmem/receipts/integration/p3diff
mkdir -p "$R" ~/zigmem/scratch/integ/p3diff
sed "s#receipts/phase3#receipts/integration/p3diff#g" ~/zigmem/tests/phase3/diff_gates.py > ~/zigmem/scratch/integ/p3diff/diff_gates_integ.py
PY=python3
G=$T/out/bin/zigmem-gate
run() { echo "== $*"; $PY ~/zigmem/scratch/integ/p3diff/diff_gates_integ.py --bin $G "$@" 2>&1 | tail -3; }
for s in 1 2 3 11 31 32; do run --ledger synthetic --seed $s --n 4000; done
run --ledger synthetic --seed 7 --n 3000
for s in 1 2 3; do run --ledger malformed --seed $s --n 4000; done
for s in 21 22 23 33; do run --ledger real --seed $s --n 5000 --extra-queries ~/zigmem/scratch/p3/eval_queries.txt; done
run --ledger synthetic --seed 11 --n 4000 --red
