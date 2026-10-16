#!/usr/bin/env bash
# Build the zigmem release binary from a COMMITTED tree (git archive of COMMIT, never the working tree), -Drelease.
#   deploy/build_release.sh build [COMMIT] [--target x86_64-linux-gnu] [--out DIR]
#        → DIR/zigmem + DIR/zigmem-recall + DIR/RELEASE.json (sha256, commit, build_cmd, optimize, target, zig version)
#   [ZM_RULINGS=rulings.json] deploy/build_release.sh stamp DIR GATE_RECEIPT... [--seed DB]   (rulings: recorded supervisor rulings,
#        each naming receipt + safety key + the exact leak items; a red key passes only when its items match exactly)
#        → after the phase-8 gates ran on DIR/zigmem: tested_sha256 = its sha, gates = receipt paths (relative to ~/zigmem;
#          every SAFETY gate must be green; gate 3 quality is recorded, not required — deploy.sh --wire requires it),
#          seed_db + seed_sha256 (the shadow import deploy.sh copies). deploy.sh refuses unless all of it checks out.
set -euo pipefail
ZM="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ZIG="${ZIG:-$HOME/tools/zig-linux/zig}"
cmd="${1:-}"; shift || true
if [ "$cmd" = build ]; then
  COMMIT="HEAD"; TARGET=""; OUT="$ZM/deploy/release"
  while [ $# -gt 0 ]; do case "$1" in --target) TARGET="$2"; shift ;; --out) OUT="$2"; shift ;; *) COMMIT="$1" ;; esac; shift; done
  SHA=$(git -C "$ZM" rev-parse --verify "$COMMIT^{commit}")
  SRC="$ZM/scratch/p8/src-${SHA:0:12}"
  if [ ! -d "$SRC" ]; then mkdir -p "$SRC.tmp"; git -C "$ZM" archive "$SHA" | tar -x -C "$SRC.tmp"; mv "$SRC.tmp" "$SRC"; fi
  BUILD="$ZM/scratch/p8/build-${SHA:0:12}${TARGET:+-$TARGET}"
  ARGS=(build install phase3 storebench -Drelease --prefix "$BUILD"); [ -n "$TARGET" ] && ARGS+=("-Dtarget=$TARGET")
  ( cd "$SRC" && "$ZIG" "${ARGS[@]}" )
  mkdir -p "$OUT"
  install -m 755 "$BUILD/bin/zigmem" "$OUT/zigmem"; for x in zigmem-recall zigmem-storebench; do [ -f "$BUILD/bin/$x" ] && install -m 755 "$BUILD/bin/$x" "$OUT/$x"; done
  /usr/bin/python3 -I - "$OUT" "$SHA" "zig ${ARGS[*]}" "${TARGET:-native}" "$("$ZIG" version)" <<'PY'
import hashlib, json, os, sys, datetime
out, commit, cmd, target, zv = sys.argv[1:6]
h = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
rel = {"sha256": h(f"{out}/zigmem"), "commit": commit, "build_cmd": cmd, "optimize": "ReleaseSafe", "target": target, "zig": zv,
       "built": datetime.datetime.now().astimezone().isoformat(timespec="seconds"), "tested_sha256": None, "gates": [], "seed_db": None, "seed_sha256": None}
if os.path.isfile(f"{out}/zigmem-recall"): rel["recall_sha256"] = h(f"{out}/zigmem-recall")
json.dump(rel, open(f"{out}/RELEASE.json", "w"), indent=1)
print(json.dumps(rel, indent=1))
PY
elif [ "$cmd" = stamp ]; then
  OUT="$1"; shift; SEED=""; GATES=()
  while [ $# -gt 0 ]; do case "$1" in --seed) SEED="$2"; shift ;; *) GATES+=("$1") ;; esac; shift; done
  /usr/bin/python3 -I - "$OUT" "$ZM" "$SEED" "${GATES[@]}" <<'PY'
import hashlib, json, os, sys
out, zm, seed, gates = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
def h(p):
    d = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""): d.update(b)
    return d.hexdigest()
rel = json.load(open(f"{out}/RELEASE.json"))
sha = h(f"{out}/zigmem"); assert sha == rel["sha256"], "binary changed since build"
import importlib.util
spec = importlib.util.spec_from_file_location("zm_kit", os.path.join(zm, "deploy", "zm_kit.py")); K = importlib.util.module_from_spec(spec); spec.loader.exec_module(K)
quality = {}
rulings = json.load(open(os.environ["ZM_RULINGS"])) if os.environ.get("ZM_RULINGS") else rel.get("rulings", [])
for g in gates:
    r = json.load(open(os.path.join(zm, g)))
    safe, safety, q = K.split_gates(r)
    reds = [k for k, v in safety.items() if not v]
    assert safe or all(K.ruled(r, g, k, rulings) for k in reds), f"{g}: SAFETY gate not green {safety} and no matching ruling"
    assert r.get("binary_sha256") in (None, sha), f"{g} ran on another binary"
    if q: quality[g] = {"gates": q, "score": K.gap_text(r)}
rel["tested_sha256"], rel["gates"], rel["quality"], rel["rulings"] = sha, gates, quality, rulings
if seed:
    rel["seed_db"], rel["seed_sha256"] = seed, h(os.path.expanduser(seed))
json.dump(rel, open(f"{out}/RELEASE.json", "w"), indent=1)
print(json.dumps(rel, indent=1))
PY
else sed -n '2,8p' "$0"; exit 64; fi
