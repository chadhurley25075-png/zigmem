#!/usr/bin/env bash
# Prove zigmem_doctor.sh: GREEN on a healthy test hub, and the right FAIL line on 3 broken cases. Synthetic rows only.
# Test port 18163 (127.0.0.1). Every server is started by hand and stopped by its exact PID, verified gone.
#   bash tests/hardening/doctor_test.sh BIN OUT_DIR
set -u
BIN="$1"; OUT="$2"; ZM="$HOME/zigmem"; D="$ZM/scratch/hardening/doc"; PORT=18163
DOC="$ZM/tests/hardening/zigmem_doctor.sh"; PY="/usr/bin/python3 -I"
mkdir -p "$OUT"; [ -e "$D" ] && { echo "scratch $D exists — refusing"; exit 2; }
mkdir -p "$D/home"; H="$D/home"
if "$BIN" 2>&1 | grep -q "household bootstrap"; then   # integration binary (8f82fc9+): seats must be bound to a household
  printf '%s' '{"members":[{"id":"syna","display":"Syn A","role":"principal","relation":"father"}],"seats":[{"name":"syndoc","member":"syna"}]}' > "$H/hh.json"
  "$BIN" household bootstrap --home "$H" --file "$H/hh.json" > /dev/null
  TOK=$("$BIN" token add --seat syndoc --scopes '*' --writes --trusted --home "$H"); SCOPE=""
else
  TOK=$("$BIN" token add --seat syndoc --scopes syn-doc --writes --home "$H"); SCOPE=',"scope":"syn-doc"'
fi
PASS=0; TOTAL=0
start() { setsid "$BIN" serve --home "$1" --port $PORT --bind 127.0.0.1 --extract none > "$1/serve.log" 2>&1 < /dev/null & SP=$!
  for _ in $(seq 1 100); do curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/health" && return 0; kill -0 $SP 2>/dev/null || return 1; sleep 0.1; done; return 1; }
stop() { kill -TERM "$SP" 2>/dev/null; for _ in $(seq 1 100); do kill -0 "$SP" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$SP" 2>/dev/null && echo "WARNING pid $SP still alive"; ss -ltnH | grep -q ":$PORT " && echo "WARNING :$PORT still listening"; return 0; }
expect() { # name expected_rc grep_regex_that_must_match...
  local name="$1" want="$2"; shift 2; TOTAL=$((TOTAL+1))
  local ok=1; [ "$RC" = "$want" ] || ok=0
  for re in "$@"; do grep -qE "$re" "$OUT/doctor_$name.txt" || ok=0; done
  if [ $ok = 1 ]; then PASS=$((PASS+1)); echo "GREEN $name (rc=$RC)"; else echo "RED   $name (rc=$RC, want $want; patterns: $*)"; fi; }

# ---- seed + GREEN ----
start "$H" || { echo "hub did not start"; exit 1; }
for i in $(seq 1 50); do curl -s -m 5 -o /dev/null -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d "{\"user_content\":\"syn widget row $i kalo vendra\",\"session_key\":\"d$i\"$SCOPE}" "http://127.0.0.1:$PORT/v1/capture"; done
L0=$(curl -s -m 5 "http://127.0.0.1:$PORT/health" | $PY -c 'import json,sys; print(json.load(sys.stdin)["rows"]["l0"])')
echo "seeded l0 rows: $L0 (want 50)"; [ "$L0" = 50 ] || { echo "RED seeding failed — the corrupt case would test an empty table"; stop; exit 1; }
SHA=$(sha256sum "$BIN" | cut -d' ' -f1)
$PY -c 'import json,sys; json.dump({"port": int(sys.argv[1]), "bin_sha256": sys.argv[2], "data": sys.argv[3], "note": "TEST manifest for doctor_test.sh, not a deploy"}, open(sys.argv[4], "w"))' $PORT "$SHA" "$H" "$D/manifest.json"
bash "$DOC" --port $PORT --manifest "$D/manifest.json" > "$OUT/doctor_green.txt" 2>&1; RC=$?
expect green 0 '^OK health' '^OK bind' '^OK db: quick_check ok' '^OK disk' '^OK binary' '^OK rss'
! grep -qE '^(WARN|FAIL)' "$OUT/doctor_green.txt" || { echo "  (green run printed a WARN/FAIL line)"; PASS=$((PASS-1)); }
# a manifest that names another sha must FAIL the binary line (negative control of the sha check)
$PY -c 'import json,sys; m=json.load(open(sys.argv[1])); m["bin_sha256"]="0"*64; json.dump(m, open(sys.argv[2],"w"))' "$D/manifest.json" "$D/manifest_wrong.json"
bash "$DOC" --port $PORT --manifest "$D/manifest_wrong.json" > "$OUT/doctor_wrongsha.txt" 2>&1; RC=$?
expect wrongsha 1 '^FAIL binary: running .* != deploy manifest' '^OK health'

# ---- BROKEN 2: 0.0.0.0 bind ----
# (live) zigmem refuses 0.0.0.0 itself → record it
"$BIN" serve --home "$H" --port 18164 --bind 0.0.0.0 --extract none > "$OUT/zigmem_refuses_0000.txt" 2>&1; echo "rc=$?" >> "$OUT/zigmem_refuses_0000.txt"
ss -ltnH | grep -q ':18164 ' && echo "listening on 18164 after refusal!" >> "$OUT/zigmem_refuses_0000.txt"
# (recorded) the live ss line of the running test hub, with its address rewritten to 0.0.0.0
ss -ltnpH | awk -v p=":$PORT" 'substr($4, length($4)-length(p)+1)==p' | sed "s/127\.0\.0\.1:$PORT/0.0.0.0:$PORT/" > "$D/ss_0000.txt"
cp "$D/ss_0000.txt" "$OUT/ss_0000_injected.txt"
ZIGMEM_DOCTOR_SS_FILE="$D/ss_0000.txt" bash "$DOC" --port $PORT --manifest "$D/manifest.json" > "$OUT/doctor_bind0000.txt" 2>&1; RC=$?
expect bind0000 1 "^FAIL bind: NOT loopback-only: 0\.0\.0\.0:$PORT"

# ---- BROKEN 1: stopped ----
stop
bash "$DOC" --port $PORT --manifest "$D/manifest.json" > "$OUT/doctor_stopped.txt" 2>&1; RC=$?
expect stopped 1 '^FAIL health' "^FAIL bind: nothing is listening on port $PORT"

# ---- BROKEN 3: corrupted DB copy ----
mkdir -p "$D/corrupt"; cp -p "$H/zigmem.db" "$H/zigmem.db-wal" "$H/tokens" "$D/corrupt/" 2>/dev/null
$PY - "$D/corrupt/zigmem.db" > "$OUT/corrupt_how.txt" <<'PY'
import os, sqlite3, sys
db = sys.argv[1]
con = sqlite3.connect(db); con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
ps = con.execute("PRAGMA page_size").fetchone()[0]; n = con.execute("PRAGMA page_count").fetchone()[0]
roots = dict(con.execute("SELECT name, rootpage FROM sqlite_master WHERE name IN ('l0','atoms') OR name LIKE 'sqlite_autoindex_l0%'"))
con.close()
pg = roots.get("l0")
with open(db, "r+b") as f:
    f.seek((pg - 1) * ps + 8); f.write(os.urandom(ps // 2))     # garbage over the l0 b-tree root page body (header kept)
print(f"page_size={ps} pages={n} corrupted l0 root page {pg} (bytes 8..{8 + ps // 2}); roots={roots}")
PY
if start "$D/corrupt"; then STARTED=yes; else STARTED=no; fi
echo "corrupt copy: zigmem serve started=$STARTED" >> "$OUT/corrupt_how.txt"
bash "$DOC" --port $PORT --data "$D/corrupt" --manifest "$D/manifest.json" > "$OUT/doctor_corrupt.txt" 2>&1; RC=$?
expect corrupt 1 '^FAIL db: quick_check'
[ "$STARTED" = yes ] && stop || { kill -0 "$SP" 2>/dev/null && stop; }

ss -ltnH | grep -qE ':(18163|18164) ' && LEFT=yes || LEFT=no
echo "SUMMARY doctor_test: $PASS/$TOTAL green; anything left listening on 18163/18164: $LEFT"
[ "$PASS" = "$TOTAL" ] && [ "$LEFT" = no ]
