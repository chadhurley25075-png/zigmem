#!/usr/bin/env python3
"""INTEGRATION gate 2: the phase-5 adversarial household gate, re-run THROUGH THE REAL HTTP API with real seat tokens.

The synthetic household (zigmem-hh-fixture: 7 members incl. the guest Taylor Kessler, 9 seats, ~70 rows with per-row
ground truth, the oracle's literal per-seat read/write table and ~76 adversarial questions per seat) is loaded into a
fresh hub database; every seat gets a real token (`*`, writes, trusted, admin flag — so household POLICY, not token
flags, is what is tested). The leak oracle is re-implemented here from the fixture's ground truth (no code shared with
the server). Paths judged: /v1/search/memories (list mode), /v1/recall (memory_ids), MCP memory_search, /v1/atoms/get
for every row id, /v1/atoms/list, /v1/search/conversations over captured turns. Then the permission matrix, the
promotion/admin flows, live revocation (both phases), token-level cases (forged, CLI-revoked, unbound, narrowed), and
the audit (one xread row per cross scope read; no query text anywhere). Synthetic data only. Port 18190.
Usage: p5_api_gate.py → receipts/integration/p5/gate.json (or $ZIGMEM_REC); exit 0 only when GREEN."""
import hashlib, http.client, json, os, random, signal, sqlite3, subprocess, sys, time

ROOT = os.path.expanduser("~/zigmem")
BIN = os.environ.get("ZIGMEM_BINDIR", os.path.join(ROOT, "scratch/integ/tree/out/bin"))
Z, FIX = os.path.join(BIN, "zigmem"), os.path.join(BIN, "zigmem-hh-fixture")
SCR = os.environ.get("ZIGMEM_SCR", os.path.join(ROOT, "scratch/integ/p5"))
REC = os.environ.get("ZIGMEM_REC", os.path.join(ROOT, "receipts/integration/p5"))
PORT = int(os.environ.get("ZIGMEM_PORT", "18190"))
QUICK = os.environ.get("P5_QUICK") == "1"  # mutation runs: fewer recall/get calls, every check kept
os.makedirs(REC, exist_ok=True)
HOME = os.path.join(SCR, "home")
STOPS, FAILS = [], []
C = dict(queries=0, rows_judged=0, leaks=0, forbidden_ok=0, revoked_denied=0, errors=0, matrix_cells=0, matrix_fail=0,
         flows=0, flow_fail=0, token_cases=0, token_fail=0, medical_served=0, xread_expected=0, turn_rows_judged=0,
         gets=0, lists=0, recalls=0, mcp=0, turn_queries=0)


def fail(msg):
    if len(FAILS) < 60:
        FAILS.append(msg)


def req(method, path, body=None, tok=None, timeout=60):
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=timeout)
    h = {"Content-Type": "application/json"}
    if tok:
        h["Authorization"] = f"Bearer {tok}"
    c.request(method, path, body=json.dumps(body).encode() if body is not None else None, headers=h)
    r = c.getresponse()
    out = r.read()
    c.close()
    try:
        return r.status, json.loads(out) if out else None
    except ValueError:
        return r.status, out


def run(cmd, **k):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **k).stdout


def ro_db():
    return sqlite3.connect(f"file:{HOME}/zigmem.db?mode=ro", uri=True, timeout=10)


# ------------------------------------------------------------------ setup
subprocess.run(["rm", "-rf", SCR], check=True)
os.makedirs(HOME, mode=0o700)
FX = json.loads(run([FIX, "--db", f"{HOME}/zigmem.db"]))
TRUTH = {t["id"]: t for t in FX["truths"]}
RULES = {r["seat"]: r for r in FX["rules"]}
PERSONS = set(FX["person_ids"])
TOK = {}
for seat in RULES:
    TOK[seat] = run([Z, "token", "add", "--home", HOME, "--seat", seat, "--scopes", "*", "--writes", "--trusted", "--admin"]).strip()
TOK["stranger"] = run([Z, "token", "add", "--home", HOME, "--seat", "stranger", "--scopes", "*", "--writes", "--trusted", "--admin"]).strip()
REVOKED = set()

log = open(os.path.join(SCR, "serve.log"), "w")
P = subprocess.Popen([Z, "serve", "--home", HOME, "--port", str(PORT)], stdout=log, stderr=subprocess.STDOUT)
for _ in range(200):
    try:
        if req("GET", "/health")[0] == 200:
            break
    except OSError:
        time.sleep(0.05)


def can_read(seat, scope):
    return scope in RULES[seat]["read"]


def can_write(seat, scope):
    return scope in RULES[seat]["write"]


def cross(seat, scope):
    return scope in RULES[seat]["cross"]


def expect_xreads(seat, scopes):
    C["xread_expected"] += sum(1 for s in scopes if can_read(seat, s) and cross(seat, s))


# ------------------------------------------------------------------ the leak oracle (independent of the server)
def leak(seat, q, rid, mode, why):
    C["leaks"] += 1
    t = TRUTH.get(rid, {})
    fail(f"LEAK [{mode}] seat={seat} q={q!r} row={rid} scope={t.get('scope')} subject={t.get('subject')}: {why}")


def judge_question(seat, q, rid, mode):
    """A row served in answer to a question (search / recall / MCP): gate.zig's judge(), restated."""
    C["rows_judged"] += 1
    t = TRUTH.get(rid)
    if t is None:
        return leak(seat, q["text"], rid, mode, "row not in the fixture")
    if seat in REVOKED:
        return leak(seat, q["text"], rid, mode, "revoked seat got a row")
    if not t["active"]:
        return leak(seat, q["text"], rid, mode, "inactive row served")
    if not can_read(seat, t["scope"]):
        return leak(seat, q["text"], rid, mode, "scope not readable by this seat")
    if not t["med"]:
        return
    C["medical_served"] += 1
    gt = q["gt"]
    if gt is None:
        return leak(seat, q["text"], rid, mode, "medical row for a question with no single subject")
    if t["truth"] != gt:
        return leak(seat, q["text"], rid, mode, "medical row about someone else")
    if not can_read(seat, f"person:{gt}"):
        return leak(seat, q["text"], rid, mode, "medical row of a person this seat may not read")


def judge_row(seat, rid, mode):
    """A row reached by id / listing: readable scope; a medical row only about one household member whose person scope
    this seat may read (inactive rows may be shown by get/list: history, not answers)."""
    C["rows_judged"] += 1
    t = TRUTH.get(rid)
    if t is None:
        return leak(seat, "(by id)", rid, mode, "row not in the fixture")
    if seat in REVOKED:
        return leak(seat, "(by id)", rid, mode, "revoked seat got a row")
    if not can_read(seat, t["scope"]):
        return leak(seat, "(by id)", rid, mode, "scope not readable by this seat")
    if t["med"]:
        if t["truth"] not in PERSONS:
            return leak(seat, "(by id)", rid, mode, "medical row not about one household member")
        if not can_read(seat, f"person:{t['truth']}"):
            return leak(seat, "(by id)", rid, mode, "medical row of a person this seat may not read")
        if t["truth"] != t["subject"]:
            return leak(seat, "(by id)", rid, mode, "mis-attributed medical row served by id")


def denied_ok(seat, st, what):
    if seat in REVOKED and st == 403:
        C["revoked_denied"] += 1
        return True
    if st != 200:
        C["errors"] += 1
        fail(f"[{what}] seat={seat} unexpected status {st}")
        return True
    return False


# ------------------------------------------------------------------ suites
def suite(phase):
    for seat, rule in RULES.items():
        tok = TOK[seat]
        mcp_n = 0
        for i, q in enumerate(rule["questions"]):
            C["queries"] += 1
            body = {"query": q["text"], "limit": 20}
            if q["requested"]:
                body["scopes"] = q["requested"]
            st, b = req("POST", "/v1/search/memories", body, tok)
            if q["expect_forbidden"]:
                if st == 403:
                    C["forbidden_ok"] += 1
                else:
                    C["leaks"] += 1
                    fail(f"[{phase}] seat={seat} forged scope {q['requested']} not refused ({st})")
                continue
            if denied_ok(seat, st, f"{phase} search"):
                continue
            expect_xreads(seat, q["requested"] or FX["all_scopes"])
            for h in b["hits"]:
                judge_question(seat, q, h["id"], "search")
            # the full phase-3 recall path (reranked) on every other question (all of them outside QUICK mode)
            if not QUICK or i % 4 == 0:
                st, b = req("POST", "/v1/recall", body, tok)
                C["recalls"] += 1
                if not denied_ok(seat, st, f"{phase} recall"):
                    expect_xreads(seat, q["requested"] or FX["all_scopes"])
                    for rid in b["memory_ids"]:
                        judge_question(seat, q, rid, "recall")
            if not q["requested"] and mcp_n < 6:
                mcp_n += 1
                C["mcp"] += 1
                st, b = req("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                            "params": {"name": "memory_search", "arguments": {"query": q["text"], "limit": 20}}}, tok)
                if st == 200 and isinstance(b, dict) and "result" in b and not b["result"].get("isError"):
                    expect_xreads(seat, FX["all_scopes"])
                    for h in json.loads(b["result"]["content"][0]["text"])["hits"]:
                        judge_question(seat, q, h["id"], "mcp")
                elif seat in REVOKED and st == 403:
                    C["revoked_denied"] += 1
                else:
                    C["errors"] += 1
                    fail(f"[{phase}] mcp seat={seat} {st} {str(b)[:120]}")
        # every row by id, and the listing
        ids = sorted(TRUTH) if not QUICK else sorted(TRUTH)[::3]
        for rid in ids:
            C["gets"] += 1
            st, b = req("POST", "/v1/atoms/get", {"id": rid}, tok)
            if st == 404:
                continue
            if denied_ok(seat, st, f"{phase} get"):
                continue
            judge_row(seat, b["atom"]["id"], "get")
            expect_xreads(seat, [TRUTH[rid]["scope"]] if rid in TRUTH else [])
        C["lists"] += 1
        st, b = req("POST", "/v1/atoms/list", {"status": "any", "limit": 200}, tok)
        if not denied_ok(seat, st, f"{phase} list"):
            expect_xreads(seat, FX["all_scopes"])
            for a in b["atoms"]:
                judge_row(seat, a["id"], "list")


TURNS = {}  # l0 id -> {owner, med, scope, seat}


def capture_turns():
    drugs = ["florvastatin", "zorvatraline", "velmoprazole", "dunatolol", "lomitriptan", "ravinoxetine", "harvacillin", "kestrapril", "quorvexine"]
    for k, (seat, rule) in enumerate(RULES.items()):
        owner = rule["member"] or "household"
        for med, text in [(True, f"[SYNTHETIC] I take 20 mg of {drugs[k]} each morning for my migraines."),
                          (False, f"[SYNTHETIC] my favorite snack is popcorn number {k}.")]:
            st, b = req("POST", "/v1/capture", {"user_content": text, "session_key": "turns"}, TOK[seat])
            if st != 200:
                C["errors"] += 1
                fail(f"capture seat={seat} {st} {b}")
                continue
            with ro_db() as con:
                sc = con.execute("SELECT scope FROM l0 WHERE id = ?", (b["ids"][0],)).fetchone()[0]
            TURNS[b["ids"][0]] = {"owner": owner, "med": med, "scope": sc, "seat": seat}


def turn_suite(phase):
    qs = ["what meds does Rowan take", "what meds do I take", "my prescription", "migraines", "popcorn snack", "what does she take",
          "does anyone in the family take meds", "Morgan's migraines", "Alex dose", "florvastatin", "ravinoxetine each morning", "kitchen"]
    for seat, rule in RULES.items():
        for qt in qs:
            # ground truth for the turn questions, written per template (oracle style)
            gt = {"what meds does Rowan take": "rowan", "Morgan's migraines": "morgan", "Alex dose": "alex"}.get(qt)
            if qt in ("what meds do I take", "my prescription", "migraines", "popcorn snack", "florvastatin", "ravinoxetine each morning", "kitchen"):
                gt = rule["member"]
            C["turn_queries"] += 1
            st, b = req("POST", "/v1/search/conversations", {"query": qt, "limit": 20}, TOK[seat])
            if denied_ok(seat, st, f"{phase} turns"):
                continue
            expect_xreads(seat, FX["all_scopes"])
            for h in b["hits"]:
                C["turn_rows_judged"] += 1
                t = TURNS.get(h["id"])
                if t is None:
                    C["leaks"] += 1
                    fail(f"LEAK [turns] seat={seat} unknown turn {h['id']}")
                    continue
                why = None
                if not can_read(seat, t["scope"]):
                    why = "turn scope not readable"
                elif t["med"]:
                    if gt is None:
                        why = "medical turn for a question with no single subject"
                    elif t["owner"] != gt:
                        why = "medical turn about someone else"
                    elif not can_read(seat, f"person:{gt}"):
                        why = "medical turn of a person this seat may not read"
                if why:
                    C["leaks"] += 1
                    fail(f"LEAK [turns {phase}] seat={seat} q={qt!r} turn={h['id']} owner={t['owner']}: {why}")


def matrix(phase):
    for seat, rule in RULES.items():
        dead = seat in REVOKED
        for scope in FX["all_scopes"]:
            C["matrix_cells"] += 1
            st, _ = req("POST", "/v1/search/memories", {"query": "matrix probe favorite", "scopes": [scope]}, TOK[seat])
            want = (not dead) and can_read(seat, scope)
            if (st == 200) != want:
                C["matrix_fail"] += 1
                fail(f"[{phase}] MATRIX read seat={seat} scope={scope} status={st} want={want}")
            if st == 200:
                expect_xreads(seat, [scope])
            C["matrix_cells"] += 1
            subject = scope[7:] if scope.startswith("person:") else (rule["member"] or "household")
            text = f"[SYNTHETIC] matrix probe {seat} wrote {scope} ({phase})"
            st, b = req("POST", "/v1/atoms/add", {"scope": scope, "subject": subject, "text": text}, TOK[seat])
            want = (not dead) and can_write(seat, scope)
            if (st == 200) != want:
                C["matrix_fail"] += 1
                fail(f"[{phase}] MATRIX write seat={seat} scope={scope} status={st} want={want}")
            if st == 200:
                TRUTH[b["id"]] = {"id": b["id"], "scope": scope, "subject": subject, "truth": subject, "med": False, "clean": True,
                                  "active": b["status"] == "active", "text": text}
        C["matrix_cells"] += 1
        st, _ = req("POST", "/v1/household/member/add", {"id": "Not A Valid Id", "display": "Synthetic Visitor", "role": "guest"}, TOK[seat])
        want = (not dead) and rule["principal"]
        if (st == 400) != want:  # 400 = passed the admin check, failed id validation (nothing changed)
            C["matrix_fail"] += 1
            fail(f"[{phase}] MATRIX admin seat={seat} status={st} want_admin={want}")
        C["matrix_cells"] += 1
        st, _ = req("POST", "/v1/household/member/revoke", {"id": "morgan"}, TOK[seat])
        if st == 200:
            C["matrix_fail"] += 1
            fail(f"[{phase}] MATRIX seat={seat} revoked a principal")


def flow(name, ok):
    C["flows"] += 1
    if not ok:
        C["flow_fail"] += 1
        fail(f"FLOW failed: {name}")


def id_of(scope, needle):
    for t in TRUTH.values():
        if t["scope"] == scope and needle in t["text"]:
            return t["id"]
    raise KeyError((scope, needle))


def hh(seat, what, body):
    return req("POST", f"/v1/household/{what}", body, TOK[seat])


def flows():
    color = id_of("person:rowan", "favorite color")
    st, b = hh("rowan-phone", "promote/request", {"id": color})
    reqid = b.get("id", -1) if st == 200 else -1
    flow("rowan requests promotion of her own plain fact", reqid > 0)
    flow("rowan cannot approve", hh("rowan-phone", "promote/decide", {"request": reqid, "approve": True})[0] == 403)
    flow("kitchen cannot approve", hh("kitchen", "promote/decide", {"request": reqid, "approve": True})[0] == 403)
    with ro_db() as con:
        n0 = con.execute("SELECT count(*) FROM atoms WHERE scope = 'household' AND text LIKE '%Rowan''s favorite color%'").fetchone()[0]
    flow("nothing reaches household before a decision", n0 == 0)
    st, b = hh("morgan-air", "promote/decide", {"request": reqid, "approve": True})
    new_id = b.get("id", -1) if st == 200 else -1
    flow("morgan approves → a new household atom", new_id > 0)
    if new_id > 0:
        TRUTH[new_id] = {"id": new_id, "scope": "household", "subject": "rowan", "truth": "rowan", "med": False, "clean": True, "active": True, "text": "promoted"}
    flow("the decision is one-shot", hh("alex-term", "promote/decide", {"request": reqid, "approve": True})[0] == 409)
    st, b = req("POST", "/v1/search/memories", {"query": "Rowan favorite color", "scopes": ["household"], "limit": 20}, TOK["taylor-phone"])
    flow("a sister reads the promoted household atom", st == 200 and any(h["id"] == new_id for h in b["hits"]))
    if st == 200:
        expect_xreads("taylor-phone", ["household"])
    flow("the guest cannot read household", req("POST", "/v1/search/memories", {"query": "favorite color", "scopes": ["household"]}, TOK["guest-phone"])[0] == 403)
    med = id_of("person:rowan", "20 mg")
    flow("medical never promotes", hh("rowan-phone", "promote/request", {"id": med})[0] == 403)
    flow("principal medical never promotes either", hh("morgan-air", "promote/request", {"id": med})[0] == 403)
    expect_xreads("morgan-air", ["person:rowan"])  # the visibility check is a by-id read
    flow("another person's atom is invisible to a child", hh("rowan-phone", "promote/request", {"id": id_of("person:morgan", "favorite color")})[0] == 404)
    st, b = hh("alex-term", "promote/request", {"id": id_of("person:alex", "favorite color")})
    r2 = b.get("id", -1) if st == 200 else -1
    st, b = hh("alex-term", "promote/decide", {"request": r2, "approve": False})
    flow("alex refuses his own request → nothing shared", r2 > 0 and st == 200 and "id" not in b)
    flow("household is never written directly, even by a principal", req("POST", "/v1/atoms/add", {"scope": "household", "subject": "household", "text": "[SYNTHETIC] direct"}, TOK["morgan-air"])[0] == 403)
    st, b = req("POST", "/v1/atoms/add", {"scope": "person:rowan", "subject": "morgan", "text": "[SYNTHETIC] Mom started 5 mg of trivexine."}, TOK["rowan-phone"])
    if st == 200:
        TRUTH[b["id"]] = {"id": b["id"], "scope": "person:rowan", "subject": "morgan", "truth": "morgan", "med": True, "clean": False, "active": False, "text": "mis-scoped medical"}
    flow("a medical fact about Morgan written into Rowan's scope lands pending_review", st == 200 and b["status"] == "pending_review")
    st, b = req("POST", "/v1/atoms/add", {"scope": "person:alex", "subject": "user", "text": "[SYNTHETIC] User likes pecan pie."}, TOK["alex-term"])
    if st == 200:
        TRUTH[b["id"]] = {"id": b["id"], "scope": "person:alex", "subject": "user", "truth": "unknown", "med": False, "clean": False, "active": False, "text": "unknown subject"}
    flow("an unresolved subject (\"User\") lands pending_review", st == 200 and b["status"] == "pending_review")
    flow("a child cannot revoke a member", hh("rowan-phone", "member/revoke", {"id": "taylor-k"})[0] == 403)
    flow("alex cannot revoke morgan (both principals)", hh("alex-term", "member/revoke", {"id": "morgan"})[0] == 403)
    flow("morgan cannot revoke alex", hh("morgan-air", "member/revoke", {"id": "alex"})[0] == 403)
    flow("a child cannot revoke another child's seat", hh("rowan-phone", "seat/revoke", {"name": "quinn-mac"})[0] == 403)
    flow("a token whose seat is not in the household is refused (403)", req("POST", "/v1/search/memories", {"query": "meds"}, TOK["stranger"])[0] == 403)
    # live revocation (no restart, next call)
    flow("morgan revokes the guest member", hh("morgan-air", "member/revoke", {"id": "taylor-k"})[0] == 200)
    REVOKED.add("guest-phone")
    flow("quinn revokes her own old seat", hh("quinn-mac", "seat/revoke", {"name": "quinn-ipad-old"})[0] == 200)
    REVOKED.add("quinn-ipad-old")
    con = sqlite3.connect(f"{HOME}/zigmem.db", timeout=10)
    try:
        con.execute("UPDATE hh_seats SET revoked_ms = NULL WHERE name = 'quinn-ipad-old'")
        con.commit()
        ok = False
    except sqlite3.DatabaseError:
        ok = True
    flow("revocation is permanent at the database", ok)
    try:
        con.execute("DELETE FROM hh_members WHERE id = 'taylor-k'")
        con.commit()
        ok = False
    except sqlite3.DatabaseError:
        ok = True
    con.close()
    flow("members are never deleted", ok)
    st, b = req("POST", "/v1/search/memories", {"query": "Taylor Kessler favorite color", "scopes": ["person:taylor-k"]}, TOK["morgan-air"])
    flow("principals still read the revoked guest's rows (history kept)", st == 200 and len(b["hits"]) > 0)
    if st == 200:
        expect_xreads("morgan-air", ["person:taylor-k"])


def tcase(name, ok):
    C["token_cases"] += 1
    if not ok:
        C["token_fail"] += 1
        fail(f"TOKEN case failed: {name}")


def token_cases():
    forged = "zm_" + os.urandom(32).hex()
    for path, body in [("/v1/search/memories", {"query": "meds"}), ("/v1/recall", {"query": "meds"}), ("/v1/atoms/get", {"id": 1}),
                       ("/v1/atoms/list", {}), ("/v1/search/conversations", {"query": "meds"}), ("/v1/atoms/add", {"text": "x"}),
                       ("/v1/household/member/revoke", {"id": "rowan"}), ("/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})]:
        tcase(f"forged token {path} → 401", req("POST", path, body, forged)[0] == 401)
        tcase(f"another seat's token with a byte flipped {path} → 401", req("POST", path, body, TOK["morgan-air"][:-1] + ("0" if TOK["morgan-air"][-1] != "0" else "1"))[0] == 401)
    # a bound seat whose TOKEN is revoked with the CLI: works, then 401 at once
    st, _ = hh("morgan-air", "seat/bind", {"name": "rowan-tablet", "member": "rowan"})
    tcase("morgan binds a new seat for rowan", st == 200)
    t = run([Z, "token", "add", "--home", HOME, "--seat", "rowan-tablet", "--scopes", "*"]).strip()
    st, b = req("POST", "/v1/search/memories", {"query": "what meds do I take", "limit": 20}, t)
    tcase("new seat token works", st == 200)
    if st == 200:
        # the oracle row for the new seat, written literally like the fixture's: rowan's scopes + its own seat scope
        RULES["rowan-tablet"] = {"seat": "rowan-tablet", "member": "rowan", "role": "child", "principal": False, "questions": [],
                                "read": ["household", "person:rowan", "seat:rowan-tablet"], "write": ["person:rowan", "seat:rowan-tablet"], "cross": []}
        q = {"text": "what meds do I take", "gt": "rowan"}
        for h in b["hits"]:
            judge_question("rowan-tablet", q, h["id"], "tablet")
    run([Z, "token", "revoke", "--home", HOME, "--seat", "rowan-tablet"])
    for path in ["/v1/search/memories", "/v1/recall", "/v1/atoms/list"]:
        tcase(f"CLI-revoked token {path} → 401", req("POST", path, {"query": "meds"}, t)[0] == 401)
    # a narrowing token: morgan's member, but this token only reads `household`
    st, _ = hh("morgan-air", "seat/bind", {"name": "morgan-narrow", "member": "morgan"})
    tn = run([Z, "token", "add", "--home", HOME, "--seat", "morgan-narrow", "--scopes", "household"]).strip()
    st, b = req("POST", "/v1/search/memories", {"query": "what meds does Morgan take", "limit": 20}, tn)
    tcase("narrowed token searches", st == 200)
    tcase("narrowed token never serves a row outside `household`", st == 200 and all(h["scope"] == "household" for h in b["hits"]))
    tcase("narrowed token asking for person:morgan → 403", req("POST", "/v1/search/memories", {"query": "meds", "scopes": ["person:morgan"]}, tn)[0] == 403)
    tcase("narrowed token cannot write person:morgan (403)", req("POST", "/v1/atoms/add", {"scope": "person:morgan", "text": "[SYNTHETIC] x"}, tn)[0] == 403)
    tcase("narrowed token has no admin flag (member/add 403)", req("POST", "/v1/household/member/add", {"id": "zz", "display": "Z", "role": "guest"}, tn)[0] == 403)
    # the unbound seat's token: 403 everywhere, never 200
    for path in ["/v1/search/memories", "/v1/recall", "/v1/atoms/list", "/v1/capture"]:
        tcase(f"unbound seat {path} → 403", req("POST", path, {"query": "meds", "user_content": "x", "session_key": "s"}, TOK["stranger"])[0] == 403)
    # a household-revoked seat with a still-valid token: 403
    tcase("household-revoked seat (token still valid) → 403", req("POST", "/v1/search/memories", {"query": "meds"}, TOK["quinn-ipad-old"])[0] == 403)
    tcase("revoked member's seat (token still valid) → 403", req("POST", "/v1/recall", {"query": "meds"}, TOK["guest-phone"])[0] == 403)
    # forged identity headers / body ids are ignored (a kid naming morgan's seat still reads as the kid)
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=30)
    c.request("POST", "/v1/search/memories", body=json.dumps({"query": "what meds does Morgan take", "limit": 20, "seat": "morgan-air", "user_id": "morgan"}),
              headers={"Authorization": f"Bearer {TOK['rowan-phone']}", "Content-Type": "application/json", "x-zigmem-seat": "morgan-air", "x-vendor-user-id": "morgan"})
    r = c.getresponse()
    b = json.loads(r.read())
    c.close()
    tcase("forged x-zigmem-seat / body seat ignored: rowan still sees no Morgan medical row", r.status == 200 and not any(TRUTH.get(h["id"], {}).get("med") and TRUTH[h["id"]]["truth"] == "morgan" for h in b["hits"]))
    if r.status == 200:
        expect_xreads("rowan-phone", FX["all_scopes"])


# ------------------------------------------------------------------ run
t0 = time.time()
try:
    capture_turns()
    suite("p1")
    turn_suite("p1")
    matrix("p1")
    flows()
    suite("p2-after-revocation")
    turn_suite("p2-after-revocation")
    matrix("p2-after-revocation")
    token_cases()
finally:
    P.send_signal(signal.SIGTERM)
    try:
        P.wait(10)
    except subprocess.TimeoutExpired:
        P.kill()
        P.wait(5)
    STOPS.append({"pid": P.pid, "gone": not os.path.exists(f"/proc/{P.pid}") or open(f"/proc/{P.pid}/stat").read().split()[2] == "Z"})
    log.close()
# read-side audit lives in audit.log (one entry per cross scope searched, per call); denials also in the store
alines = [json.loads(l) for l in open(f"{HOME}/audit.log")]
xread_got = sum(len(l.get("xread", [])) for l in alines)
xread_q_ok = all(len(l["q"]) == 8 for l in alines if l.get("xread"))
with ro_db() as con:
    deny_rows = con.execute("SELECT count(*) FROM audit WHERE action = 'deny'").fetchone()[0]
    words = ["meds", "prescription", "favorite", "dose", "migraine", "popcorn", "medication", "pills"]
    text_in_audit = sum(con.execute("SELECT count(*) FROM audit WHERE action IN ('xread','deny') AND detail LIKE ?", (f"%{w}%",)).fetchone()[0] for w in words)
alog = open(f"{HOME}/audit.log").read()
text_in_log = sum(alog.count(w) for w in words)
audit_ok = xread_got == C["xread_expected"] and xread_q_ok and text_in_audit == 0 and text_in_log == 0 and deny_rows > 0
if not audit_ok:
    fail(f"AUDIT xread got={xread_got} want={C['xread_expected']} deny_rows={deny_rows} text_in_audit={text_in_audit} text_in_log={text_in_log}")
ok = (C["leaks"] == 0 and C["matrix_fail"] == 0 and C["flow_fail"] == 0 and C["errors"] == 0 and C["token_fail"] == 0 and audit_ok
      and C["queries"] >= 200 and all(s["gone"] for s in STOPS))
res = dict(C, gate="integration-p5-api", pass_=ok, xread_audit_rows=xread_got, deny_rows=deny_rows, query_text_in_audit_table=text_in_audit,
           query_text_in_audit_log=text_in_log, fixture_rows=len(FX["truths"]), turns_captured=len(TURNS), elapsed_s=round(time.time() - t0, 1),
           quick=QUICK, stops=STOPS, failures=FAILS)
json.dump(res, open(os.path.join(REC, "gate.json"), "w"), indent=1)
print(json.dumps({k: v for k, v in res.items() if k != "failures"}, indent=1))
for f in FAILS[:30]:
    print("  ", f)
print("GATE integration-p5-api", "GREEN" if ok else "RED")
sys.exit(0 if ok else 1)
