#!/usr/bin/env bash
# Merge lane A: candidate release build (git archive, -Drelease) + lane tool build + unit tests. No servers.
set -uo pipefail
ZM=$HOME/zigmem; M=$ZM/scratch/merge; T=$M/tree; ZIG=$HOME/tools/zig-linux/zig
SHA=$(git -C $ZM rev-parse --verify merge-20261013^{commit}); S=${SHA:0:12}; R=$ZM/receipts/merge; mkdir -p $R $M/logs
say() { echo "$(date '+%F %T') A $S: $* [load $(cut -d' ' -f1-3 /proc/loadavg)]" | tee -a $M/logs/lane.log; }
[ "$(git -C $T rev-parse HEAD)" = "$SHA" ] || { say "worktree HEAD != $SHA"; exit 1; }
say "candidate build"; $ZM/deploy/build_release.sh build $SHA --out $ZM/scratch/p8/cand-$S > $M/logs/cand_build.log 2>&1; say "candidate build rc=$?"
sha256sum $ZM/scratch/p8/cand-$S/* | tee $R/candidate_sha256.txt
say "lane tools build (worktree = $SHA, -Drelease)"
( cd $T && $ZIG build -Drelease install phase3 storebench extractgate household-gate hh-fixture --prefix $M/out ) > $M/logs/tools_build.log 2>&1; say "tools rc=$?"
sha256sum $M/out/bin/* | tee $R/tools_sha256.txt
say "unit tests"
( cd $T && $ZIG build -Drelease test test-store test-extract test-phase3 test-api test-household test-panel --summary all ) > $R/unit.txt 2>&1; RC=$?
say "unit rc=$RC $(grep -E 'Build Summary' $R/unit.txt)"
echo A_DONE
