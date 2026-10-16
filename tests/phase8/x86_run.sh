#!/usr/bin/env bash
# Runs ON the x86 box (x86_64): unit-test executables from ~/zigmem_x86/tests (cwd = the matching source tree so relative test
# data resolves), then a 127.0.0.1 smoke of `zigmem serve` on port 18199 with a synthetic seat, then stops it by PID.
set -uo pipefail
SP="${ZIGMEM_SMOKE_PORT:-18199}"; RP="${ZIGMEM_REFUSE_PORT:-18198}"   # merge lane 10/13: overrides; defaults unchanged
B="${1:-$HOME/zigmem_x86}"; cd "$B"
echo "host $(hostname) $(uname -m)"
mkdir -p src && tar -C src -xf src.tar
pass=0; fail=0
while IFS=$'\t' read -r step bin; do
  if ( cd src && timeout 600 "$B/tests/$bin" > "$B/tests/$bin.out" 2>&1 ); then echo "PASS $step ($bin) $(tail -1 "$B/tests/$bin.out" | cut -c1-100)"; pass=$((pass+1));
  else echo "FAIL $step ($bin) rc=$? $(tail -3 "$B/tests/$bin.out" | tr '\n' ' ' | cut -c1-300)"; fail=$((fail+1)); fi
done < tests.list
echo "unit: $pass pass, $fail fail"
# smoke
H="$B/smoke_home"; [ -e "$H" ] && mv "$H" "$H.old-$(date +%s)"
mkdir -m 700 "$H"
# integrated binaries need the seat bound in a household (synthetic member "ana"); older ones have no household verb
printf '{"members":[{"id":"ana","display":"Ana Test","role":"principal"}],"seats":[{"name":"smoke","member":"ana"}]}' > "$H/hh.json"
if ./bin/zigmem household bootstrap --home "$H" --file "$H/hh.json" >/dev/null 2>&1; then SC='*'; CS=',"scope":"person:ana"'; echo "household: bootstrapped"; else SC=syn-smoke; CS=''; echo "household: n/a (pre-integration binary)"; fi
./bin/zigmem token add --seat smoke --scopes "$SC" --writes --home "$H" > "$H/smoke.token" 2>/dev/null; chmod 600 "$H/smoke.token"
./bin/zigmem serve --home "$H" --port $SP --bind 127.0.0.1 --extract none > "$H/serve.log" 2>&1 &
PID=$!
for i in $(seq 1 50); do curl -s -m 1 -o /dev/null http://127.0.0.1:$SP/health && break; sleep 0.2; done
T=$(cat "$H/smoke.token")
echo "health: $(curl -s -m 3 http://127.0.0.1:$SP/health | cut -c1-200)"
echo "capture: $(curl -s -m 5 http://127.0.0.1:$SP/v1/capture -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d "{\"session_key\":\"s1\",\"user_content\":\"Ana keeps the lantern in the blue shed.\",\"assistant_content\":\"ok\"$CS}" | cut -c1-200)"
echo "conv search: $(curl -s -m 5 http://127.0.0.1:$SP/v1/search/conversations -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"query":"lantern","limit":3}' | cut -c1-300)"
echo "recall: $(curl -s -m 30 -o /dev/null -w '%{http_code}' http://127.0.0.1:$SP/v1/recall -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"query":"where is the lantern"}')"
echo "no-token: $(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:$SP/v1/recall -d '{}')"
echo "refuse 0.0.0.0: $(./bin/zigmem serve --home "$H.x" --port $RP --bind 0.0.0.0 >/dev/null 2>&1; echo rc=$?; [ -e "$H.x" ] && echo home-created || echo no-home)"
echo "listen: $(ss -Hltn "sport = :$SP" | awk '{print $4}')"
kill -TERM $PID; for i in $(seq 1 50); do kill -0 $PID 2>/dev/null || break; sleep 0.1; done
kill -0 $PID 2>/dev/null && echo "STILL RUNNING $PID" || echo "stopped pid $PID"
echo "after stop listen: '$(ss -Hltn "sport = :$SP" | awk '{print $4}')'"
