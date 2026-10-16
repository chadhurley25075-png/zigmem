#!/bin/bash
# Fix batch item 2: run an extraction set through zigmem-extractgate (the real pipeline + store sink) on the primary engine only
# (extract AND judge = primary; the gate tool sends one request at a time, so <= 2 concurrent always holds).
# Copy of tests/hardening/extract_hard/run_hard.sh + tests/extract/run_gate.sh audit, pointed at the fixbatch tree and
# receipts/fixbatch/extract (the originals cd into ~/zigmem and write its receipts, which this lane must not touch).
#   bash tests/fixbatch/run_extract_fb.sh NAME hard|p2 GATE_BIN
set -u
T=$(cd "$(dirname "$0")/../.." && pwd); cd "$T" || exit 2
NAME=$1; KIND=$2; GATE=$3
R=receipts/fixbatch/extract; SC=$T/../run/extract; mkdir -p $R $SC
case $KIND in hard) SET=tests/hardening/extract_hard/turns_hard.json ;; p2) SET=tests/extract/turns.json ;; *) echo "kind?"; exit 2 ;; esac
DB=$SC/extract_$NAME.db; [ -e "$DB" ] && { echo "$DB exists — refusing"; exit 2; }
echo "gate sha256 $(sha256sum $GATE | cut -c1-64)  set sha256 $(sha256sum $SET | cut -c1-64)  load $(cut -d' ' -f1-3 /proc/loadavg)" > $R/$NAME.meta
strace -f -qq -e trace=connect -o $R/$NAME.strace $GATE --set $SET --extract primary --judge primary --run-id $NAME --store $DB \
  > $R/$NAME.jsonl 2> $R/$NAME.err &
SP=$!
: > $R/$NAME.ss
while kill -0 $SP 2>/dev/null; do
  for p in $(pgrep -P $SP); do ss -tnpH 2>/dev/null | grep "pid=$p," >> $R/$NAME.ss; done
  sleep 0.5
done
wait $SP; echo "gate exit=$?" | tee -a $R/$NAME.meta
/usr/bin/python3 -I - "$R/$NAME.strace" "$R/$NAME.ss" > $R/${NAME}_offbox.json <<'PY'
import re, sys, json
st = open(sys.argv[1]).read().splitlines(); conns = []
for l in st:
    if "connect(" not in l: continue
    m = re.search(r'sin_port=htons\((\d+)\).*inet_addr\("([\d.]+)"\)', l)
    conns.append((m.group(2), int(m.group(1))) if m else ("other", l.strip()[:160]))
peers = sorted({x.split()[4] for x in open(sys.argv[2]) if len(x.split()) > 4})
print(json.dumps({"connect_calls": len(conns), "destinations": sorted({f"{a}:{p}" for a, p in conns}),
                  "offbox": [c for c in conns if c != ("127.0.0.1", 18080)], "ss_peers": peers,
                  "ss_offbox": [p for p in peers if p != "127.0.0.1:18080"]}, indent=1))
PY
cat $R/${NAME}_offbox.json
if [ $KIND = hard ]; then
  /usr/bin/python3 -I tests/hardening/extract_hard/hard_grade.py $R/$NAME.jsonl $SET --json $R/${NAME}_hard_grade.json | tee $R/${NAME}_hard_grade.txt
fi
/usr/bin/python3 -I tests/extract/grade.py $R/$NAME.jsonl $SET --json $R/${NAME}_p2grade.json > $R/${NAME}_p2grade.txt 2>&1
head -3 $R/${NAME}_p2grade.txt
sqlite3 "file:$DB?mode=ro" 'PRAGMA integrity_check' | tee -a $R/$NAME.meta
