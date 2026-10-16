#!/usr/bin/env bash
# Start the release hub on a bench home (127.0.0.1:PORT), run shadow_bench.py, stop the hub by PID, verify nothing listens.
#   run_shadow_bench.sh RELDIR HOME TAG [PORT]
set -uo pipefail
REL="$1"; H="$2"; TAG="$3"; PORT="${4:-18191}"; ZM="$HOME/zigmem"
SHA=$(sha256sum "$REL/zigmem" | cut -d' ' -f1)
"$REL/zigmem" serve --home "$H" --port "$PORT" --bind 127.0.0.1 --extract none > "$H/serve.log" 2>&1 &
PID=$!; echo "hub pid $PID"
for i in $(seq 1 1500); do curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/health" && break; kill -0 $PID 2>/dev/null || { echo "hub died"; break; }; sleep 0.2; done   # vector index loads first
curl -s -m 3 "http://127.0.0.1:$PORT/health"; echo
"python3" "$ZM/tests/phase8/shadow_bench.py" --url "http://127.0.0.1:$PORT" --token-file "$H/shadow.token" \
   --bin-sha "$SHA" --tag "$TAG" --lanes zigmem,zigcli,live --recall-bin "$REL/zigmem-recall" --recall-db "$H/zigmem.db" 2>&1 | grep -v -i warn
kill -TERM "$PID"; for i in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
kill -0 "$PID" 2>/dev/null && echo "hub STILL RUNNING $PID" || echo "hub stopped pid $PID"
echo "listening on $PORT after: '$(ss -Hltn "sport = :$PORT" | awk '{print $4}')'"
