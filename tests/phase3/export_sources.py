#!/usr/bin/env python3
"""Export the four the reranked lane sources (journal · synth · vault · facts) READ-ONLY to one JSONL for `zigmem-recall load`,
using the live lanes' own cleaning so zigmem sees the same text the control does. Output stays on the dev box (scratch/p3/).
Rows: {"src","id","date","cite","text"}. Mirrors c_scroll (clean, len>=200, noise rows out), c_facts (reader_rejects out)."""
import json, os, sqlite3, sys
HOME = os.path.expanduser("~")
sys.path.insert(0, HOME); sys.path.insert(0, f"{HOME}/bench_lane"); sys.path.insert(0, f"{HOME}/bench_eval")
import turbovec_scroll_precog as T
import blend_rerank as B
out = open(sys.argv[1], "w")
n = {}
def w(src, i, date, cite, text):
    if not text: return
    out.write(json.dumps({"src": src, "id": i, "date": date or "", "cite": cite, "text": text}, ensure_ascii=False) + "\n")
    n[src] = n.get(src, 0) + 1
def ro(p): return sqlite3.connect(f"file:{p}?mode=ro", uri=True)
D = f"{HOME}/bench_lane/data"
for i, vol, sub, rs, date, text in ro(f"{D}/synth.sqlite").execute("SELECT id, vol, sub, raw_start, date, text FROM chunks ORDER BY id"):
    w("synth", i, date, (f"synthesis Vol {vol}{sub} raw L{rs}" if rs else "synthesis core") + (f" · {date}" if date else ""), text)
for i, path, title, date, text in ro(f"{D}/vault.sqlite").execute("SELECT id, path, title, date, text FROM chunks ORDER BY id"):
    w("vault", i, date, f"vault {path}" + (f" · {date}" if date else ""), f"{title}: {text}")
rej = B.reader_rejects()
for i, date, fact, vol, sub, rs in ro(f"{D}/facts.sqlite").execute("SELECT id, date, fact, vol, sub, raw_start FROM facts ORDER BY id"):
    if str(i) in rej: n["facts_rejected"] = n.get("facts_rejected", 0) + 1; continue
    w("fact", i, date, f"fact · {date or 'undated'} · synthesis Vol {vol}{sub or ''} raw L{rs}", fact)
for i, vol, ls, dh, text, noise in ro(f"{HOME}/bench_eval/data/scroll_chunks.sqlite").execute("SELECT id, vol, line_start, date_hint, text, noise FROM chunks ORDER BY id"):
    if noise: n["scroll_noise"] = n.get("scroll_noise", 0) + 1; continue
    t = T._clean(text)
    if len(t) < 200: continue
    w("journal", i, dh, f"Vol {vol} · {dh or 'undated'} · L{ls}", t)
print(json.dumps(n))
