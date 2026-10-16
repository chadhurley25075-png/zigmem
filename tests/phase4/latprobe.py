#!/usr/bin/env python3
"""Where does search latency go? Same server, same DB: vary query shape; report server-side ms (audit) per class."""
import json, os, random, sqlite3, sys, time
sys.path.insert(0, os.path.dirname(__file__))
import gates as g
home = os.path.join(g.SCR, "lat")
tok = g.token_add(home, "probe-" + str(int(time.time())), "syn-a,syn-b")
p = g.start(home, 18156)
con = sqlite3.connect(os.path.join(home, "zigmem.db"))
texts = [r[0] for r in con.execute("SELECT text FROM atoms ORDER BY random() LIMIT 300")]
con.close()
rng = random.Random(1)
def run(label, qs, **kw):
    ts = []
    for q in qs:
        t = time.perf_counter()
        st, b = g.req(18156, "POST", "/v1/search/memories", dict(query=q, limit=10, **kw), tok)
        ts.append((time.perf_counter() - t) * 1000)
    ts.sort()
    print(f"{label:40s} n={len(ts)} p50={ts[len(ts)//2]:.2f} p95={ts[int(.95*(len(ts)-1))]:.2f}")
words = [w for t in texts for w in t.split()[2:]]
run("same query x100", ["kaloner17 mitudor5"] * 100)
run("1 random word from texts", [rng.choice(words) for _ in range(200)])
run("2-3 words from texts", [" ".join(rng.sample(t.split()[2:], 3)) for t in texts[:200]])
run("2-3 words, scope syn-a", [" ".join(rng.sample(t.split()[2:], 3)) for t in texts[:200]], scope="syn-a")
run("nonsense word", ["zzzqqq%d" % i for i in range(200)])
g.stop(p)
au = [json.loads(l) for l in open(os.path.join(home, "audit.log")) if "search_ms" in l]
au = au[-1000:]
tot = sorted(x["ms"] for x in au); se = sorted(x["search_ms"] for x in au)
print("server total p50/p95", tot[len(tot)//2], tot[int(.95*(len(tot)-1))], " search p50/p95", se[len(se)//2], se[int(.95*(len(se)-1))])
