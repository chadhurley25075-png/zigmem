#!/usr/bin/env python3
"""Latency probe (diagnosis only, not a gate): the latency gate's own query recipe against an existing home, with
extra serve args, sequential N queries; prints p50/p95. Usage: latprobe.py HOME PORT N [serve args...]"""
import http.client, json, os, random, sqlite3, subprocess, sys, time
home, port, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
Z = os.environ.get("ZIGMEM_BIN", os.path.expanduser("~/zigmem/scratch/integ/tree/out/bin/zigmem"))
tok = subprocess.run([Z, "token", "add", "--home", home, "--seat", "seat-l", "--scopes", "person:ana,person:ben"], capture_output=True, text=True).stdout.strip()
if not tok:
    print("token: reuse failed; revoke+readd"); subprocess.run([Z, "token", "revoke", "--home", home, "--seat", "seat-l"], capture_output=True)
    tok = subprocess.run([Z, "token", "add", "--home", home, "--seat", "seat-l", "--scopes", "person:ana,person:ben"], capture_output=True, text=True).stdout.strip()
con = sqlite3.connect(os.path.join(home, "zigmem.db"))
texts = [r[0] for r in con.execute("SELECT text FROM atoms ORDER BY random() LIMIT 400")]
con.close()
rng = random.Random(9)
qs = [" ".join(rng.sample(t.split()[2:], min(len(t.split()[2:]), rng.randint(2, 3)))) for t in texts]
p = subprocess.Popen([Z, "serve", "--home", home, "--port", str(port)] + sys.argv[4:], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1.5)
def req(q):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    c.request("POST", "/v1/search/memories", body=json.dumps({"query": q, "limit": 10}), headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"})
    r = c.getresponse(); b = r.read(); c.close(); return r.status
for q in qs[:50]: req(q)
lat = []
for i in range(n):
    t = time.perf_counter(); assert req(qs[i % len(qs)]) == 200; lat.append((time.perf_counter() - t) * 1000)
h = http.client.HTTPConnection("127.0.0.1", port); h.request("GET", "/health"); print("prof_us", json.loads(h.getresponse().read()).get("prof_us")); h.close()
p.terminate(); p.wait(10)
lat.sort()
print(json.dumps({"args": sys.argv[4:], "p50": round(lat[len(lat)//2], 2), "p95": round(lat[int(.95*(len(lat)-1))], 2), "pid_gone": p.poll() is not None}))
