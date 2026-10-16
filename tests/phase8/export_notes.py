#!/usr/bin/env python3
"""Append the NOTES·TV source (the genome's dated memory files + rules, secrets never indexed — build_notes.py) READ-ONLY as
JSONL rows for `zigmem-recall load`, in the same shape the live c_notes lane serves ("note <path> · <date>", "<title>: <text>").
Phase 3 loaded these 3,580 rows from scratch; this is that export written down. Output stays on the dev box."""
import json, os, sqlite3, sys
HOME = os.path.expanduser("~")
con = sqlite3.connect(f"file:{HOME}/bench_lane/data/notes.sqlite?mode=ro", uri=True)
n = 0
with open(sys.argv[1], "a") as out:
    for i, path, title, date, text in con.execute("SELECT id, path, title, date, text FROM chunks ORDER BY id"):
        if not text:
            continue
        out.write(json.dumps({"src": "notes", "id": i, "date": date or "", "cite": f"note {path}" + (f" · {date}" if date else ""),
                              "text": f"{title}: {text}"}, ensure_ascii=False) + "\n")
        n += 1
print(json.dumps({"notes": n}))
