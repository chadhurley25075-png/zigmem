#!/bin/bash
# Hardening item 3: run the HARD extraction set through the existing phase-2 extraction path (zigmem-extractgate, the
# real pipeline + store sink) on the primary engine only (extract AND judge = primary; sequential = 1 request at a time).
# Same off-box audit as tests/extract/run_gate.sh (strace connect + ss sampler). Synthetic data only.
#   bash tests/hardening/extract_hard/run_hard.sh NAME [GATE_BIN]
set -u
cd ~/zigmem || exit 2
NAME=$1; GATE=${2:-$HOME/zigmem/scratch/hardening/bin-531de47/bin/zigmem-extractgate}
R=receipts/hardening/extract_hard; SC=scratch/hardening/extract_hard; mkdir -p $R $SC
SET=tests/hardening/extract_hard/turns_hard.json
DB=$SC/extract_$NAME.db; [ -e "$DB" ] && { echo "$DB exists — refusing"; exit 2; }
echo "gate sha256 $(sha256sum $GATE | cut -c1-64)  set sha256 $(sha256sum $SET | cut -c1-64)" > $R/$NAME.meta
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
/usr/bin/python3 -I tests/hardening/extract_hard/hard_grade.py $R/$NAME.jsonl $SET --json $R/${NAME}_hard_grade.json | tee $R/${NAME}_hard_grade.txt
/usr/bin/python3 -I tests/extract/grade.py $R/$NAME.jsonl $SET --json $R/${NAME}_p2grade.json > $R/${NAME}_p2grade.txt 2>&1
sqlite3 "file:$DB?mode=ro" 'PRAGMA integrity_check' | tee -a $R/$NAME.meta
