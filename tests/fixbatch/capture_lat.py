#!/usr/bin/env python3
"""Fix batch item 1: /v1/capture latency through the API (synthetic rows only). Reuses the integration p4 harness
(household bootstrap, seat token, start/stop by exact PID). Sequential 1,000 captures, then 8 clients x 250.
Gate (the phase-4 latency gate applied to capture): p95 <= 10 ms sequential and <= 25 ms with 8 clients.
Usage: ZIGMEM_BIN=... ZIGMEM_SCR=... ZIGMEM_REC=... capture_lat.py TAG [PORT]  -> $ZIGMEM_REC/capture_<TAG>.json"""
import json, os, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "integration"))
import p4_gates as g

tag = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 18186
home = g.fresh_home("caplat_" + tag)
g.bootstrap(home, g.SYN, [("seat-w", "ana")])
tok = g.token_add(home, "seat-w", "person:ana", "--writes", "--trusted", person="ana")
p = g.start(home, port, "--extract", "none")
words = ["kal", "vor", "min", "dus", "pel", "tora", "ven", "sid"]
rng = g.random.Random(11)
load0 = open("/proc/loadavg").read().split()[:3]


def one(i, k=0):
    text = f"syn caplat {tag} k{k} n{i} " + " ".join(rng.choice(words) for _ in range(8))
    t = time.perf_counter()
    st, b = g.req(port, "POST", "/v1/capture", {"user_content": text, "session_key": f"c{k}"}, tok)
    ms = (time.perf_counter() - t) * 1000
    assert st == 200, (st, b)
    return ms


for i in range(50):
    one(i, 99)  # warm-up
seq = [one(i) for i in range(1000)]
conc, lock = [], threading.Lock()


def worker(k):
    mine = [one(i, k + 1) for i in range(250)]
    with lock:
        conc.extend(mine)


th = [threading.Thread(target=worker, args=(k,)) for k in range(8)]
tc = time.perf_counter()
[x.start() for x in th]
[x.join() for x in th]
wall = time.perf_counter() - tc
st, h = g.jreq(port, "GET", "/health")
g.stop(p)
con = g.sqlite3.connect(os.path.join(home, "zigmem.db"))
rows = con.execute("SELECT count(*) FROM l0").fetchone()[0]
con.close()
pct = g.pct
res = {"tag": tag, "bin": g.Z, "load_before": load0, "load_after": open("/proc/loadavg").read().split()[:3], "l0_rows": rows,
       "sequential_ms": {"n": len(seq), "p50": round(pct(seq, .5), 3), "p95": round(pct(seq, .95), 3), "p99": round(pct(seq, .99), 3), "max": round(max(seq), 2), "per_s": round(len(seq) / (sum(seq) / 1000), 1)},
       "concurrent8_ms": {"n": len(conc), "p50": round(pct(conc, .5), 3), "p95": round(pct(conc, .95), 3), "p99": round(pct(conc, .99), 3), "max": round(max(conc), 2), "per_s": round(len(conc) / wall, 1)},
       "stops": g.STOPS}
res["gate_green"] = res["sequential_ms"]["p95"] <= 10 and res["concurrent8_ms"]["p95"] <= 25
g.receipt("capture_" + tag, res)
print(json.dumps(res, indent=1))
print("CAPTURE", tag, "GREEN" if res["gate_green"] else "RED")
