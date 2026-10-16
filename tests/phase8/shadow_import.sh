#!/usr/bin/env bash
# Phase-8 shadow import: the same sources + exclusions phase 3 used (export_sources.py: journal/synth/vault/facts with the live
# lanes' own cleaning + reader_rejects; export_notes.py: NOTES·TV), embedded by local nomic (Ollama :11434, as phase 3), into
# a NEW store. Family text stays on the dev box (dir 0700). Usage: shadow_import.sh OUTDIR ZIGMEM_RECALL_BIN
set -euo pipefail
OUT="$1"; BIN="$2"; ZM="$HOME/zigmem"
mkdir -p -m 700 "$OUT"
[ -e "$OUT/zigmem.db" ] && { echo "refusing: $OUT/zigmem.db exists"; exit 1; }
date -Is > "$OUT/started"
"python3" "$ZM/tests/phase3/export_sources.py" "$OUT/sources.jsonl" > "$OUT/export_counts.json"
"python3" "$ZM/tests/phase8/export_notes.py" "$OUT/sources.jsonl" > "$OUT/export_notes.json"
wc -l < "$OUT/sources.jsonl" > "$OUT/lines"
sha256sum "$BIN" > "$OUT/loader.sha256"
"$BIN" load --db "$OUT/zigmem.db" --jsonl "$OUT/sources.jsonl" --name shadow-p8 --embed-url http://127.0.0.1:11434/api/embed --embed-fmt ollama > "$OUT/load.json" 2> "$OUT/load.log"
"$BIN" stats --db "$OUT/zigmem.db" > "$OUT/stats.json"
date -Is > "$OUT/finished"
