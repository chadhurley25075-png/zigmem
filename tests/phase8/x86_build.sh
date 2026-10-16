#!/usr/bin/env bash
# Phase-8 x86_64 build for the x86 box, cross-compiled on the dev box from a COMMITTED tree (git archive), -Drelease.
#   x86_build.sh COMMIT   → scratch/p8/x86-<sha12>/{bin/, tests/<step>.test, tests.list, src.tar}
# Test executables are built by `zig build <test steps> -Dtarget=x86_64-linux-gnu`; zig cannot run them here (foreign arch),
# so the run steps fail with "unable to spawn foreign binary" and we collect exactly those binaries (step name → path).
set -uo pipefail
ZM="$HOME/zigmem"; ZIG="$HOME/tools/zig-linux/zig"
SHA=$(git -C "$ZM" rev-parse --verify "${1:-HEAD}^{commit}") || exit 1
SRC="$ZM/scratch/p8/src-${SHA:0:12}"; OUT="$ZM/scratch/p8/x86-${SHA:0:12}"
[ -d "$SRC" ] || { mkdir -p "$SRC.tmp" && git -C "$ZM" archive "$SHA" | tar -x -C "$SRC.tmp" && mv "$SRC.tmp" "$SRC"; }
mkdir -p "$OUT/tests"
cd "$SRC"
"$ZIG" build install phase3 -Drelease -Dtarget=x86_64-linux-gnu --prefix "$OUT" > "$OUT/build.log" 2>&1 || { echo "x86 build FAILED"; tail -20 "$OUT/build.log"; exit 1; }
STEPS=$("$ZIG" build -l 2>/dev/null | awk '{print $1}' | grep -E '^test' | tr '\n' ' ')
echo "$STEPS" > "$OUT/steps"
"$ZIG" build $STEPS -Drelease -Dtarget=x86_64-linux-gnu > "$OUT/test_build.log" 2>&1
: > "$OUT/tests.list"
# pair each "<step>\n+- run test ..." block with its "failed command: ./.zig-cache/o/<h>/test" line
/usr/bin/python3 -I - "$OUT" "$SRC" <<'PY'
import os, re, shutil, sys
out, src = sys.argv[1], sys.argv[2]
log = open(f"{out}/test_build.log").read().splitlines()
step, n = None, 0
with open(f"{out}/tests.list", "w") as L:
    for i, l in enumerate(log):
        if re.match(r"^test[\w-]*$", l.strip()) and i + 1 < len(log) and log[i + 1].startswith("+- run test"):
            step = l.strip()
        m = re.match(r"failed command: (\./\.zig-cache/o/\w+/test) ", l)
        if m and step:
            n += 1
            dst = f"{out}/tests/{step}-{n}.test"
            shutil.copy(os.path.join(src, m.group(1)), dst)
            L.write(f"{step}\t{os.path.basename(dst)}\n")
print(f"collected {n} test binaries")
PY
tar -C "$SRC" -cf "$OUT/src.tar" --exclude .zig-cache --exclude zig-out .
file "$OUT"/bin/* "$OUT"/tests/* | sed "s#$OUT/##" | cut -c1-110
