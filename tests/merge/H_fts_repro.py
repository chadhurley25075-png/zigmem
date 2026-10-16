#!/usr/bin/env python3
"""Merge lane diagnostic (synthetic only): does /health?deep=1 (fixbatch quick_check on the hub's long-lived read-only
connection) report FTS5 "corruption" while captures are being written, and is the file actually sound at that moment?
Candidate binary on 127.0.0.1:18236, home scratch/merge/run/fts_repro_<n> (fresh). 4 writer threads post synthetic captures;
the checker calls /health?deep=1 back-to-back (or every --every s); on each non-ok result an independent system-sqlite
quick_check runs on the live file (mode=ro) and on a .backup copy + FTS5 'integrity-check'. Server stopped by exact PID."""
import json, os, random, sqlite3, subprocess, sys, threading, time, urllib.request, urllib.error
BIN, SECS, NAME = sys.argv[1], int(sys.argv[2]), sys.argv[3]; EVERY = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0; PORT = 18236
D = os.path.expanduser(f"~/zigmem/scratch/merge/run/fts_repro_{NAME}"); assert not os.path.exists(D), "exists"
os.makedirs(D, mode=0o700); H = D + "/home"; os.makedirs(H, mode=0o700)
json.dump({"members": [{"id": "syna", "display": "Syn A", "role": "principal", "relation": "father"}], "seats": [{"name": "synh", "member": "syna"}]}, open(H + "/hh.json", "w"))
subprocess.run([BIN, "household", "bootstrap", "--home", H, "--file", H + "/hh.json"], check=True, capture_output=True)
TOK = subprocess.run([BIN, "token", "add", "--seat", "synh", "--scopes", "*", "--writes", "--trusted", "--home", H], check=True, capture_output=True, text=True).stdout.strip()
P = subprocess.Popen([BIN, "serve", "--home", H, "--port", str(PORT), "--bind", "127.0.0.1", "--extract", "none"], stdout=open(D + "/serve.log", "w"), stderr=subprocess.STDOUT)
def get(path, timeout=60):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}{path}", timeout=timeout) as r: return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read() or b"{}")
    except Exception as e: return 0, {"err": str(e)}
for _ in range(200):
    if get("/health", 1)[0] in (200, 503): break
    time.sleep(0.1)
stop = threading.Event(); acked = [0]; werr = [0]; W = ["kal", "vor", "min", "dus", "pel", "tor", "sab", "lin", "rue", "gat", "zen", "mor"]
def writer(k):
    n = 0
    while not stop.is_set():
        body = json.dumps({"user_content": f"syn fts w{k} n{n} " + " ".join(random.choice(W) + str(random.randint(0, 999)) for _ in range(12)), "session_key": f"f{k}-{n // 50}"}).encode()
        rq = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/capture", body, {"Authorization": "Bearer " + TOK, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(rq, timeout=10) as r: acked[0] += r.status == 200
        except Exception: werr[0] += 1
        n += 1
ts = [threading.Thread(target=writer, args=(k,), daemon=True) for k in range(4)]; [t.start() for t in ts]
db = H + "/zigmem.db"; res = {"name": NAME, "every_s": EVERY, "checks": 0, "bad": []}; t0 = time.time()
while time.time() - t0 < SECS:
    st, j = get("/health?deep=1"); res["checks"] += 1
    q = (j.get("db") or {}).get("quick_check")
    if st != 200 or q != "ok":
        ev = {"t": round(time.time() - t0, 1), "status": st, "quick_check": q}
        c = sqlite3.connect(f"file:{db}?mode=ro", uri=True); ev["sys_quick_check_live"] = c.execute("PRAGMA quick_check(5)").fetchall()
        bk = f"{D}/backup_{len(res['bad'])}.db"; b = sqlite3.connect(bk); c.backup(b); c.close()
        try:
            b.execute("INSERT INTO l0_fts(l0_fts) VALUES('integrity-check')"); ev["backup_fts5_integrity"] = "ok"
        except Exception as e: ev["backup_fts5_integrity"] = str(e)
        ev["backup_quick_check"] = b.execute("PRAGMA quick_check(5)").fetchall(); b.close()
        st2, j2 = get("/health?deep=1"); ev["hub_recheck"] = [st2, (j2.get("db") or {}).get("quick_check")]
        res["bad"].append(ev); print(json.dumps(ev), flush=True)
    if EVERY: time.sleep(EVERY)
stop.set(); time.sleep(1)
res.update(acked=acked[0], werr=werr[0], secs=SECS, l0_rows=get("/health")[1].get("rows"))
P.terminate(); P.wait(10); res["stopped_pid"] = P.pid; res["gone"] = P.poll() is not None
print(json.dumps({k: v for k, v in res.items() if k != "bad"}), "bad", len(res["bad"]))
json.dump(res, open(os.path.expanduser(f"~/zigmem/receipts/merge/fts_quickcheck_repro_{NAME}.json"), "w"), indent=1)
