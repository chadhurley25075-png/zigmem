#!/usr/bin/env bash
set -uo pipefail
ZM=$HOME/zigmem; S=5f8f13c12a4b; M=$ZM/scratch/merge
say() { echo "$(date "+%F %T") C $S: $* [load $(cut -d" " -f1-3 /proc/loadavg)]" | tee -a $M/logs2/lane.log; }
say "shadow import (fresh, this commit loader)"
bash $ZM/tests/phase8/shadow_import.sh $ZM/scratch/p8/shadow-$S $ZM/scratch/p8/cand-$S/zigmem-recall > $ZM/scratch/p8/shadow_import_$S.out 2>&1; say "import rc=$? $(cat $ZM/scratch/p8/shadow-$S/load.json 2>/dev/null | head -c 300)"
echo C_DONE
