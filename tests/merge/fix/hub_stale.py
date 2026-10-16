#!/usr/bin/env python3
"""Merge lane: hub-level repro of the /health false corruption (synthetic only). Port 127.0.0.1:18236, fresh home under
scratch/merge/fix/hub_<name>. Phase 1: hub A preloads PRE captures, then is stopped (SIGTERM, exact PID). Phase 2: hub B starts
on the populated store (its check connection opens on a non-empty l0_fts, as after the soak's kill -9 restart); CYCLES times:
BURST captures (one commit each), then GET /health?deep=1 (runs the check now). Each cycle also runs an independent
fresh-connection check with the vendored-SQLite C tool (fts_stale_check) on the live file.
usage: hub_stale.py BIN NAME PRE CYCLES BURST"""
import json, os, random, subprocess, sys, time, urllib.request, urllib.error
BIN, NAME, PRE, CYC, BURST = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]); PORT = 18236
F = os.path.expanduser("~/zigmem/scratch/merge/fix"); D = f"{F}/hub_{NAME}"; assert not os.path.exists(D), "exists"
os.makedirs(D, mode=0o700); H = D + "/home"; os.makedirs(H, mode=0o700)
json.dump({"members": [{"id": "syna", "display": "Syn A", "role": "principal", "relation": "father"}], "seats": [{"name": "synh", "member": "syna"}]}, open(H + "/hh.json", "w"))
subprocess.run([BIN, "household", "bootstrap", "--home", H, "--file", H + "/hh.json"], check=True, capture_output=True)
TOK = subprocess.run([BIN, "token", "add", "--seat", "synh", "--scopes", "*", "--writes", "--trusted", "--home", H], check=True, capture_output=True, text=True).stdout.strip()
def get(path, timeout=120):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}{path}", timeout=timeout) as r: return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read() or b"{}")
    except Exception as e: return 0, {"err": str(e)}
def start():
    p = subprocess.Popen([BIN, "serve", "--home", H, "--port", str(PORT), "--bind", "127.0.0.1", "--extract", "none"], stdout=open(D + "/serve.log", "a"), stderr=subprocess.STDOUT)
    for _ in range(300):
        if get("/health", 1)[0] in (200, 503): return p
        time.sleep(0.1)
    raise SystemExit("hub did not start")
def stop(p):
    p.terminate(); p.wait(15); assert p.poll() is not None
W = ["kal", "vor", "min", "dus", "pel", "tor", "sab", "lin", "rue", "gat", "zen", "mor"]; n = [0]
def cap(k):
    for _ in range(k):
        body = json.dumps({"user_content": f"syn stale n{n[0]} " + " ".join(random.choice(W) + str(random.randint(0, 499)) for _ in range(14)), "session_key": f"s{n[0] // 100}"}).encode()
        rq = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/capture", body, {"Authorization": "Bearer " + TOK, "Content-Type": "application/json"})
        with urllib.request.urlopen(rq, timeout=10) as r: assert r.status == 200
        n[0] += 1
res = {"name": NAME, "bin_sha256": subprocess.run(["sha256sum", BIN], capture_output=True, text=True).stdout.split()[0], "pre": PRE, "cycles": []}
pa = start(); cap(PRE); stop(pa); res["pid_A"] = pa.pid
pb = start(); res["pid_B"] = pb.pid
for k in range(CYC):
    cap(BURST)
    st, j = get("/health?deep=1"); q = (j.get("db") or {}).get("quick_check")
    ind = subprocess.run([f"{F}/fts_stale_check", H + "/zigmem.db"], capture_output=True, text=True).stdout.strip()
    res["cycles"].append({"k": k, "rows": n[0], "status": st, "hub_quick_check": q, "fresh_conn_check": ind})
    print(json.dumps(res["cycles"][-1]), flush=True)
stop(pb)
res["hub_false_reports"] = sum(1 for c in res["cycles"] if c["status"] != 200 and c["fresh_conn_check"] == "ok")
res["fresh_conn_failures"] = sum(1 for c in res["cycles"] if c["fresh_conn_check"] != "ok")
res["nothing_listening"] = subprocess.run(["ss", "-Hltn", f"sport = :{PORT}"], capture_output=True, text=True).stdout.strip() == ""
print("SUMMARY", json.dumps({k: v for k, v in res.items() if k != "cycles"}))
json.dump(res, open(os.path.expanduser(f"~/zigmem/receipts/merge/hub_stale_{NAME}.json"), "w"), indent=1)
