#!/usr/bin/env python3
"""The same SQL the store runs (ftsPlan df counts + bm25 query), timed in-process with Python's sqlite3, on the latency DB."""
import os, random, sqlite3, sys, time
sys.path.insert(0, os.path.dirname(__file__))
import gates as g
syl = ["ka", "lo", "mi", "ner", "tu", "sa", "vel", "dor", "pi", "qua", "ren", "zo", "bri", "fen", "gal", "hum"]
def word(idx):
    x = idx + 17; s = ""
    for _ in range(3):
        s += syl[x % 16]; x //= 16
    return s + str(idx % 97)
rng = random.Random(7)
qa = [[word(int(5000 * rng.random() ** 3)) for _ in range(2 + rng.randrange(2))] for _ in range(300)]
con = sqlite3.connect("file:" + os.path.join(g.SCR, "lat", "zigmem.db") + "?mode=ro", uri=True)
con.execute("PRAGMA cache_size=-65536"); con.execute("PRAGMA mmap_size=134217728")
total = con.execute("SELECT max(id) FROM atoms").fetchone()[0]; th = max(1000, total // 20)
t_df = []; t_q = []
for terms in qa:
    t = time.perf_counter(); kept = []
    for w in terms:
        n = con.execute("SELECT count(*) FROM (SELECT 1 FROM atoms_fts WHERE atoms_fts MATCH ? LIMIT ?)", ('"%s"' % w, th + 1)).fetchone()[0]
        if n <= th: kept.append('"%s"' % w)
    t_df.append((time.perf_counter() - t) * 1000)
    m = " OR ".join(kept) if kept else " OR ".join('"%s"' % w for w in terms)
    order = "ORDER BY r" if kept else "ORDER BY atoms_fts.rowid DESC"
    t = time.perf_counter()
    con.execute("SELECT a.id, a.text, bm25(atoms_fts) AS r FROM atoms_fts JOIN atoms a ON a.id = atoms_fts.rowid WHERE atoms_fts MATCH ? "
                "AND a.status = 'active' AND a.scope IN ('syn-a','syn-b') " + order + " LIMIT 10", (m,)).fetchall()
    t_q.append((time.perf_counter() - t) * 1000)
for name, xs in [("df counts", t_df), ("bm25 query", t_q)]:
    xs.sort(); print(f"{name:12s} p50={xs[len(xs)//2]:.2f} p95={xs[int(.95*(len(xs)-1))]:.2f}")
print("sqlite", sqlite3.sqlite_version)
