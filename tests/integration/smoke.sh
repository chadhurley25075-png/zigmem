#!/bin/bash
# integration smoke: synthetic household, one capture, one search, one recall, whoami; stop by PID.
set -u
Z=~/zigmem/scratch/integ/tree/out/bin/zigmem
H=~/zigmem/scratch/integ/smoke
rm -rf "$H"; mkdir -p "$H"; chmod 700 "$H"
cat > "$H/hh.json" <<J
{"members":[{"id":"sam","display":"Pat Synth","role":"principal","relation":"father"},{"id":"ana","display":"Ana Synth","role":"child"}],
 "seats":[{"name":"seat-a","member":"ana"},{"name":"seat-p","member":"sam"}]}
J
$Z household bootstrap --home "$H" --file "$H/hh.json"
TA=$($Z token add --home "$H" --seat seat-a --scopes '*' --writes --trusted)
TP=$($Z token add --home "$H" --seat seat-p --scopes '*' --writes --trusted --admin)
$Z serve --home "$H" --port 18189 > "$H/serve.log" 2>&1 &
P=$!
sleep 1.5
c() { curl -s -m 20 -X POST "127.0.0.1:18189$1" -H "Authorization: Bearer $2" -H content-type:application/json -d "$3"; echo; }
curl -s 127.0.0.1:18189/health; echo
c /v1/household/whoami $TA '{}'
c /v1/atoms/add $TA '{"text":"Ana keeps the lantern in the blue shed.","subject":"ana"}'
c /v1/atoms/add $TP '{"text":"Pat keeps the kayak in the barn.","subject":"sam","scope":"person:pat"}'
c /v1/search/memories $TA '{"query":"lantern"}'
c /v1/search/memories $TA '{"query":"kayak"}'
c /v1/search/memories $TP '{"query":"lantern"}'
c /v1/search/memories $TP '{"query":"Ana lantern"}'
c /v1/recall $TP '{"query":"where does Ana keep the lantern"}'
c /v1/capture $TA '{"user_content":"I like the blue shed best.","session_key":"s1"}'
c /v1/search/conversations $TA '{"query":"blue shed"}'
c /v1/search/conversations $TP '{"query":"blue shed"}'
c /v1/search/memories $TA '{"query":"kayak","scope":"person:pat"}'
c /v1/search/memories zm_0000 '{"query":"kayak"}'
kill $P; sleep 0.5; kill -0 $P 2>/dev/null && echo STILL_ALIVE || echo stopped $P
cat "$H/serve.log" | head -5
sqlite3 "$H/zigmem.db" "select seat, action, detail from audit where action in ('xread','deny')" 2>/dev/null | head
