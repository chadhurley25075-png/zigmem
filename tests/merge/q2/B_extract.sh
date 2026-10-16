#!/usr/bin/env bash
# Merge lane B: extraction gates (hard 47, phase-2 46) through zigmem-extractgate on the primary engine ONLY (extract + judge = primary;
# the tool sends one request at a time → <= 2 concurrent holds). Same procedure as tests/fixbatch/run_extract_fb.sh (strace +
# ss off-box audit, both graders), receipts → receipts/merge2/extract, stores → scratch/merge/run/extract. Synthetic sets only.
set -u
ZM=$HOME/zigmem; M=$ZM/scratch/merge; T=$M/tree; cd $T || exit 2
GATE=$M/out2/bin/zigmem-extractgate; R=$ZM/receipts/merge2/extract; SC=$M/run2/extract; mkdir -p $R $SC
run() { NAME=$1; KIND=$2
  case $KIND in hard) SET=tests/hardening/extract_hard/turns_hard.json ;; p2) SET=tests/extract/turns.json ;; esac
  DB=$SC/extract_$NAME.db; [ -e "$DB" ] && { echo "$DB exists — refusing"; return 2; }
  echo "gate sha256 $(sha256sum $GATE | cut -c1-64)  set sha256 $(sha256sum $SET | cut -c1-64)  load $(cut -d' ' -f1-3 /proc/loadavg) start $(date -Is)" > $R/$NAME.meta
  strace -f -qq -e trace=connect -o $R/$NAME.strace $GATE --set $SET --extract primary --judge primary --run-id $NAME --store $DB > $R/$NAME.jsonl 2> $R/$NAME.err &
  SP=$!; : > $R/$NAME.ss
  while kill -0 $SP 2>/dev/null; do for p in $(pgrep -P $SP); do ss -tnpH 2>/dev/null | grep "pid=$p," >> $R/$NAME.ss; done; sleep 0.5; done
  wait $SP; echo "gate exit=$? end $(date -Is)" | tee -a $R/$NAME.meta
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
  [ $KIND = hard ] && /usr/bin/python3 -I tests/hardening/extract_hard/hard_grade.py $R/$NAME.jsonl $SET --json $R/${NAME}_hard_grade.json | tee $R/${NAME}_hard_grade.txt
  /usr/bin/python3 -I tests/extract/grade.py $R/$NAME.jsonl $SET --json $R/${NAME}_p2grade.json > $R/${NAME}_p2grade.txt 2>&1; head -3 $R/${NAME}_p2grade.txt
  sqlite3 "file:$DB?mode=ro" 'PRAGMA integrity_check' | tee -a $R/$NAME.meta
}
echo "primary models: $(curl -s -m 5 http://127.0.0.1:18080/v1/models | head -c 120)"
run M2_hard hard; run M2_p2 p2
echo B_DONE
