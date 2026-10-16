#!/usr/bin/env bash
# zigmem_doctor.sh — READ-ONLY health check for a running zigmem hub (hardening item 2; a future `the fleet health check` may call it —
# NOT wired anywhere; wiring is Alex's call). Changes nothing: no writes to the DB, no restarts, no signals.
#   zigmem_doctor.sh [--port 8470] [--data DIR] [--manifest FILE] [--src ZIGMEM_TREE]
# One line per check: "OK|WARN|FAIL <check>: detail". Exit 1 if any FAIL, else 0.
# Where things come from (nothing about the deploy is hardcoded):
#   data dir  : --data, else the running process's `--home`, else the deploy manifest's "data"
#   binary sha: deploy manifest (~/.local/state/zigmem-deploy/manifest.json, written by deploy/deploy.sh) "bin_sha256";
#               no manifest → compared to <src>/deploy/release/RELEASE.json "sha256" as a WARN-level hint
#   RSS ceiling: the qualify soak's pre-run receipt (<src>/receipts/phase8/soak_*.pre.json) for THIS binary sha; if none
#               matches, the same formula as tests/phase8/soak.py from the source settings (schema.zig cache_size +
#               mmap_size, hub.zig readers, vector index rows) with a 64 MB base, labelled "computed" in the line.
# Test hook (used by tests/hardening/doctor_test.sh only): ZIGMEM_DOCTOR_SS_FILE = a file holding `ss -ltnpH` output to
# use instead of the live socket table (zigmem itself refuses --bind 0.0.0.0, see the README).
set -u
PORT=8470; DATA=""; SRC="${ZIGMEM_SRC:-$HOME/zigmem}"; MAN="$HOME/.local/state/zigmem-deploy/manifest.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift ;; --data) DATA="$2"; shift ;; --manifest) MAN="$2"; shift ;; --src) SRC="$2"; shift ;;
    -h|--help) sed -n 2,16p "$0"; exit 0 ;; *) echo "FAIL args: unknown $1"; exit 2 ;;
  esac; shift
done
PY="/usr/bin/python3 -I"
FAILS=0
say() { echo "$1 $2: $3"; [ "$1" = FAIL ] && FAILS=$((FAILS+1)); return 0; }
jget() { $PY -c 'import json,sys
try: v=json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception: v=None
print("" if v is None else v)' "$1" "$2"; }

# ---- 1. health ----
H=$(curl -s -m 5 -o - -w '\n%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)
CODE=$(printf '%s' "$H" | tail -1); BODY=$(printf '%s' "$H" | sed '$d')
if [ "$CODE" = 200 ] && printf '%s' "$BODY" | $PY -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("ok") is True else 1)' 2>/dev/null; then
  say OK health "127.0.0.1:$PORT/health 200 ok:true ($(printf '%s' "$BODY" | $PY -c 'import json,sys; j=json.load(sys.stdin); print("v%s rows l0=%s atoms=%s" % (j.get("version"), j.get("rows",{}).get("l0"), j.get("rows",{}).get("atoms")))'))"
else
  say FAIL health "127.0.0.1:$PORT/health did not answer 200 ok:true (http ${CODE:-none})"
fi

# ---- 2. bind (loopback only) ----
if [ -n "${ZIGMEM_DOCTOR_SS_FILE:-}" ]; then SS=$(cat "$ZIGMEM_DOCTOR_SS_FILE"); else SS=$(ss -ltnpH 2>/dev/null); fi
LINES=$(printf '%s\n' "$SS" | awk -v p=":$PORT" '{ if (substr($4, length($4)-length(p)+1) == p) print }')
PID=""
if [ -z "$LINES" ]; then
  say FAIL bind "nothing is listening on port $PORT"
else
  ADDRS=$(printf '%s\n' "$LINES" | awk '{print $4}' | sort -u | tr '\n' ' ')
  BAD=$(printf '%s\n' "$LINES" | awk '{print $4}' | grep -v -E '^(127\.0\.0\.1|\[::1\]):[0-9]+$' | sort -u | tr '\n' ' ')
  PID=$(printf '%s\n' "$LINES" | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
  if [ -n "$BAD" ]; then say FAIL bind "NOT loopback-only: $BAD(every listener must be 127.0.0.1 / [::1])"
  else say OK bind "loopback only: $ADDRS(pid ${PID:-?})"; fi
fi

# ---- 3. data dir ----
if [ -z "$DATA" ] && [ -n "$PID" ] && [ -r "/proc/$PID/cmdline" ]; then
  DATA=$(tr '\0' '\n' < "/proc/$PID/cmdline" | awk 'f{print; exit} $0=="--home"{f=1}')
fi
[ -z "$DATA" ] && [ -f "$MAN" ] && DATA=$(jget "$MAN" data)
DB="$DATA/zigmem.db"

# ---- 4. DB quick_check (read-only connection) ----
if [ -z "$DATA" ] || [ ! -f "$DB" ]; then
  say FAIL db "no database found (data dir '${DATA:-unknown}')"
else
  QC=$($PY - "$DB" <<'PY' 2>&1
import sqlite3, sys
try:
    con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=10)
    rows = [r[0] for r in con.execute("PRAGMA quick_check(5)")]
    print("ok" if rows == ["ok"] else "; ".join(rows)[:300])
except Exception as e:
    print(f"error: {e}")
PY
)
  if [ "$QC" = ok ]; then say OK db "quick_check ok ($DB, $(du -h "$DB" | cut -f1))"
  else say FAIL db "quick_check: $QC ($DB)"; fi
fi

# ---- 5. disk headroom of the data dir ----
if [ -n "$DATA" ] && [ -d "$DATA" ]; then
  read -r AVAIL_K PCT <<<"$(df -Pk "$DATA" | awk 'NR==2{gsub("%","",$5); print $4, $5}')"
  GB=$((AVAIL_K / 1048576))
  if [ "$PCT" -ge 97 ] || [ "$GB" -lt 2 ]; then say FAIL disk "$DATA filesystem ${PCT}% used, ${GB} GB free"
  elif [ "$PCT" -ge 90 ] || [ "$GB" -lt 10 ]; then say WARN disk "$DATA filesystem ${PCT}% used, ${GB} GB free"
  else say OK disk "$DATA filesystem ${PCT}% used, ${GB} GB free"; fi
else
  say WARN disk "data dir unknown — headroom not checked"
fi

# ---- 6. binary sha vs deploy manifest ----
BSHA=""
if [ -n "$PID" ] && [ -r "/proc/$PID/exe" ]; then BSHA=$(sha256sum "/proc/$PID/exe" 2>/dev/null | cut -d' ' -f1); fi
if [ -z "$BSHA" ]; then
  say WARN binary "no running zigmem process found on :$PORT — sha not checked"
elif [ -f "$MAN" ] && [ "$(jget "$MAN" port)" = "$PORT" ]; then
  WANT=$(jget "$MAN" bin_sha256)
  if [ "$BSHA" = "$WANT" ]; then say OK binary "running ${BSHA:0:16}… = deploy manifest bin_sha256"
  else say FAIL binary "running ${BSHA:0:16}… != deploy manifest bin_sha256 ${WANT:0:16}… ($MAN)"; fi
else
  REL="$SRC/deploy/release/RELEASE.json"; WANT=""; [ -f "$REL" ] && WANT=$(jget "$REL" sha256)
  if [ -n "$WANT" ] && [ "$BSHA" = "$WANT" ]; then say OK binary "running ${BSHA:0:16}… = $REL (no deploy manifest for :$PORT)"
  else say WARN binary "running ${BSHA:0:16}…; no deploy manifest for :$PORT (release sha ${WANT:0:16}…)"; fi
fi

# ---- 7. RSS vs ceiling ----
if [ -n "$PID" ] && [ -r "/proc/$PID/status" ]; then
  RES=$($PY - "$PID" "$BSHA" "$SRC" "$DB" <<'PY' 2>&1
import glob, json, os, re, sqlite3, sys
pid, sha, src, db = sys.argv[1:5]
rss = int([l for l in open(f"/proc/{pid}/status") if l.startswith("VmRSS:")][0].split()[1]) / 1024
ceil = None; how = ""
for f in sorted(glob.glob(f"{src}/receipts/phase8/soak_*.pre.json")):
    try: j = json.load(open(f))
    except Exception: continue
    if sha and j.get("binary_sha256") == sha:
        ceil = j["ceiling"]["ceiling_mb"]; how = os.path.basename(f)
if ceil is None:
    try:
        sch = open(f"{src}/src/store/schema.zig").read(); hub = open(f"{src}/src/api/hub.zig").read()
        cache = abs(int(re.search(r"cache_size=(-?\d+)", sch).group(1))) * 1024
        mmap = int(re.search(r"mmap_size=(\d+)", sch).group(1))
        readers = int(re.search(r"readers:\s*usize\s*=\s*(\d+)", hub).group(1))
        idx = 0
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
            n, blen = con.execute("SELECT count(*), coalesce(max(length(emb)),0) FROM vec WHERE kind='atom'").fetchone(); idx = n * (blen + 8)
        except Exception: pass
        ceil = round((64 * 2**20 + (1 + readers) * (cache + mmap) + idx + 64 * (16 * 1024 + 512 * 1024)) / 2**20, 1)
        how = "computed from source settings (no soak pre-receipt for this sha)"
    except Exception as e:
        print(f"WARN|rss {rss:.0f} MB; ceiling unknown ({e})"); sys.exit()
lvl = "FAIL" if rss > ceil else ("WARN" if rss > 0.8 * ceil else "OK")
print(f"{lvl}|RSS {rss:.0f} MB vs ceiling {ceil:.0f} MB ({100 * rss / ceil:.0f}%; {how})")
PY
)
  say "${RES%%|*}" rss "${RES#*|}"
else
  say WARN rss "no running zigmem process on :$PORT — RSS not checked"
fi

[ "$FAILS" -gt 0 ] && exit 1
exit 0
