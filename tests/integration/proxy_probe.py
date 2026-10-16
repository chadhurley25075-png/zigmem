#!/usr/bin/env python3
"""Proxy token probe (no engine): the hub's proxy in front of a local fake upstream that records every request.
GREEN = without a token / with a wrong token → 401 and the upstream saw nothing; with the seat's token → forwarded,
the seat's block injected, and the token NOT forwarded upstream. Synthetic only. Ports 18187 (hub) 18188 (proxy) 18189 (upstream)."""
import http.client, http.server, json, os, signal, subprocess, sys, threading, time

ROOT = os.path.expanduser("~/zigmem")
Z = os.environ.get("ZIGMEM_BIN", f"{ROOT}/scratch/integ/tree/out/bin/zigmem")
SCR = os.environ.get("ZIGMEM_SCR", f"{ROOT}/scratch/integ/proxyprobe")
REC = os.environ.get("ZIGMEM_REC", f"{ROOT}/receipts/integration/p7")
H = f"{SCR}/home"
SEEN = []


class Up(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        SEEN.append({"auth": self.headers.get("Authorization"), "body": body.decode()})
        out = json.dumps({"choices": [{"message": {"content": "ok"}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


subprocess.run(["rm", "-rf", SCR], check=True)
os.makedirs(H, mode=0o700)
tok = subprocess.run([Z, "token", "add", "--home", H, "--seat", "seat-p", "--scopes", "*"], check=True, capture_output=True, text=True).stdout.strip()
json.dump({"members": [{"id": "ana", "display": "Ana", "role": "child"}], "seats": [{"name": "seat-p", "member": "ana"}]}, open(f"{H}/hh.json", "w"))
subprocess.run([Z, "household", "bootstrap", "--home", H, "--file", f"{H}/hh.json"], check=True, capture_output=True)
import sqlite3
con = sqlite3.connect(f"{H}/zigmem.db")
con.execute("INSERT INTO persona(subject, scope, text, rev, built_ms) VALUES ('ana','person:ana','Ana codeword HERON-77',1,0)")
con.commit()
con.close()
XB = int(os.environ.get("ZIGMEM_PROXY_PORT_BASE", "18187"))  # merge lane 10/13: hub XB, proxy XB+1, upstream XB+2; default unchanged
srv = http.server.ThreadingHTTPServer(("127.0.0.1", XB + 2), Up)
threading.Thread(target=srv.serve_forever, daemon=True).start()
p = subprocess.Popen([Z, "serve", "--home", H, "--port", str(XB), "--proxy-upstream", f"http://127.0.0.1:{XB + 2}", "--proxy-port", str(XB + 1)],
                     stdout=open(f"{SCR}/serve.log", "w"), stderr=subprocess.STDOUT)
time.sleep(1.5)
body = json.dumps({"model": "m", "messages": [{"role": "system", "content": "s"}, {"role": "user", "content": "hi"}]})


def post(headers):
    c = http.client.HTTPConnection("127.0.0.1", XB + 1, timeout=10)
    c.request("POST", "/v1/chat/completions", body=body, headers={"Content-Type": "application/json", **headers})
    r = c.getresponse()
    r.read()
    c.close()
    return r.status


rows = {}
try:
    rows["no token → 401"] = post({"x-zigmem-session": "a"}) == 401
    rows["wrong token → 401"] = post({"Authorization": "Bearer zm_" + "1" * 64}) == 401
    rows["upstream saw nothing for the refused requests"] = len(SEEN) == 0
    rows["seat token → forwarded 200"] = post({"Authorization": f"Bearer {tok}", "x-zigmem-session": "b"}) == 200
    rows["the seat's block was injected"] = len(SEEN) == 1 and "HERON-77" in SEEN[0]["body"]
    rows["the token never reached the upstream"] = len(SEEN) == 1 and SEEN[0]["auth"] is None and tok not in SEEN[0]["body"]
finally:
    p.send_signal(signal.SIGTERM)
    p.wait(10)
    srv.shutdown()
ok = all(rows.values())
os.makedirs(REC, exist_ok=True)
json.dump({"rows": rows, "pid_gone": p.poll() is not None, "ok": ok}, open(f"{REC}/proxy_probe.json", "w"), indent=1)
for k, v in rows.items():
    print("ok  " if v else "FAIL", k)
print("GATE proxy_probe", "GREEN" if ok else "RED")
sys.exit(0 if ok else 1)
