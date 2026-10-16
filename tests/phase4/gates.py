#!/usr/bin/env python3
"""zigmem phase-4 gates (stdlib only, synthetic data only). Each gate starts its own server on a test port, stops it
by PID and asserts the PID is gone. Usage: gates.py auth|bind|fuzz|latency|crash|extract [args]. Receipts go to
receipts/phase4/<gate>.json; the exit code is 0 only when the gate is GREEN."""
import http.client, json, os, random, signal, socket, sqlite3, subprocess, sys, threading, time

ROOT = os.path.expanduser("~/zigmem")
Z = os.environ.get("ZIGMEM_BIN", os.path.join(ROOT, "zig-out/bin/zigmem"))
SCR = os.path.join(ROOT, "scratch/p4")
REC = os.path.join(ROOT, "receipts/phase4")
os.makedirs(SCR, exist_ok=True)
os.makedirs(REC, exist_ok=True)
STOPS = []


def fresh_home(name):
    h = os.path.join(SCR, name)
    subprocess.run(["rm", "-rf", h], check=True)
    return h


def token_add(home, seat, scopes, *flags, person=None):
    cmd = [Z, "token", "add", "--home", home, "--seat", seat, "--scopes", scopes] + list(flags)
    if person:
        cmd += ["--person", person]
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()


def start(home, port, *extra):
    log = open(os.path.join(home, f"serve_{port}.log"), "ab")
    p = subprocess.Popen([Z, "serve", "--home", home, "--port", str(port)] + list(extra), stdout=log, stderr=log)
    for _ in range(100):
        try:
            if req(port, "GET", "/health")[0] == 200:
                return p
        except OSError:
            pass
        if p.poll() is not None:
            raise RuntimeError(f"server exited rc={p.returncode}")
        time.sleep(0.05)
    raise RuntimeError("server did not come up")


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # a zombie child still answers kill(0); reap check
    try:
        st = open(f"/proc/{pid}/stat").read().split()[2]
        return st != "Z"
    except FileNotFoundError:
        return False


def stop(p, sig=signal.SIGTERM):
    os.kill(p.pid, sig)
    try:
        p.wait(10)
    except subprocess.TimeoutExpired:
        pass
    gone = not alive(p.pid)
    STOPS.append({"pid": p.pid, "signal": int(sig), "gone": gone})
    assert gone, f"pid {p.pid} still alive"
    return gone


def req(port, method, path, body=None, token=None, headers=None, raw=None, timeout=15):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    h = dict(headers or {})
    if token is not None:
        h["Authorization"] = f"Bearer {token}"
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    if data is not None:
        h.setdefault("Content-Type", "application/json")
    c.request(method, path, body=data, headers=h)
    r = c.getresponse()
    out = r.read()
    c.close()
    return r.status, out


def jreq(*a, **k):
    st, b = req(*a, **k)
    try:
        return st, json.loads(b) if b else None
    except ValueError:
        return st, b


def insert_atom(db, scope, subject, text):
    """Synthetic atom rows for read-side tests (extraction is gated separately)."""
    con = sqlite3.connect(db, timeout=10)
    cur = con.execute("INSERT INTO atoms(lineage, subject, scope, type, priority, text, recorded_ms, status, sha256) "
                      "VALUES (?,?,?,?,?,?,?,?,?)", ("Lsyn" + str(random.random()), subject, scope, "fact", 50, text,
                                                    int(time.time() * 1000), "active", os.urandom(32)))
    con.commit()
    rid = cur.lastrowid
    con.close()
    return rid


def receipt(name, obj):
    with open(os.path.join(REC, name + ".json"), "w") as f:
        json.dump(obj, f, indent=1)


# ---------------------------------------------------------------- auth matrix
POST_ROUTES = ["/recall", "/v1/recall", "/capture", "/v1/capture", "/search/memories", "/v1/search/memories",
               "/search/conversations", "/v1/search/conversations", "/session/end", "/v1/session/end",
               "/v1/session/block", "/v1/atoms/get", "/v1/atoms/list", "/v1/atoms/supersede", "/v1/atoms/demote",
               "/v3/conversation/add", "/v3/conversation/search", "/v3/atomic/search", "/v3/atomic/delete",
               "/admin/retire", "/seed", "/mcp", "/no/such/route"]


def gate_auth():
    port = 18150
    home = fresh_home("auth")
    T = {
        "A": token_add(home, "seat-a", "syn-a,syn-shared", "--writes", person="ana"),
        "B": token_add(home, "seat-b", "syn-b", "--writes", "--trusted", person="ben"),
        "R": token_add(home, "seat-r", "syn-a"),
        "ADM": token_add(home, "seat-admin", "syn-admin", "--admin"),
        "C": token_add(home, "seat-c", "syn-a", "--writes"),
    }
    p = start(home, port)
    db = os.path.join(home, "zigmem.db")
    rows = []

    def check(name, got, want, extra=True):
        ok = (got == want) and bool(extra)
        rows.append({"case": name, "got": got, "want": want, "ok": ok})
        if not ok:
            print("FAIL", name, got, want)

    # seed (synthetic)
    st, b = jreq(port, "POST", "/v1/capture", {"user_content": "Ben stores the kayak paddles in the garage loft.", "session_key": "s"}, T["B"])
    check("seed capture B", st, 200)
    st, b = jreq(port, "POST", "/v1/capture", {"user_content": "Ana keeps the lantern in the blue shed.", "session_key": "s"}, T["A"])
    check("seed capture A", st, 200)
    atom_a = insert_atom(db, "syn-a", "ana", "Ana keeps the lantern in the blue shed.")
    atom_b = insert_atom(db, "syn-b", "ben", "Ben stores the kayak paddles in the garage loft.")
    body_ok = {"query": "lantern", "session_key": "s", "user_content": "x", "id": atom_a, "text": "t", "messages": [{"role": "user", "content": "x"}], "session_id": "s"}

    # 1. no token / malformed / wrong token on every protected route → 401
    rnd = "zm_" + os.urandom(32).hex()
    for r in POST_ROUTES:
        check(f"no token {r}", req(port, "POST", r, body_ok)[0], 401)
        check(f"basic auth {r}", req(port, "POST", r, body_ok, headers={"Authorization": "Basic " + T["A"]})[0], 401)
        check(f"empty bearer {r}", req(port, "POST", r, body_ok, headers={"Authorization": "Bearer "})[0], 401)
        check(f"wrong token {r}", req(port, "POST", r, body_ok, token=rnd)[0], 401)
        check(f"token w/o prefix {r}", req(port, "POST", r, body_ok, token=T["A"][3:])[0], 401)
        check(f"token + junk {r}", req(port, "POST", r, body_ok, token=T["A"] + "x")[0], 401)
    check("GET /mcp no token", req(port, "GET", "/mcp")[0], 401)
    check("health no token", req(port, "GET", "/health")[0], 200)

    # 2. another seat's data / scopes: A cannot reach syn-b
    for r in ["/v1/search/memories", "/v1/search/conversations", "/v1/recall", "/v3/atomic/search", "/v1/atoms/list"]:
        check(f"A asks scope syn-b {r}", req(port, "POST", r, {"query": "kayak", "scope": "syn-b"}, T["A"])[0], 403)
        check(f"A asks scopes [syn-a,syn-b] {r}", req(port, "POST", r, {"query": "kayak", "scopes": ["syn-a", "syn-b"]}, T["A"])[0], 403)
    st, b = jreq(port, "POST", "/v1/atoms/get", {"id": atom_b}, T["A"])
    check("A get B's atom → 404", st, 404)
    check("A supersede B's atom → 404", req(port, "POST", "/v1/atoms/supersede", {"id": atom_b, "text": "Ben moved the paddles."}, T["A"])[0], 404)
    check("A demote B's atom → 404", req(port, "POST", "/v1/atoms/demote", {"id": atom_b}, T["A"])[0], 404)
    check("A capture into syn-b → 403", req(port, "POST", "/v1/capture", {"user_content": "x", "session_key": "s", "scope": "syn-b"}, T["A"])[0], 403)
    st, b = jreq(port, "POST", "/v1/atoms/get", {"id": atom_a}, T["A"])
    check("A get own atom", st, 200, b and b["atom"]["subject"] == "ana")

    # 3. impersonation: forged identity headers + body ids are ignored
    forged = {"x-vendor-user-id": "seat-b", "x-vendor-service-id": "seat-b", "x-vendor-agent-id": "seat-b", "x-zigmem-seat": "seat-b"}
    st, b = jreq(port, "POST", "/v1/search/conversations", {"query": "kayak paddles", "user_id": "seat-b", "seat": "seat-b", "agent_id": "x"}, T["A"], headers=forged)
    check("forged identity search sees only own scope", st, 200, b["total"] == 0)
    st, b = jreq(port, "POST", "/v1/search/memories", {"query": "kayak paddles", "user_id": "seat-b"}, T["A"], headers=forged)
    check("forged identity atom search sees only own scope", st, 200, b["total"] == 0)
    st, b = jreq(port, "POST", "/v1/capture", {"user_content": "Ana waters the fern on Sundays.", "session_key": "imp", "seat": "seat-b", "user_id": "seat-b", "session_id": "seat-b/s"}, T["A"], headers=forged)
    con = sqlite3.connect(db)
    row = con.execute("SELECT seat, session_id, scope FROM l0 WHERE id = ?", (b["ids"][0],)).fetchone()
    con.close()
    check("forged capture lands as seat-a", st, 200, row == ("seat-a", "seat-a/imp", "syn-a"))
    st, b = jreq(port, "POST", "/v1/search/conversations", {"query": "lantern", "session_key": "s"}, T["B"])
    check("B cannot read A's session by key", st, 200, b["total"] == 0)

    # 4. read-only seat: every write → 403
    for r, body in [("/v1/capture", {"user_content": "x", "session_key": "s"}), ("/capture", {"user_content": "x", "session_key": "s"}),
                    ("/v3/conversation/add", {"session_id": "s", "messages": [{"role": "user", "content": "x"}]}),
                    ("/v1/session/end", {"session_key": "s"}), ("/v1/atoms/supersede", {"id": atom_a, "text": "y"}),
                    ("/v1/atoms/demote", {"id": atom_a})]:
        check(f"read-only R {r}", req(port, "POST", r, body, T["R"])[0], 403)
    check("read-only R can search", req(port, "POST", "/v1/search/memories", {"query": "lantern"}, T["R"])[0], 200)

    # 5. admin-only routes
    for r in ["/admin/retire", "/v3/atomic/delete"]:
        for s in ["A", "B", "R"]:
            check(f"non-admin {s} {r}", req(port, "POST", r, {"id": atom_a}, T[s])[0], 403)
    con = sqlite3.connect(db)
    n0 = con.execute("SELECT count(*) FROM atoms").fetchone()[0]
    st, b = jreq(port, "POST", "/v3/atomic/delete", {"id": atom_b}, T["ADM"])
    st2 = con.execute("SELECT status FROM atoms WHERE id = ?", (atom_b,)).fetchone()
    n1 = con.execute("SELECT count(*) FROM atoms").fetchone()[0]
    con.close()
    check("admin delete = retire, row kept", st, 200, st2 == ("retired",) and n0 == n1 and b["deleted"] == 0)

    # 6. privacy screen: untrusted A refused on family/medical/money text; trusted B allowed
    for t in ["Morgan's surgery is on Tuesday", "the girls have a fever", "sell 40k shares of the stock", "call 202-555-0100", "the ETF dropped"]:
        check(f"untrusted A screened: {t[:20]}", req(port, "POST", "/v1/capture", {"user_content": t, "session_key": "p"}, T["A"])[0], 403)
    check("trusted B not screened", req(port, "POST", "/v1/capture", {"user_content": "Morgan's surgery is on Tuesday", "session_key": "p"}, T["B"])[0], 200)
    check("untrusted A supersede screened", req(port, "POST", "/v1/atoms/supersede", {"id": atom_a, "text": "Morgan keeps the lantern"}, T["A"])[0], 403)
    con = sqlite3.connect(db)
    leaked = con.execute("SELECT count(*) FROM l0 WHERE seat = 'seat-a' AND (text LIKE '%surgery%' OR text LIKE '%fever%' OR text LIKE '%shares%')").fetchone()[0]
    con.close()
    check("screened text never written", leaked, 0)

    # 7. MCP auth
    call = lambda name, args, i=1: {"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": name, "arguments": args}}
    check("MCP no token", req(port, "POST", "/mcp", call("memory_search", {"query": "kayak"}))[0], 401)
    st, b = jreq(port, "POST", "/mcp", call("memory_search", {"query": "kayak paddles", "include_turns": True, "seat": "seat-b", "scope": "syn-b"}), T["A"], headers=forged)
    inner = json.loads(b["result"]["content"][0]["text"])
    check("MCP A search sees no B data (forged args dropped)", st, 200, inner["hits"] == [] and inner["turns"] == [])
    st, b = jreq(port, "POST", "/mcp", call("memory_add", {"text": "Ana fixed the gate latch."}), T["R"])
    check("MCP read-only add refused", st, 200, b["result"]["isError"] is True)
    st, b = jreq(port, "POST", "/mcp", call("memory_add", {"text": "Rowan has a dentist visit"}), T["A"])
    check("MCP untrusted family add refused", st, 200, b["result"]["isError"] is True and "privacy" in b["result"]["content"][0]["text"])
    st, b = jreq(port, "POST", "/mcp", call("memory_get", {"id": atom_b}), T["A"])
    check("MCP A get B's atom refused", st, 200, b["result"]["isError"] is True)

    # 8. live revocation (no restart) + fail-closed token file
    check("C works before revoke", req(port, "POST", "/v1/search/memories", {"query": "lantern"}, T["C"])[0], 200)
    subprocess.run([Z, "token", "revoke", "--home", home, "--seat", "seat-c"], check=True, capture_output=True)
    for r in ["/v1/search/memories", "/v1/capture", "/mcp"]:
        check(f"C revoked {r}", req(port, "POST", r, {"query": "lantern", "user_content": "x", "session_key": "s"}, T["C"])[0], 401)
    check("A still works after C revoked", req(port, "POST", "/v1/search/memories", {"query": "lantern"}, T["A"])[0], 200)
    os.chmod(os.path.join(home, "tokens"), 0o644)
    check("token file 0644 → fail closed", req(port, "POST", "/v1/search/memories", {"query": "lantern"}, T["A"])[0], 401)
    os.chmod(os.path.join(home, "tokens"), 0o600)
    check("token file 0600 again → works", req(port, "POST", "/v1/search/memories", {"query": "lantern"}, T["A"])[0], 200)
    # token at rest: never in the file, only its hash
    tf = open(os.path.join(home, "tokens")).read()
    check("no token stored in clear", sum(t in tf for t in T.values()), 0)
    check("token file mode 0600", oct(os.stat(os.path.join(home, "tokens")).st_mode & 0o777), "0o600")

    # audit: every call has a line, the real seat, no argument text
    lines = [json.loads(x) for x in open(os.path.join(home, "audit.log"))]
    check("audit: forged calls recorded as seat-a with ignored_identity", any(l["seat"] == "seat-a" and l.get("ignored_identity") for l in lines), True)
    alltext = open(os.path.join(home, "audit.log")).read()
    check("audit holds no request text", ("lantern" in alltext) or ("kayak" in alltext) or ("surgery" in alltext), False)
    stop(p)
    npass = sum(r["ok"] for r in rows)
    receipt("auth", {"rows": rows, "pass": npass, "total": len(rows), "audit_lines": len(lines), "stops": STOPS})
    print(f"AUTH {npass}/{len(rows)}")
    return npass == len(rows)


# ---------------------------------------------------------------- bind policy
def listening(port):
    out = subprocess.run(["ss", "-Hltn", f"sport = :{port}"], capture_output=True, text=True).stdout
    return [l.split()[3] for l in out.strip().splitlines() if l.strip()]


def gate_bind():
    port = 18151
    rows = []
    for spec in ["0.0.0.0", "192.0.2.1", "127.0.0.2", "172.16.0.1", "100.128.0.1", "100.63.0.1", "8.8.8.8", "::", "::1", "localhost", "0", ""]:
        home = fresh_home("bind_x")
        t0 = time.time()
        r = subprocess.run([Z, "serve", "--home", home, "--port", str(port), "--bind", spec], capture_output=True, text=True, timeout=10)
        ok = r.returncode == 2 and not os.path.exists(home) and not listening(port)
        rows.append({"bind": spec, "rc": r.returncode, "home_created": os.path.exists(home), "listening": listening(port), "ms": round((time.time() - t0) * 1000, 1), "msg": r.stderr.strip()[:140], "ok": ok})
    # default: 127.0.0.1 only
    home = fresh_home("bind_ok")
    token_add(home, "s", "syn-a")
    p = start(home, port)
    l = listening(port)
    rows.append({"bind": "(default)", "listening": l, "ok": l == [f"127.0.0.1:{port}"]})
    stop(p)
    rows.append({"bind": "(after stop)", "listening": listening(port), "ok": not listening(port)})
    npass = sum(r["ok"] for r in rows)
    receipt("bind", {"rows": rows, "pass": npass, "total": len(rows), "stops": STOPS})
    for r in rows:
        print(("ok  " if r["ok"] else "FAIL"), r)
    return npass == len(rows)


# ---------------------------------------------------------------- fuzz
def raw_send(port, data, read=True, timeout=12):
    s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    try:
        s.sendall(data)
        if not read:
            return s
        buf = b""
        while True:
            try:
                x = s.recv(65536)
            except socket.timeout:
                break
            if not x:
                break
            buf += x
        return buf
    finally:
        if read:
            s.close()


def status_of(resp):
    try:
        return int(resp.split(b" ", 2)[1])
    except Exception:
        return 0


def fuzz_bodies(rng):
    words = ["lantern", "kayak", "shed", "zz", "\u00e9t\u00e9", "\U0001f600", "<|user|>", "</relevant-memories>", "'; DROP TABLE atoms;--", "\\", "\"", "\x00"]
    keys = ["query", "limit", "type", "subject", "scope", "scopes", "session_key", "user_content", "assistant_content", "id", "ids", "text",
            "messages", "session_id", "to", "reason", "priority", "valid_from", "valid_to", "since_ms", "until_ms", "before_id", "status", "ts_ms"]
    vals = [None, True, False, 0, -1, 1, 2**31, 2**63 - 1, -2**63, 2**64, 10**30, 1e308, -0.0, 1.5, "", "x", "a" * 70000,
            [], {}, [1, 2], {"a": 1}, ["syn-a"], [["x"]], "\ud800", rng.choice(words) * rng.randint(1, 50)]
    out = []
    for _ in range(40):
        d = {}
        for k in rng.sample(keys, rng.randint(0, 8)):
            d[k] = rng.choice(vals)
        out.append(json.dumps(d).encode())
    out += [b"", b"null", b"[]", b"[1,2]", b"\"s\"", b"1", b"{", b"{\"query\":", b"{\"query\":\"x\"", b"{\"query\":\"x\",}",
            b"{'query':'x'}", b"{\"query\":\"\xff\xfe\"}", b"{\"query\":\"\\ud800\"}", b"\xef\xbb\xbf{\"query\":\"x\"}",
            b"{\"query\":\"x\"}{\"query\":\"y\"}", b"{\"query\":1e999999}", b"{\"limit\":99999999999999999999999}",
            b"{\"query\":\"x\",\"query\":7}", b"[" * 200000, b"{\"a\":" * 80000 + b"1" + b"}" * 80000, b"[" * 500000,
            b"{\"query\":\"" + b"a" * 510000 + b"\"}", os.urandom(4096), b"\x00" * 1000,
            b"{\"messages\":[" + b",".join([b"{\"role\":\"user\",\"content\":\"x\"}"] * 70) + b"],\"session_id\":\"s\"}"]
    return out


def gate_fuzz():
    port = 18152
    home = fresh_home("fuzz")
    tok_w = token_add(home, "seat-w", "syn-a", "--writes", "--trusted", person="ana")
    tok_r = token_add(home, "seat-r", "syn-a")
    tok_adm = token_add(home, "seat-adm", "syn-a", "--admin", "--writes", "--trusted")
    p = start(home, port)
    rng = random.Random(4)
    counts = {}
    sent = 0
    deaths = 0

    def note(st):
        counts[st] = counts.get(st, 0) + 1

    routes = POST_ROUTES + ["/health", "/" + "a" * 3000, "/v1/../admin/retire", "/v1/search/memories?x=1"]
    for rnd in range(6):
        for body in fuzz_bodies(rng):
            for r in rng.sample(routes, 8):
                tok = rng.choice([tok_w, tok_r, tok_adm, None])
                try:
                    st, _ = req(port, rng.choice(["POST", "POST", "GET", "PUT", "DELETE"]), r, raw=body, token=tok, timeout=20)
                except (OSError, http.client.HTTPException) as e:
                    st = f"exc:{type(e).__name__}"
                note(st)
                sent += 1
            if not alive(p.pid):
                deaths += 1
                break
    # MCP-specific garbage
    mcp_msgs = [b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_search\",\"arguments\":{\"query\":\"x\",\"limit\":" + v + b"}}}" for v in [b"0", b"21", b"-5", b"1e300", b"\"5\"", b"null", b"[]", b"9223372036854775808"]]
    mcp_msgs += [b"{\"jsonrpc\":\"2.0\",\"id\":" + i + b",\"method\":\"ping\"}" for i in [b"null", b"{}", b"[]", b"1.5", b"\"" + b"i" * 300 + b"\"", b"99999999999999999999999"]]
    mcp_msgs += [b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"" + m + b"\"}" for m in [b"tools/call", b"initialize", b"resources/read", b"x" * 500, b"notifications/x"]]
    mcp_msgs += [b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":" + pp + b"}" for pp in [b"[]", b"1", b"{\"name\":7}", b"{\"name\":\"memory_get\",\"arguments\":{\"id\":0}}", b"{\"name\":\"memory_get\",\"arguments\":{\"id\":-1}}", b"{\"name\":\"memory_block\",\"arguments\":{\"session_key\":\"\\u0001\"}}", b"{\"name\":\"memory_add\",\"arguments\":{\"text\":\"" + b"z" * 20000 + b"\"}}"]]
    for m in mcp_msgs * 3:
        try:
            st, _ = req(port, "POST", "/mcp", raw=m, token=rng.choice([tok_w, tok_r]))
        except (OSError, http.client.HTTPException) as e:
            st = f"exc:{type(e).__name__}"
        note(("mcp", st))
        sent += 1
    # protocol abuse on raw sockets
    abuse = [b"GARBAGE\r\n\r\n", b"GET\r\n\r\n", b"GET / HTTP/2.0\r\n\r\n", b"POST /v1/recall HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
             b"POST /v1/recall HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello",
             b"POST /v1/recall HTTP/1.1\r\nContent-Length: 10000000\r\n\r\n", b"POST /v1/recall HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
             b"POST /v1/recall HTTP/1.1\r\nX: " + b"a" * 20000 + b"\r\n\r\n", b"POST /v1/recall HTTP/1.1\r\n" + b"H: v\r\n" * 100 + b"\r\n",
             b"POST /v1/recall HTTP/1.1\r\nnocolon\r\n\r\n", b"POST /v1/recall HTTP/1.1\r\n: v\r\n\r\n", b"\r\n\r\n", b"\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03" + os.urandom(64),
             b"POST /v1/recall HTTP/1.1\r\nContent-Length: 18446744073709551616\r\n\r\n", b"POST /v1/recall HTTP/1.1\r\nAuthorization: Bearer " + b"z" * 10000 + b"\r\nContent-Length: 2\r\n\r\n{}"]
    for a in abuse * 2:
        try:
            note(("raw", status_of(raw_send(port, a))))
        except OSError as e:
            note(("raw", f"exc:{type(e).__name__}"))
        sent += 1
    # short body (client closes early) and slowloris over the connection cap
    s = raw_send(port, b"POST /v1/recall HTTP/1.1\r\nContent-Length: 100\r\n\r\n{\"q", read=False)
    s.close()
    slow = [raw_send(port, b"POST /v1/recall HTTP/1.1\r\n", read=False) for _ in range(80)]
    time.sleep(0.5)
    st_busy = req(port, "GET", "/health")[0] if True else 0
    note(("slowloris_health", st_busy))
    for x in slow:
        x.close()
    time.sleep(0.5)
    st_after = req(port, "GET", "/health")[0]
    note(("after_slowloris_health", st_after))
    log = open(os.path.join(home, f"serve_{port}.log"), "rb").read()
    panics = log.count(b"panic")
    ok = alive(p.pid) and deaths == 0 and panics == 0 and st_after == 200
    con = sqlite3.connect(os.path.join(home, "zigmem.db"))
    integ = con.execute("PRAGMA integrity_check").fetchone()[0]
    con.close()
    stop(p)
    res = {"sent": sent, "deaths": deaths, "panics_in_log": panics, "health_after": st_after, "health_during_slowloris": st_busy,
           "integrity": integ, "status_counts": {str(k): v for k, v in sorted(counts.items(), key=lambda kv: str(kv[0]))}, "stops": STOPS}
    receipt("fuzz", res)
    print(json.dumps(res, indent=1))
    return ok and integ == "ok"


# ---------------------------------------------------------------- latency
def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * (len(xs) - 1)))]


def gate_latency(n_atoms="100000"):
    port = 18153
    home = fresh_home("lat")
    os.makedirs(home, mode=0o700)
    db = os.path.join(home, "zigmem.db")
    t0 = time.time()
    bench = subprocess.run([os.path.join(ROOT, "zig-out/bin/zigmem-storebench"), "perf", db, n_atoms], capture_output=True, text=True)
    build_s = time.time() - t0
    tok = token_add(home, "seat-l", "syn-a,syn-b")
    con = sqlite3.connect(db)
    texts = [r[0] for r in con.execute("SELECT text FROM atoms ORDER BY random() LIMIT 400")]
    natoms = con.execute("SELECT count(*) FROM atoms").fetchone()[0]
    con.close()
    rng = random.Random(9)
    qs = []
    for t in texts:
        w = t.split()[2:]
        qs.append(" ".join(rng.sample(w, min(len(w), rng.randint(2, 3)))))
    p = start(home, port)
    for q in qs[:50]:  # warm-up (page cache, reader pool)
        req(port, "POST", "/v1/search/memories", {"query": q, "limit": 10}, tok)
    seq = []
    hits = 0
    for i in range(1000):
        q = qs[i % len(qs)]
        t = time.perf_counter()
        st, b = req(port, "POST", "/v1/search/memories", {"query": q, "limit": 10}, tok)
        seq.append((time.perf_counter() - t) * 1000)
        assert st == 200, (st, b)
        hits += json.loads(b)["total"] > 0
    conc = []
    lock = threading.Lock()

    def worker(k):
        mine = []
        for i in range(250):
            q = qs[(k * 250 + i) % len(qs)]
            t = time.perf_counter()
            st, _ = req(port, "POST", "/v1/search/memories", {"query": q, "limit": 10}, tok)
            mine.append((time.perf_counter() - t) * 1000)
            assert st == 200
        with lock:
            conc.extend(mine)
    th = [threading.Thread(target=worker, args=(k,)) for k in range(8)]
    tc = time.perf_counter()
    [x.start() for x in th]
    [x.join() for x in th]
    wall = time.perf_counter() - tc
    server_ms = [json.loads(l)["ms"] for l in open(os.path.join(home, "audit.log")) if '"/v1/search/memories"' in l]
    stop(p)
    res = {"atoms": natoms, "db_build_s": round(build_s, 1), "storebench_rc": bench.returncode, "queries_with_hits": hits,
           "sequential_ms": {"n": len(seq), "p50": round(pct(seq, .5), 2), "p95": round(pct(seq, .95), 2), "p99": round(pct(seq, .99), 2), "max": round(max(seq), 2)},
           "concurrent8_ms": {"n": len(conc), "p50": round(pct(conc, .5), 2), "p95": round(pct(conc, .95), 2), "p99": round(pct(conc, .99), 2), "max": round(max(conc), 2), "qps": round(len(conc) / wall, 1)},
           "server_side_ms": {"n": len(server_ms), "p50": round(pct(server_ms, .5), 2), "p95": round(pct(server_ms, .95), 2)}, "stops": STOPS}
    receipt("latency", res)
    print(json.dumps(res, indent=1))
    return res["sequential_ms"]["p95"] <= 10 and res["concurrent8_ms"]["p95"] <= 25


# ---------------------------------------------------------------- kill -9 durability
def gate_crash(rounds="10"):
    port = 18154
    home = fresh_home("crash")
    tok = token_add(home, "seat-w", "syn-a", "--writes", "--trusted")
    db = os.path.join(home, "zigmem.db")
    out = []
    total_acked = 0
    total_missing = 0
    for r in range(int(rounds)):
        p = start(home, port)
        acked = []
        lock = threading.Lock()
        stop_flag = threading.Event()

        def client(t):
            n = 0
            while not stop_flag.is_set():
                text = f"syn crash r{r} t{t} n{n} " + " ".join(random.choice(["kal", "vor", "min", "dus", "pel"]) for _ in range(6))
                try:
                    st, b = jreq(port, "POST", "/v1/capture", {"user_content": text, "session_key": f"r{r}t{t}"}, tok, timeout=5)
                except (OSError, http.client.HTTPException):
                    return
                if st == 200:
                    with lock:
                        acked.append((b["ids"][0], text))
                n += 1
        th = [threading.Thread(target=client, args=(t,)) for t in range(8)]
        [x.start() for x in th]
        time.sleep(random.uniform(0.5, 2.0))
        os.kill(p.pid, signal.SIGKILL)
        p.wait()
        STOPS.append({"pid": p.pid, "signal": 9, "gone": not alive(p.pid)})
        stop_flag.set()
        [x.join() for x in th]
        con = sqlite3.connect(db)
        integ = con.execute("PRAGMA integrity_check").fetchone()[0]
        con.execute("INSERT INTO l0_fts(l0_fts, rank) VALUES ('integrity-check', 1)")
        missing = 0
        for rid, text in acked:
            row = con.execute("SELECT text, seat FROM l0 WHERE id = ?", (rid,)).fetchone()
            if row != (text, "seat-w"):
                missing += 1
        rows = con.execute("SELECT count(*) FROM l0").fetchone()[0]
        con.close()
        total_acked += len(acked)
        total_missing += missing
        out.append({"round": r, "acked": len(acked), "missing_or_altered": missing, "integrity": integ, "fts_integrity": "ok", "l0_rows_total": rows, "pid_gone": STOPS[-1]["gone"]})
        print(out[-1])
    # the server comes back on the same file
    p = start(home, port)
    st, b = jreq(port, "GET", "/health")
    stop(p)
    res = {"rounds": out, "acked_total": total_acked, "missing_total": total_missing, "restart_health": st, "rows_after": b["rows"], "stops": STOPS}
    receipt("crash", res)
    return total_missing == 0 and all(o["integrity"] == "ok" for o in out) and st == 200


# ---------------------------------------------------------------- extraction worker (the primary engine, ≤2 concurrent)
TURNS = [
    "Ana keeps the spare bike pump in the hall closet.",
    "Ben's chess club meets on Thursdays at the library.",
    "Ana is allergic to walnuts.",
    "Ben prefers tea with honey, not sugar.",
    "Ana's violin lesson moved to Mondays.",
    "Ben is saving up for a telescope.",
    "Ana planted tomatoes along the back fence.",
    "Ben's bus pass expires at the end of November.",
]


def gate_extract(workers="2"):
    port = 18155
    home = fresh_home("extract")
    tok = token_add(home, "seat-x", "syn-x", "--writes", "--trusted", person="ana")
    for pid_, al in [("ana", "Ana"), ("ben", "Ben")]:
        subprocess.run([Z, "people", "add", "--home", home, "--id", pid_, "--aliases", al], check=True, capture_output=True)
    p = start(home, port, "--extract", "primary", "--workers", workers)
    samples = []
    stop_s = threading.Event()

    def sampler():
        while not stop_s.is_set():
            o = subprocess.run(["ss", "-Htnp"], capture_output=True, text=True).stdout
            mine = [l for l in o.splitlines() if f"pid={p.pid}," in l]
            peers = [l.split()[4] for l in mine]
            eng = sum(1 for x in peers if x == "127.0.0.1:18080")
            other = [x for x in peers if x != "127.0.0.1:18080" and not x.startswith("127.0.0.1:")]
            try:
                h = jreq(port, "GET", "/health")[1]["extract"]
            except Exception:
                h = {}
            samples.append({"t": round(time.time(), 2), "engine_conns": eng, "other_peers": other, "inflight": h.get("inflight"), "queued": h.get("queued"), "running": h.get("running")})
            time.sleep(0.2)
    th = threading.Thread(target=sampler)
    th.start()
    t0 = time.time()
    for i, t in enumerate(TURNS):
        st, b = jreq(port, "POST", "/v1/capture", {"user_content": t, "session_key": f"x{i % 3}"}, tok)
        assert st == 200 and b["scheduler_notified"], (st, b)
    while time.time() - t0 < 600:
        h = jreq(port, "GET", "/health")[1]["extract"]
        if h["queued"] == 0 and h["running"] == 0:
            break
        time.sleep(1)
    elapsed = time.time() - t0
    stop_s.set()
    th.join()
    health = jreq(port, "GET", "/health")[1]
    stop(p)
    con = sqlite3.connect(os.path.join(home, "zigmem.db"))
    atoms = [dict(zip(["id", "subject", "status", "text", "run_id", "extractor", "prompt_sha"], r)) for r in
             con.execute("SELECT id, subject, status, text, run_id, extractor, prompt_sha IS NOT NULL FROM atoms ORDER BY id")]
    jobs = dict(con.execute("SELECT state, count(*) FROM jobs GROUP BY state").fetchall())
    con.close()
    res = {"turns": len(TURNS), "elapsed_s": round(elapsed, 1), "jobs": jobs, "health_extract": health["extract"],
           "max_engine_conns": max(s["engine_conns"] for s in samples), "max_inflight": max((s["inflight"] or 0) for s in samples),
           "other_peers_seen": sorted({x for s in samples for x in s["other_peers"]}), "samples": len(samples),
           "atoms": atoms, "stops": STOPS}
    receipt("extract", res)
    print(json.dumps({k: v for k, v in res.items() if k != "atoms"}, indent=1))
    for a in atoms:
        print(a)
    return (res["max_engine_conns"] <= 2 and health["extract"]["inflight_max"] <= 2 and not res["other_peers_seen"]
            and jobs.get("done", 0) == len(TURNS) and all(a["run_id"].startswith("api-w") and a["prompt_sha"] for a in atoms))


if __name__ == "__main__":
    g = sys.argv[1]
    ok = globals()["gate_" + g](*sys.argv[2:])
    print("GATE", g, "GREEN" if ok else "RED")
    sys.exit(0 if ok else 1)
