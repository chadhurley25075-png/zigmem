#!/bin/bash
# zigmem phase 2 gate run: NAME EXTRACT JUDGE [extra gate args...]
# Runs the gate binary under strace (connect syscalls) + an ss sampler, then audits destinations and grades.
set -u
cd ~/zigmem || exit 2
NAME=$1; EX=$2; JU=$3; shift 3
R=receipts/phase2; mkdir -p $R scratch
export PATH=~/.local/bin:$PATH
if [[ "$EX $JU" == *secondary* ]]; then
  J=$(the secondary engine status command 2>&1 | sed -n 's/^  jobs *\([0-9]*\).*/\1/p' | head -1)
  echo "secondary jobs before run: ${J:-?}"
  if [ "${J:-1}" != "0" ]; then echo "secondary busy or unreadable: not running"; exit 3; fi
fi
DB=scratch/extract_$NAME.db; rm -f $DB $DB-wal $DB-shm
strace -f -qq -e trace=connect -o $R/$NAME.strace ./zig-out/bin/zigmem-extractgate --set tests/extract/turns.json \
  --extract $EX --judge $JU --run-id $NAME --store $DB "$@" > $R/$NAME.jsonl 2> $R/$NAME.err &
SP=$!
: > $R/$NAME.ss
while kill -0 $SP 2>/dev/null; do
  for p in $(pgrep -P $SP) ; do ss -tnpH 2>/dev/null | grep "pid=$p," >> $R/$NAME.ss; done
  sleep 0.5
done
wait $SP; echo "gate exit=$?"
python3 - "$R/$NAME.strace" "$R/$NAME.ss" > $R/${NAME}_offbox.json <<'EOF'
import re, sys, json
allowed = {("127.0.0.1", 18080), ("127.0.0.1", 18033)}
st = open(sys.argv[1]).read().splitlines()
conns = []
for l in st:
    if "connect(" not in l: continue
    m = re.search(r'sin_port=htons\((\d+)\).*inet_addr\("([\d.]+)"\)', l)
    if m: conns.append((m.group(2), int(m.group(1))))
    else: conns.append(("other", l.strip()[:160]))
ss = [l.split() for l in open(sys.argv[2]) if l.strip()]
peers = sorted({x[4] for x in ss if len(x) > 4})
bad = [c for c in conns if c not in allowed]
bad_ss = [p for p in peers if p not in ("127.0.0.1:18080", "127.0.0.1:18033")]
print(json.dumps({"connect_calls": len(conns), "destinations": sorted({f"{a}:{p}" for a, p in conns}), "offbox": bad,
                  "ss_samples": len(ss), "ss_peers": peers, "ss_offbox": bad_ss}, indent=1))
EOF
cat $R/${NAME}_offbox.json
python3 tests/extract/grade.py $R/$NAME.jsonl tests/extract/turns.json --json $R/${NAME}_grade.json | tee $R/${NAME}_grade.txt
