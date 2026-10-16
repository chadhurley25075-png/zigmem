#!/usr/bin/env bash
# Fix batch item 3: /health must report a corrupted database. Same corruption as tests/hardening/doctor_test.sh BROKEN 3
# (garbage over the l0 b-tree root page of a COPY). Synthetic rows only. Test port 18187 (127.0.0.1); every server is
# started by hand and stopped by its exact PID, verified gone.
#   bash tests/fixbatch/health_test.sh BIN OUT_DIR SCRATCH_DIR [expect=fixed|old]
# expect=old runs the same steps on the pre-fix binary as the negative control (the old /health says 200 ok:true).
set -u
BIN="$1"; OUT="$2"; D="$3"; EXPECT="${4:-fixed}"; PORT="${ZIGMEM_HEALTH_PORT:-18187}"; PY="/usr/bin/python3 -I"
T=$(cd "$(dirname "$0")/../.." && pwd); DOC="$T/tests/hardening/zigmem_doctor.sh"
mkdir -p "$OUT"; [ -e "$D" ] && { echo "scratch $D exists — refusing"; exit 2; }
mkdir -p "$D/home"; H="$D/home"
printf '%s' '{"members":[{"id":"syna","display":"Syn A","role":"principal","relation":"father"}],"seats":[{"name":"synh","member":"syna"}]}' > "$H/hh.json"
"$BIN" household bootstrap --home "$H" --file "$H/hh.json" > /dev/null
TOK=$("$BIN" token add --seat synh --scopes '*' --writes --trusted --home "$H")
PASS=0; TOTAL=0
start() { setsid "$BIN" serve --home "$1" --port $PORT --bind 127.0.0.1 --extract none > "$1/serve.log" 2>&1 < /dev/null & SP=$!
  for _ in $(seq 1 100); do curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/health" && return 0; kill -0 $SP 2>/dev/null || return 1; sleep 0.1; done; return 1; }
stop() { kill -TERM "$SP" 2>/dev/null; for _ in $(seq 1 100); do kill -0 "$SP" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$SP" 2>/dev/null && echo "WARNING pid $SP still alive"; ss -ltnH | grep -q ":$PORT " && echo "WARNING :$PORT still listening"; return 0; }
# GET /health[?deep=1] → "<status> <body>"; plain /health waits (<=10 s) until the background check has run once
get() { local q="$1" i st; for i in $(seq 1 100); do
    st=$(curl -s -m 30 -o "$D/h.json" -w '%{http_code}' "http://127.0.0.1:$PORT/health$q")
    [ -n "$q" ] && break; grep -q '"quick_check":"pending"' "$D/h.json" || break; sleep 0.1; done
  echo "$st $(cat "$D/h.json")"; }
expect() { # name got_status want_status body_regex
  TOTAL=$((TOTAL+1)); if [ "$2" = "$3" ] && echo "$5" | grep -qE "$4"; then PASS=$((PASS+1)); echo "GREEN $1 (status $2)"; else echo "RED   $1 (status $2, want $3, re $4)"; fi; }

start "$H" || { echo "hub did not start"; exit 1; }
for i in $(seq 1 50); do curl -s -m 5 -o /dev/null -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d "{\"user_content\":\"syn widget row $i kalo vendra\",\"session_key\":\"d$i\"}" "http://127.0.0.1:$PORT/v1/capture"; done
R=$(get ""); echo "$R" > "$OUT/healthy_health.txt"; S=${R%% *}; B=${R#* }
if [ "$EXPECT" = fixed ]; then expect healthy_plain "$S" 200 '"ok":true.*"quick_check":"ok"' "$B"; else expect healthy_plain_old "$S" 200 '"ok":true' "$B"; fi
R=$(get "?deep=1"); echo "$R" > "$OUT/healthy_deep.txt"; S=${R%% *}; B=${R#* }
if [ "$EXPECT" = fixed ]; then expect healthy_deep "$S" 200 '"ok":true.*"quick_check":"ok"' "$B"; fi
stop

mkdir -p "$D/corrupt"; cp -p "$H/zigmem.db" "$H/zigmem.db-wal" "$H/tokens" "$H/household.json" "$D/corrupt/" 2>/dev/null
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
R=$(get ""); echo "$R" > "$OUT/corrupt_health.txt"; S=${R%% *}; B=${R#* }
if [ "$EXPECT" = fixed ]; then
  expect corrupt_plain "$S" 503 '"ok":false.*"quick_check":"[^o"]' "$B"
  R=$(get "?deep=1"); echo "$R" > "$OUT/corrupt_deep.txt"; S=${R%% *}; B=${R#* }
  expect corrupt_deep "$S" 503 '"ok":false' "$B"
  $PY -c 'import json,sys; m={"port": int(sys.argv[1]), "bin_sha256": sys.argv[2], "data": sys.argv[3], "note": "TEST manifest, not a deploy"}; json.dump(m, open(sys.argv[4], "w"))' $PORT "$(sha256sum "$BIN" | cut -d" " -f1)" "$D/corrupt" "$D/manifest.json"
  bash "$DOC" --port $PORT --data "$D/corrupt" --manifest "$D/manifest.json" > "$OUT/doctor_corrupt.txt" 2>&1; RC=$?
  TOTAL=$((TOTAL+1)); if [ $RC = 1 ] && grep -qE '^FAIL db: quick_check' "$OUT/doctor_corrupt.txt" && grep -qE '^FAIL health' "$OUT/doctor_corrupt.txt"; then PASS=$((PASS+1)); echo "GREEN doctor_corrupt (rc=1, FAIL db + FAIL health)"; else echo "RED   doctor_corrupt (rc=$RC; see doctor_corrupt.txt)"; fi
else
  expect corrupt_plain_old_says_ok "$S" 200 '"ok":true' "$B"   # the bug, reproduced on the old binary
fi
[ "$STARTED" = yes ] && stop || { kill -0 "$SP" 2>/dev/null && stop; }
ss -ltnH | grep -qE ":$PORT " && LEFT=yes || LEFT=no
echo "SUMMARY health_test[$EXPECT]: $PASS/$TOTAL green; left listening on $PORT: $LEFT"
[ "$PASS" = "$TOTAL" ] && [ "$LEFT" = no ]
