#!/usr/bin/env python3
"""serve --proxy-upstream: the phase-0 proxy inside the hub binary, its block from the store's frozen_blocks.
Local echo upstream only (no engine). Checks: block injected after the system message, byte-identical across turns
of one session, frozen even after the persona changes mid-session, a new session picks up the new persona."""
import http.client, http.server, json, os, sqlite3, sys, threading, time
sys.path.insert(0, os.path.dirname(__file__))
import gates as g

seen = []


class Echo(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        seen.append(body)
        out = b'{"ok":true}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


up = http.server.ThreadingHTTPServer(("127.0.0.1", 18142), Echo)
threading.Thread(target=up.serve_forever, daemon=True).start()
home = g.fresh_home("proxy")
g.token_add(home, "seat-p", "syn-p", "--writes", "--trusted")
p = g.start(home, 18157, "--proxy-upstream", "http://127.0.0.1:18142", "--proxy-port", "18141", "--proxy-seat", "seat-p")
db = os.path.join(home, "zigmem.db")


def persona(text):
    con = sqlite3.connect(db)
    con.execute("INSERT INTO persona(subject, scope, text, rev, built_ms) VALUES ('ana','syn-p',?,1,0) "
                "ON CONFLICT(subject, scope) DO UPDATE SET text = excluded.text, rev = rev + 1", (text,))
    con.commit()
    con.close()


def chat(session, user):
    c = http.client.HTTPConnection("127.0.0.1", 18141, timeout=10)
    body = json.dumps({"model": "m", "messages": [{"role": "system", "content": "sys"}, {"role": "user", "content": user}]})
    c.request("POST", "/v1/chat/completions", body=body, headers={"Content-Type": "application/json", "x-zigmem-session": session})
    r = c.getresponse()
    r.read()
    c.close()
    return json.loads(seen[-1])["messages"]


persona("Ana keeps the lantern in the blue shed.")
m1 = chat("s1", "hi")
m2 = chat("s1", "again")
persona("Ana moved the lantern to the red barn.")
m3 = chat("s1", "third")
m4 = chat("s2", "new session")
rows = {
    "block at index 1 after system": m1[1]["role"] == "system" and "<memory>" in m1[1]["content"] and m1[0]["content"] == "sys",
    "s1 turn 2 byte-identical": json.dumps(m1[1]) == json.dumps(m2[1]),
    "s1 frozen after persona change": json.dumps(m1[1]) == json.dumps(m3[1]) and "blue shed" in m3[1]["content"],
    "s2 gets the new persona": "red barn" in m4[1]["content"],
    "user turns untouched": m1[2] == {"role": "user", "content": "hi"} and m4[2]["content"] == "new session",
}
g.stop(p)
up.shutdown()
for k, v in rows.items():
    print(("ok  " if v else "FAIL"), k)
g.receipt("proxy_mode", {"rows": rows, "block_s1": m1[1]["content"], "stops": g.STOPS})
print("GATE proxy_mode", "GREEN" if all(rows.values()) else "RED")
sys.exit(0 if all(rows.values()) else 1)
