#!/usr/bin/env python3
"""Phase-1-shaped queries (same generator as src/store/bench.zig) vs text-sampled queries, through the API."""
import json, os, random, sqlite3, sys, time
sys.path.insert(0, os.path.dirname(__file__))
import gates as g
syl = ["ka", "lo", "mi", "ner", "tu", "sa", "vel", "dor", "pi", "qua", "ren", "zo", "bri", "fen", "gal", "hum"]
def word(idx):
    x = idx + 17; s = ""
    for _ in range(3):
        s += syl[x % 16]; x //= 16
    return s + str(idx % 97)
rng = random.Random(7)
pick = lambda: int(5000 * rng.random() ** 3)
home = os.path.join(g.SCR, "lat")
con = sqlite3.connect(os.path.join(home, "zigmem.db"))
def df(w):
    return con.execute("SELECT count(*) FROM atoms_fts WHERE atoms_fts MATCH ?", ('"%s"' % w,)).fetchone()[0]
qa = [" ".join(word(pick()) for _ in range(2 + rng.randrange(2))) for _ in range(300)]
texts = [r[0] for r in con.execute("SELECT text FROM atoms ORDER BY random() LIMIT 300")]
qb = [" ".join(rng.sample(t.split()[2:], 3)) for t in texts]
for name, qs in [("phase1-generator", qa), ("text-sampled", qb)]:
    dfs = sorted(df(w) for q in qs[:100] for w in q.split())
    print(name, "term df p50/p90/max", dfs[len(dfs)//2], dfs[int(.9*len(dfs))], dfs[-1])
tok = g.token_add(home, "probe2-" + str(int(time.time())), "syn-a,syn-b")
p = g.start(home, 18157)
for name, qs in [("phase1-generator", qa), ("text-sampled", qb)]:
    ts = []
    for q in qs:
        t = time.perf_counter(); g.req(18157, "POST", "/v1/search/memories", {"query": q, "limit": 10}, tok); ts.append((time.perf_counter() - t) * 1000)
    ts.sort(); print(f"{name:20s} API p50={ts[len(ts)//2]:.2f} p95={ts[int(.95*(len(ts)-1))]:.2f}")
g.stop(p)
