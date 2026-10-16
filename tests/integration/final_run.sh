#!/bin/bash
# INTEGRATION: every gate on ONE binary set, built once with -Drelease. Log: receipts/integration/final_run.log
set -u
T=~/zigmem/scratch/integ/tree
R=~/zigmem/receipts/integration
cd $T
Z=~/tools/zig-linux/zig
PY=python3
rm -rf out
$Z build -Drelease install phase3 household-gate hh-fixture storebench --prefix out || exit 9
echo "== binary"; sha256sum out/bin/*
echo "== unit"; $Z build -Drelease test test-store test-extract test-phase3 test-api test-household test-panel --summary all 2>&1 | grep -E "tests passed|failed|error" | head -5
export ZIGMEM_STOREBENCH=$T/out/bin/zigmem-storebench
for g in auth bind fuzz latency crash extract; do timeout 1800 python3 tests/integration/p4_gates.py $g > $R/p4/$g.log 2>&1; echo "== p4 $g rc=$?"; done
timeout 3000 $PY tests/integration/p5_api_gate.py > $R/p5/gate.log 2>&1; echo "== p5 api rc=$?"
rm -f ~/zigmem/scratch/integ/p5inproc/final.db*; out/bin/zigmem-household-gate --db ~/zigmem/scratch/integ/p5inproc/final.db > $R/p5/inprocess_gate.json; echo "== p5 in-process rc=$?"
timeout 1800 $PY tests/integration/p6_panel.py all --bin $T/out/bin/zigmem --tag panel > $R/p6/panel.log 2>&1; echo "== p6 panel rc=$?"
timeout 3000 $PY tests/integration/p7_adapters.py > $R/p7/gate.log 2>&1; echo "== p7 adapters rc=$?"
timeout 600 python3 tests/integration/proxy_probe.py > $R/p7/proxy_probe.log 2>&1; echo "== proxy probe rc=$?"
bash tests/integration/p3diff.sh > $R/p3diff/run.log 2>&1; echo "== p3 diff done"
$PY tests/integration/bench_api.py --fresh --lanes zigmem-api,zigmem-cli,live-local --par 1 --tag final_leash8s > $R/bench/final_leash8s.log 2>&1; echo "== bench 8s rc=$?"
$PY tests/integration/bench_api.py --lanes zigmem-api --par 1 --tag final_leash3s --serve-args "--rerank http://127.0.0.1:18098/rerank" > $R/bench/final_leash3s.log 2>&1; echo "== bench 3s rc=$?"
$PY tests/integration/bench_api.py --lanes zigmem-api --par 4 --tag final_leash3s_par4 --serve-args "--rerank http://127.0.0.1:18098/rerank" > $R/bench/final_leash3s_par4.log 2>&1; echo "== bench 3s par4 rc=$?"
$PY tests/integration/bench_api.py --lanes zigmem-api --par 4 --tag final_leash8s_par4 > $R/bench/final_leash8s_par4.log 2>&1; echo "== bench 8s par4 rc=$?"
echo "== listeners after"; ss -Hltn | grep -E ":(181[89][0-9]) " || echo none
echo FINAL_DONE
