#!/usr/bin/env python3
"""zigmem INTEGRATION re-run of the phase-6 panel gates (port of tests/phase6/gates.py; every check unchanged).
Setup only: household-shaped scopes (syn-a → person:ana, syn-b → person:ben) and a synthetic household binding every
seat the gates use (adm → the principal pat; ana, ro, victim, newseat → ana; ben → ben). Ports 18196-18199.
Usage: p6_panel.py all --bin PATH [--port N] [--tag NAME]. Receipts: receipts/integration/p6/<tag>.json."""
import hashlib, http.client, json, os, re, secrets, signal, sqlite3, subprocess, sys, time, threading

ROOT = os.path.expanduser("~/zigmem")
SCR = os.environ.get("ZIGMEM_SCR", os.path.join(ROOT, "scratch/integ/p6"))
REC = os.environ.get("ZIGMEM_REC", os.path.join(ROOT, "receipts/integration/p6"))
os.makedirs(SCR, exist_ok=True)
os.makedirs(REC, exist_ok=True)
STOPS, RESP, TOKENS, SESSIONS = [], [], {}, []

HOSTILE = [
    '<script>window.__xss=1;alert(1)</script>',
    '"><img src=x onerror="window.__xss=1;alert(2)">',
    "'><svg onload=window.__xss=1>",
    '</textarea><script>window.__xss=1</script>',
    '</title><script>window.__xss=1</script>',
    'javascript:window.__xss=1',
    '<a href="javascript:window.__xss=1">click</a>',
    '<iframe srcdoc="<script>parent.__xss=1</script>"></iframe>',
    '<style>body{display:none}</style>',
    '<meta http-equiv="refresh" content="0;url=javascript:window.__xss=1">',
    '‮<b>bold</b> &amp; &lt;already&gt;',
]
RAW_MARKERS = ['<script>window.__xss', '<img src=x', '<svg', '<iframe', '<style>body', '<meta http-equiv', '<b>bold', '<a href="javascript']


# ------------------------------------------------------------------ plumbing
def alive(pid):
    try:
        os.kill(pid, 0)
        return open(f"/proc/{pid}/stat").read().split()[2] != "Z"
    except (ProcessLookupError, FileNotFoundError):
        return False


def stop(p):
    os.kill(p.pid, signal.SIGTERM)
    try:
        p.wait(10)
    except subprocess.TimeoutExpired:
        os.kill(p.pid, signal.SIGKILL)
        p.wait(5)
    gone = not alive(p.pid)
    STOPS.append({"pid": p.pid, "gone": gone})
    assert gone, f"pid {p.pid} still alive"


class Srv:
    def __init__(s, bin_, port, tag):
        s.bin, s.port, s.home = bin_, port, os.path.join(SCR, tag)
        subprocess.run(["rm", "-rf", s.home], check=True)
        s.db = os.path.join(s.home, "zigmem.db")

    def token(s, seat, scopes, *flags, person=None):
        cmd = [s.bin, "token", "add", "--home", s.home, "--seat", seat, "--scopes", scopes] + list(flags)
        if person:
            cmd += ["--person", person]
        t = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()
        TOKENS[seat] = t
        return t

    def revoke(s, seat):
        subprocess.run([s.bin, "token", "revoke", "--home", s.home, "--seat", seat], check=True, capture_output=True)

    def start(s):
        log = open(os.path.join(s.home, "serve.log"), "ab")
        s.p = subprocess.Popen([s.bin, "serve", "--home", s.home, "--port", str(s.port)], stdout=log, stderr=log)
        for _ in range(100):
            try:
                if s.req("GET", "/health", record=False)[0] == 200:
                    return
            except OSError:
                pass
            time.sleep(0.05)
        raise RuntimeError("server did not come up")

    def stop(s):
        stop(s.p)

    def req(s, method, path, form=None, cookies=None, headers=None, raw=None, ctype=None, record=True, who="-"):
        """headers: dict; a value of None drops a default header. Defaults: Host, and on POST Origin + form type."""
        h = {"Host": f"127.0.0.1:{s.port}"}
        if method == "POST":
            h["Origin"] = f"http://127.0.0.1:{s.port}"
            h["Content-Type"] = ctype or "application/x-www-form-urlencoded"
        if cookies:
            h["Cookie"] = "; ".join(f"{k}={v}" for k, v in cookies.items())
        for k, v in (headers or {}).items():
            if v is None:
                h.pop(k, None)
            else:
                h[k] = v
        body = raw if raw is not None else (urlenc(form).encode() if form is not None else b"")
        c = http.client.HTTPConnection("127.0.0.1", s.port, timeout=15)
        c.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        for k, v in h.items():
            c.putheader(k, v)
        c.putheader("Content-Length", str(len(body)))
        c.endheaders(body)
        r = c.getresponse()
        out = r.read()
        hdrs = r.getheaders()
        c.close()
        if record:
            RESP.append({"who": who, "method": method, "path": path, "status": r.status, "headers": hdrs, "body": out})
        return r.status, hdrs, out.decode("utf-8", "replace")

    def sql(s, q, args=()):
        con = sqlite3.connect(s.db, timeout=10)
        try:
            cur = con.execute(q, args)
            rows = cur.fetchall()
            con.commit()
            return rows
        finally:
            con.close()


def urlenc(d):
    from urllib.parse import urlencode
    return urlencode(d)


def hdr(hdrs, name):
    return [v for k, v in hdrs if k.lower() == name.lower()]


def cookie_of(hdrs, name):
    for v in hdr(hdrs, "Set-Cookie"):
        k, _, rest = v.partition("=")
        if k == name:
            return rest.split(";")[0]
    return None


def csrf_of(body):
    m = re.search(r'name="csrf" value="([0-9a-f]{64})"', body)
    return m.group(1) if m else None


def login(s, seat):
    st, h, b = s.req("GET", "/panel/login", who=seat)
    pre, tok = cookie_of(h, "zm_pre"), csrf_of(b)
    st, h, b = s.req("POST", "/panel/login", form={"csrf": tok, "token": TOKENS[seat]}, cookies={"zm_pre": pre}, who=seat)
    assert st == 303, (st, b[:300])
    sess = cookie_of(h, "zm_sess")
    SESSIONS.append(sess)
    st, h, b = s.req("GET", "/panel/atoms", cookies={"zm_sess": sess}, who=seat)
    assert st == 200, st
    return {"seat": seat, "sess": sess, "csrf": csrf_of(b)}


def get(s, L, path):
    return s.req("GET", path, cookies={"zm_sess": L["sess"]}, who=L["seat"])


def post(s, L, path, form, **k):
    f = dict(form)
    if "csrf" not in f:
        f["csrf"] = L["csrf"]
    if f["csrf"] is None:
        del f["csrf"]
    return s.req("POST", path, form=f, cookies={"zm_sess": L["sess"]}, who=L["seat"], **k)


def check(results, name, ok, detail=None):
    results.append({"check": name, "ok": bool(ok), "detail": detail})
    if not ok:
        print("  RED:", name, detail if detail is not None else "")
    return ok


# ------------------------------------------------------------------ synthetic world
def seed(s):
    """Hostile + ordinary synthetic rows. Returns ids."""
    ids = {}
    adm = TOKENS["adm"]
    c = http.client.HTTPConnection("127.0.0.1", s.port, timeout=15)
    turn_ids = []
    for i, hx in enumerate(HOSTILE):
        body = json.dumps({"session_key": "syn-sess", "user_content": f"turn {i}: Ana mentioned {hx}", "scope": "person:ana", "ts_ms": 1760000000000 + i})
        c = http.client.HTTPConnection("127.0.0.1", s.port, timeout=15)
        c.request("POST", "/v1/capture", body=body, headers={"Authorization": f"Bearer {adm}", "Content-Type": "application/json"})
        r = json.loads(c.getresponse().read())
        turn_ids.append(r["ids"][0])
        c.close()
    now = int(time.time() * 1000)

    def atom(scope, subject, text, typ="fact", status="active", lineage=None, src=None, run=None, vf=None, sup=None):
        lin = lineage or ("Lsyn" + secrets.token_hex(6))
        return s.sql("INSERT INTO atoms(lineage, subject, scope, type, priority, text, valid_from, recorded_ms, status, src_l0, extractor, prompt_sha, run_id, sha256, superseded_by) "
                     "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) RETURNING id",
                     (lin, subject, scope, typ, 50, text, vf, now, status, src, "zigmem-extract/syn|<b>m</b>|p:1", os.urandom(32), run, os.urandom(32), sup))[0][0]

    s.sql("INSERT INTO runs(id, kind, model, started_ms, ended_ms, outcome) VALUES (?,?,?,?,?,?)",
          ("run-<script>window.__xss=1</script>", "extract", HOSTILE[1], now, now, HOSTILE[0]))
    ids["hostile"] = []
    for i, hx in enumerate(HOSTILE):
        ids["hostile"].append(atom("person:ana", "ana" if i % 2 else 'ana"><script>window.__xss=1</script>', f"Ana note {i}: {hx}",
                                   src=f"turn={turn_ids[i]} sha={hx}", run="run-<script>window.__xss=1</script>", vf=hx if i == 3 else "2026-10-01"))
    # bad UTF-8 (stored as text via a blob cast)
    ids["badutf8"] = s.sql("INSERT INTO atoms(lineage, subject, scope, type, priority, text, recorded_ms, status, sha256) "
                           "VALUES ('Lbad','ana','person:ana','fact',50,CAST(? AS TEXT),?,'active',?) RETURNING id",
                           (b"bad bytes \xff\xfe <script>window.__xss=1</script> \xc3", now, os.urandom(32)))[0][0]
    # a two-version lineage made of hostile text (history view)
    old = atom("person:ana", "ben", "Ben's old note " + HOSTILE[2], lineage="L<script>x</script>", status="active")
    new = atom("person:ana", "ben", "Ben's new note " + HOSTILE[0], lineage="L<script>x</script>")
    s.sql("UPDATE atoms SET status='superseded', superseded_by=?, valid_to=? WHERE id=?", (new, HOSTILE[5], old))
    ids["lineage"] = (old, new)
    s.sql("INSERT INTO audit(ts_ms, seat, action, table_name, row_id, detail) VALUES (?,?,?,?,?,?)", (now, HOSTILE[1], HOSTILE[0], "atoms", new, HOSTILE[3]))
    # extraction queue rows, one dead with a hostile error
    for i, t in enumerate(turn_ids[:4]):
        s.sql("INSERT INTO jobs(kind, key, due_ms, tries, state, last_err) VALUES ('extract', ?, ?, ?, ?, ?)",
              (str(t), now, i, ["queued", "done", "dead", "running"][i], HOSTILE[i] if i == 2 else None))
    # ordinary rows for the function checks
    ids["f1"] = atom("person:ana", "ana", "Ana keeps the brass lantern in the blue shed.")
    ids["f2"] = atom("person:ana", "ana", "Ana plants tulips every spring.")
    ids["f3"] = atom("person:ana", "ben", "Ben waters the tulips on Sunday.")
    ids["csrf1"] = atom("person:ana", "ana", "CSRF target one: the kite is red.")
    ids["csrf2"] = atom("person:ana", "ana", "CSRF target two: the boat is green.")
    ids["pending"] = atom("person:ana", "ana", "Ana might move to the coast.", status="pending_review")
    ids["synb"] = atom("person:ben", "zed", "Zed hides the zebra-lantern in syn-b.")
    ids["turns"] = turn_ids
    return ids


# ------------------------------------------------------------------ gates
GET_ROUTES = ["/panel", "/panel/", "/panel/atoms", "/panel/atoms?status=any", "/panel/atom?id=1", "/panel/queue", "/panel/health", "/panel/seats", "/panel/nope"]
POST_ROUTES = ["/panel/logout", "/panel/atom/supersede", "/panel/atom/status", "/panel/seats/create", "/panel/seats/revoke", "/panel/nope"]


def gate_auth(s, ids):
    R = []
    st, h, b = s.req("GET", "/panel/login", who="anon")
    check(R, "login page is public (200)", st == 200, st)
    bad_cookies = [None, {"zm_sess": secrets.token_hex(32)}, {"zm_sess": "x"}, {"zm_sess": "zz" * 32}, {"zm_pre": secrets.token_hex(16)}]
    for ck in bad_cookies:
        for p in GET_ROUTES:
            st, h, b = s.req("GET", p, cookies=ck, who="anon")
            check(R, f"GET {p} cookie={list(ck) if ck else None} -> 303 login, empty body", st == 303 and hdr(h, "Location") == ["/panel/login"] and b == "", (st, hdr(h, "Location"), len(b)))
        for p in POST_ROUTES:
            st, h, b = s.req("POST", p, form={"csrf": "0" * 64, "id": ids["csrf1"], "to": "retired"}, cookies=ck, who="anon")
            check(R, f"POST {p} cookie={list(ck) if ck else None} -> 401", st == 401, st)
    # revocation kills the panel session on its next request
    s.token("victim", "person:ana")
    L = login(s, "victim")
    s.revoke("victim")
    st, h, b = get(s, L, "/panel/atoms")
    check(R, "CLI revoke ends the panel session (303 login)", st == 303 and hdr(h, "Location") == ["/panel/login"], st)
    # the API behind the wrapper still demands a bearer token
    for p in ["/v1/recall", "/v1/atoms/list", "/mcp"]:
        st, h, b = s.req("POST", p, raw=b"{}", ctype="application/json", who="anon")
        check(R, f"API {p} without bearer still 401", st == 401, st)
    return R


def state(s):
    return {"atoms": s.sql("SELECT id, status, superseded_by FROM atoms ORDER BY id"),
            "audit": s.sql("SELECT count(*) FROM audit")[0][0],
            "tokens": hashlib.sha256(open(os.path.join(s.home, "tokens"), "rb").read()).hexdigest()}


def gate_csrf(s, ids, adm, ana):
    R = []
    before = state(s)
    tgt = {"id": ids["csrf1"], "to": "retired"}
    good_o = f"http://127.0.0.1:{s.port}"
    cases = [
        ("no csrf field", "/panel/atom/status", dict(tgt, csrf=None), {}, None, 403),
        ("wrong csrf", "/panel/atom/status", dict(tgt, csrf=secrets.token_hex(32)), {}, None, 403),
        ("short csrf", "/panel/atom/status", dict(tgt, csrf="abc"), {}, None, 403),
        ("another session's csrf", "/panel/atom/status", dict(tgt, csrf=ana["csrf"]), {}, None, 403),
        ("Origin evil", "/panel/atom/status", tgt, {"Origin": "http://evil.example"}, None, 403),
        ("Origin null", "/panel/atom/status", tgt, {"Origin": "null"}, None, 403),
        ("Origin other port (same site)", "/panel/atom/status", tgt, {"Origin": "http://127.0.0.1:18198"}, None, 403),
        ("Origin https variant", "/panel/atom/status", tgt, {"Origin": "https://127.0.0.1:%d" % s.port}, None, 403),
        ("Sec-Fetch-Site cross-site", "/panel/atom/status", tgt, {"Sec-Fetch-Site": "cross-site"}, None, 403),
        ("Sec-Fetch-Site same-site", "/panel/atom/status", tgt, {"Sec-Fetch-Site": "same-site"}, None, 403),
        ("Host evil (rebinding)", "/panel/atom/status", tgt, {"Host": f"evil.example:{s.port}", "Origin": f"http://evil.example:{s.port}"}, None, 403),
        ("no Host", "/panel/atom/status", tgt, {"Host": None}, None, 403),
        ("text/plain body", "/panel/atom/status", tgt, {}, "text/plain", 415),
        ("json body", "/panel/atom/status", tgt, {}, "application/json", 415),
        ("multipart", "/panel/atom/status", tgt, {}, "multipart/form-data; boundary=x", 415),
        ("supersede no csrf", "/panel/atom/supersede", {"id": ids["csrf1"], "text": "pwned", "csrf": None}, {}, None, 403),
        ("seat create no csrf", "/panel/seats/create", {"seat": "evil", "scopes": "person:ana", "admin": "1", "csrf": None}, {}, None, 403),
        ("seat create Origin evil", "/panel/seats/create", {"seat": "evil", "scopes": "person:ana", "admin": "1"}, {"Origin": "http://evil.example"}, None, 403),
        ("seat revoke no csrf", "/panel/seats/revoke", {"seat": "ana", "csrf": None}, {}, None, 403),
        ("logout no csrf", "/panel/logout", {"csrf": None}, {}, None, 403),
    ]
    for name, path, form, hd, ct, want in cases:
        st, h, b = post(s, adm, path, form, headers=hd, ctype=ct)
        check(R, f"{name} -> {want}", st == want, st)
    st, h, b = s.req("POST", "/panel/atom/status", form=dict(tgt, csrf=adm["csrf"]), who="anon")
    check(R, "valid csrf but no cookie -> 401", st == 401, st)
    # login CSRF
    st, h, b = s.req("GET", "/panel/login", who="anon")
    pre, tok = cookie_of(h, "zm_pre"), csrf_of(b)
    st2, h2, b2 = s.req("GET", "/panel/login", who="anon")
    pre2, tok2 = cookie_of(h2, "zm_pre"), csrf_of(b2)
    for name, form, ck, hd in [
        ("login without pre cookie", {"csrf": tok, "token": TOKENS["adm"]}, {}, {}),
        ("login csrf from another form", {"csrf": tok2, "token": TOKENS["adm"]}, {"zm_pre": pre}, {}),
        ("login no csrf", {"token": TOKENS["adm"]}, {"zm_pre": pre}, {}),
        ("login Origin evil", {"csrf": tok, "token": TOKENS["adm"]}, {"zm_pre": pre}, {"Origin": "http://evil.example"}),
    ]:
        st, h, b = s.req("POST", "/panel/login", form=form, cookies=ck, headers=hd, who="anon")
        check(R, f"{name} -> 403 and no session cookie", st == 403 and cookie_of(h, "zm_sess") is None, st)
    after = state(s)
    check(R, "DB atoms/status, audit rows and token file unchanged by every refused request", before == after,
          None if before == after else {"audit": (before["audit"], after["audit"]), "tok": before["tokens"] == after["tokens"]})
    st, h, b = get(s, adm, "/panel/atoms")
    check(R, "session survived the refused logout", st == 200, st)
    # GREEN control: the same request with the token and same-origin headers works
    st, h, b = post(s, adm, "/panel/atom/status", tgt)
    flipped = s.sql("SELECT status FROM atoms WHERE id=?", (ids["csrf1"],))[0][0]
    check(R, "control: valid same-origin form post succeeds (303, retired)", st == 303 and flipped == "retired", (st, flipped))
    return R


EVIL_TPL = """<!doctype html><html><body><form id="f" method="post" action="http://127.0.0.1:{port}/panel/atom/status">
<input name="id" value="{id}"><input name="to" value="retired"><input name="csrf" value="{csrf}"></form>
<script>document.getElementById('f').submit()</script></body></html>"""


def evil_server(port, d):
    os.makedirs(d, exist_ok=True)
    p = subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1", "--directory", d],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(50):
        try:
            http.client.HTTPConnection("127.0.0.1", port, timeout=1).request("HEAD", "/")
            return p
        except OSError:
            time.sleep(0.1)
    return p


def browser_gates(s, ids, adm, do_csrf=True, do_xss=True, do_mobile=True):
    """Chromium: UI login, cross-origin auto-submit attacks, hostile-row pages, storage/cookie checks, 390 px."""
    from playwright.sync_api import sync_playwright
    out = {"csrf": [], "xss": [], "secrets": [], "mobile": [], "seen": []}
    base = f"http://127.0.0.1:{s.port}"
    pages_list = ["/panel/atoms", "/panel/atoms?status=any", "/panel/atoms?q=note", f"/panel/atom?id={ids['hostile'][0]}",
                  f"/panel/atom?id={ids['hostile'][1]}", f"/panel/atom?id={ids['hostile'][3]}", f"/panel/atom?id={ids['badutf8']}",
                  f"/panel/atom?id={ids['lineage'][1]}", f"/panel/atom?id={ids['f2']}", "/panel/queue", "/panel/health", "/panel/seats"]
    with sync_playwright() as pw:
        br = pw.chromium.launch(headless=True)

        def ui_login(ctx, seat):
            pg = ctx.new_page()
            pg.goto(base + "/panel/login")
            pg.fill("input[name=token]", TOKENS[seat])
            pg.click("button[type=submit]")
            pg.wait_for_url("**/panel/atoms")
            return pg

        def capture(pg):
            def on_resp(r):
                try:
                    if r.url.startswith(base):
                        out["seen"].append({"url": r.url, "status": r.status, "headers": r.headers_array(), "body": r.body()})
                except Exception:
                    pass
            pg.on("response", on_resp)

        ctx = br.new_context()
        pg = ui_login(ctx, "adm")
        capture(pg)
        if do_csrf:
            real_csrf = pg.get_attribute("input[name=csrf]", "value")
            ev = os.path.join(SCR, "evil")
            evp = evil_server(18198, ev)
            try:
                for name, host, csrf, tid in [("cross-origin same-site page (127.0.0.1:18198), guessed csrf", "127.0.0.1", "0" * 64, ids["csrf2"]),
                                              ("cross-site page (localhost:18198), guessed csrf", "localhost", "0" * 64, ids["csrf2"]),
                                              ("cross-origin page holding the browser session's REAL csrf (leak simulation)", "127.0.0.1", real_csrf, ids["csrf2"])]:
                    fn = f"evil_{secrets.token_hex(4)}.html"
                    open(os.path.join(ev, fn), "w").write(EVIL_TPL.format(port=s.port, id=tid, csrf=csrf))
                    ap = ctx.new_page()
                    statuses = []
                    ap.on("response", lambda r: statuses.append(r.status) if "/panel/atom/status" in r.url else None)
                    ap.goto(f"http://{host}:18198/{fn}")
                    try:
                        ap.wait_for_load_state("load", timeout=5000)
                        ap.wait_for_timeout(800)
                    except Exception:
                        pass
                    stv = s.sql("SELECT status FROM atoms WHERE id=?", (tid,))[0][0]
                    out["csrf"].append({"check": f"browser: {name} -> refused, atom unchanged", "ok": stv == "active" and all(x in (401, 403) for x in statuses) and statuses != [],
                                        "detail": {"statuses": statuses, "atom": stv}})
                    ap.close()
            finally:
                stop(evp)
        if do_xss or do_mobile:
            dialogs = []
            pg.on("dialog", lambda d: (dialogs.append(d.message), d.dismiss()))
            csp = []
            pg.on("console", lambda m: csp.append(m.text) if "Content Security Policy" in m.text else None)
            for p in pages_list:
                pg.goto(base + p)
                pg.wait_for_timeout(150)
                xss = pg.evaluate("() => typeof window.__xss !== 'undefined' || typeof parent.__xss !== 'undefined'")
                html_ = pg.content()
                n_scripts = len(re.findall(r"<script\b", html_))
                raw = [m for m in RAW_MARKERS if m in html_]
                store_ = pg.evaluate("() => [localStorage.length, sessionStorage.length, document.cookie]")
                out["xss"].append({"check": f"browser: {p} no script ran, 1 script tag, no raw markup", "ok": not xss and n_scripts == 1 and not raw,
                                   "detail": {"xss": xss, "scripts": n_scripts, "raw": raw}})
                out["secrets"].append({"check": f"browser: {p} storage empty, cookie HttpOnly", "ok": store_ == [0, 0, ""], "detail": store_})
            out["xss"].append({"check": "browser: 0 dialogs over every page", "ok": not dialogs, "detail": dialogs})
            out["xss"].append({"check": "browser: 0 CSP violations (no injected inline script/style attempted to run)", "ok": not csp, "detail": csp[:5]})
        ctx.close()
        if do_mobile:
            shots = os.path.join(REC, "shots")
            os.makedirs(shots, exist_ok=True)
            for scheme in ["light", "dark"]:
                mctx = br.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=2, is_mobile=True, has_touch=True, color_scheme=scheme)
                mp = mctx.new_page()
                mp.goto(base + "/panel/login")
                lw = mp.evaluate("() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]")
                out["mobile"].append({"check": f"390px {scheme}: /panel/login fits", "ok": lw[0] <= 390, "detail": lw})
                mp.screenshot(path=os.path.join(shots, f"login_{scheme}.png"), full_page=True)
                mp.fill("input[name=token]", TOKENS["adm"])
                mp.click("button[type=submit]")
                mp.wait_for_url("**/panel/atoms")
                for p in pages_list:
                    mp.goto(base + p)
                    w = mp.evaluate("() => [document.documentElement.scrollWidth, document.documentElement.clientWidth, Math.max(...[...document.querySelectorAll('body *')].map(e => e.getBoundingClientRect().right))]")
                    out["mobile"].append({"check": f"390px {scheme}: {p} fits", "ok": w[0] <= 390 and w[2] <= 390.5, "detail": w})
                    name = re.sub(r"[^a-z0-9]+", "_", p[7:]).strip("_") or "root"
                    mp.screenshot(path=os.path.join(shots, f"{name}_{scheme}.png"), full_page=True)
                mctx.close()
        br.close()
    return out


def raw_xss():
    """Every HTML body served so far (python client): exactly one <script> (ours), no raw hostile markup."""
    R, n = [], 0
    for r in RESP:
        ct = ";".join(hdr(r["headers"], "Content-Type"))
        if r["status"] != 200 or "text/html" not in ct:
            continue
        b = r["body"].decode("utf-8", "replace")
        n += 1
        raw = [m for m in RAW_MARKERS if m in b]
        if b.count("<script") != 1 or raw:
            R.append((r["path"], b.count("<script"), raw))
    return [{"check": f"raw bodies: {n} HTML pages, each exactly one <script> and no raw hostile markup", "ok": n > 0 and not R, "detail": R[:10]}]


def gate_function(s, ids, adm, ana, ro):
    R = []
    n_before = s.sql("SELECT count(*) FROM atoms")[0][0]
    ids_before = {r[0] for r in s.sql("SELECT id FROM atoms")}
    st, h, b = get(s, adm, "/panel/atoms")
    check(R, "list shows seeded memories", st == 200 and "brass lantern" in b, st)
    st, h, b = get(s, adm, "/panel/atoms?q=lantern")
    check(R, "search finds by word", "brass lantern" in b and "plants tulips" not in b, st)
    st, h, b = get(s, adm, "/panel/atoms?subject=ben")
    check(R, "subject filter", "waters the tulips" in b and "plants tulips" not in b, st)
    st, h, b = get(s, adm, f"/panel/atom?id={ids['hostile'][0]}")
    check(R, "atom page shows provenance, run, source turn, history, audit", all(k in b for k in ["Provenance", "<h3>Run</h3>", "Source turn #", "History", "Audit", "content sha256"]), st)
    st, h, b = get(s, adm, f"/panel/atom?id={ids['lineage'][1]}")
    check(R, "lineage view lists both versions", b.count('href="/panel/atom?id=') >= 2 and "2 versions" in b, st)
    # supersede
    st, h, b = post(s, adm, "/panel/atom/supersede", {"id": ids["f1"], "text": "Ana keeps the brass lantern in the red shed now.", "valid_from": "2026-10-12"})
    loc = hdr(h, "Location")
    new = int(re.search(r"id=(\d+)", loc[0]).group(1)) if loc else None
    row_old = s.sql("SELECT status, superseded_by, lineage FROM atoms WHERE id=?", (ids["f1"],))[0]
    row_new = s.sql("SELECT status, lineage, extractor FROM atoms WHERE id=?", (new,))[0] if new else None
    check(R, "supersede: new active version, old kept as superseded, same lineage", st == 303 and row_old[0] == "superseded" and row_old[1] == new and row_new[0] == "active" and row_new[1] == row_old[2] and row_new[2] == "panel", (st, row_old, row_new))
    st, h, b = get(s, adm, f"/panel/atom?id={new}")
    check(R, "history after supersede shows 2 versions + audit supersede", "2 versions" in b and "supersede" in b, st)
    # status flips
    st, h, b = post(s, adm, "/panel/atom/status", {"id": ids["f2"], "to": "pending_review", "reason": "check the season"})
    st2, h2, b2 = post(s, adm, "/panel/atom/status", {"id": ids["f2"], "to": "active"})
    aud = s.sql("SELECT detail FROM audit WHERE table_name='atoms' AND row_id=? AND action='status' ORDER BY id", (ids["f2"],))
    check(R, "demote to review then approve (trusted), audit rows", st == 303 and st2 == 303 and [x[0] for x in aud] == ["active->pending_review", "pending_review->active"], (st, st2, aud))
    st, h, b = post(s, ana, "/panel/atom/status", {"id": ids["pending"], "to": "active"})
    check(R, "untrusted seat cannot approve (403)", st == 403 and s.sql("SELECT status FROM atoms WHERE id=?", (ids["pending"],))[0][0] == "pending_review", st)
    st, h, b = post(s, ana, "/panel/atom/supersede", {"id": ids["f3"], "text": "Ben saw the dentist on Monday."})
    check(R, "untrusted seat: privacy screen refuses family/medical text (403)", st == 403, st)
    st, h, b = post(s, ro, "/panel/atom/status", {"id": ids["f3"], "to": "retired"})
    check(R, "read-only seat cannot change status (403)", st == 403, st)
    st, h, b = post(s, adm, "/panel/atom/status", {"id": ids["f3"], "to": "retired", "reason": "test retire"})
    r3 = s.sql("SELECT status FROM atoms WHERE id=?", (ids["f3"],))[0][0]
    check(R, "retire = status flip (row still there) + audit", st == 303 and r3 == "retired" and s.sql("SELECT count(*) FROM audit WHERE row_id=? AND detail='active->retired'", (ids["f3"],))[0][0] == 1, (st, r3))
    st, h, b = post(s, adm, "/panel/atom/status", {"id": ids["f3"], "to": "active"})
    check(R, "retired cannot come back (409)", st == 409, st)
    # scopes
    st, h, b = get(s, ana, f"/panel/atom?id={ids['synb']}")
    st2, h2, b2 = get(s, ana, "/panel/atoms?q=zebra")
    check(R, "seat sees only its scopes (other-scope atom 404, absent from search + subject chips)", st == 404 and st2 == 200 and "Zed hides" not in b2 and ">zed<" not in b2 and "No memories match" in b2, (st, st2))
    st, h, b = get(s, adm, "/panel/queue")
    check(R, "queue page: states + jobs + pending count", all(k in b for k in ["queued", "dead", "awaiting review", "job #"]), st)
    st, h, b = get(s, adm, "/panel/health")
    check(R, "health page: hub counts + retriever + sessions", all(k in b for k in ["rows.atoms", "retriever", "panel.sessions"]), st)
    # seats
    st, h, b = get(s, ana, "/panel/seats")
    check(R, "non-admin sees only its own seat", ">ana<" in b and ">adm<" not in b and "New seat" not in b, st)
    st, h, b = post(s, ana, "/panel/seats/create", {"seat": "sneaky", "scopes": "person:ana,person:ben", "admin": "1"})
    check(R, "non-admin cannot create a seat (403)", st == 403, st)
    st, h, b = post(s, adm, "/panel/seats/create", {"seat": "newseat", "scopes": "person:ana", "writes": "1"})
    toks = re.findall(r"zm_[0-9a-f]{64}", b)
    check(R, "admin creates a seat; token shown once in the response", st == 200 and len(set(toks)) == 1, (st, len(toks)))
    newtok = toks[0] if toks else ""
    TOKENS["newseat"] = newtok
    RESP[-1]["token_page"] = True
    line = [l for l in open(os.path.join(s.home, "tokens")).read().splitlines() if l.startswith("newseat\t")]
    check(R, "token file stores only the sha256 (0600)", line and hashlib.sha256(newtok.encode()).hexdigest() in line[0] and newtok not in open(os.path.join(s.home, "tokens")).read() and oct(os.stat(os.path.join(s.home, "tokens")).st_mode & 0o777) == "0o600", line)
    st, h, b = get(s, adm, "/panel/seats")
    check(R, "token not shown again on the seats page", newtok not in b and "newseat" in b, st)
    c = http.client.HTTPConnection("127.0.0.1", s.port, timeout=15)
    c.request("POST", "/v1/recall", body=json.dumps({"query": "lantern"}), headers={"Authorization": f"Bearer {newtok}", "Content-Type": "application/json"})
    r = c.getresponse(); rb = r.read(); c.close()
    check(R, "new token works on the API", r.status == 200, r.status)
    NL = login(s, "newseat")
    st, h, b = post(s, adm, "/panel/seats/revoke", {"seat": "newseat"})
    c = http.client.HTTPConnection("127.0.0.1", s.port, timeout=15)
    c.request("POST", "/v1/recall", body=json.dumps({"query": "lantern"}), headers={"Authorization": f"Bearer {newtok}", "Content-Type": "application/json"})
    r = c.getresponse(); r.read(); c.close()
    st2, h2, b2 = get(s, NL, "/panel/atoms")
    check(R, "panel revoke: API 401 at once, its panel session ends", st == 303 and r.status == 401 and st2 == 303, (st, r.status, st2))
    st, h, b = post(s, adm, "/panel/seats/revoke", {"seat": "adm"})
    check(R, "a seat cannot revoke itself from the panel", st == 400, st)
    ids_after = {r[0] for r in s.sql("SELECT id FROM atoms")}
    check(R, "nothing deleted: every atom id still present, count only grew", ids_before <= ids_after and len(ids_after) >= n_before, (n_before, len(ids_after)))
    st, h, b = post(s, adm, "/panel/logout", {})
    st2, h2, b2 = get(s, adm, "/panel/atoms")
    check(R, "logout ends the session", st == 303 and st2 == 303, (st, st2))
    return R


def gate_secrets(s, browser_seen):
    R = []
    tok_file = open(os.path.join(s.home, "tokens")).read()
    hashes = set(re.findall(r"\t([0-9a-f]{64})\t", tok_file))
    secrets_ = {f"token:{k}": v for k, v in TOKENS.items() if v}
    for hx in hashes:
        secrets_[f"hash:{hx[:8]}"] = hx
        secrets_[f"HASH:{hx[:8]}"] = hx.upper()
    sess = [x for x in SESSIONS if x]
    every = [("py", r) for r in RESP] + [("browser", {"path": x["url"], "status": x["status"], "headers": [(h["name"], h["value"]) for h in x["headers"]], "body": x["body"] or b""}) for x in browser_seen]
    hits, zm_hits, sess_hits = [], [], []
    for src, r in every:
        body = r["body"].decode("utf-8", "replace") if isinstance(r["body"], bytes) else r["body"]
        hdrs = "\n".join(f"{k}: {v}" for k, v in r["headers"])
        text_all = body + "\n" + hdrs
        for name, v in secrets_.items():
            if v in text_all:
                if name.startswith("token:newseat") and r.get("token_page"):
                    continue
                hits.append((src, r["path"], name))
        for m in re.findall(r"zm_[0-9a-f]{64}", text_all):
            if not r.get("token_page"):
                zm_hits.append((src, r["path"]))
        for sv in sess:
            if sv in body:
                sess_hits.append((src, r["path"], "body"))
            for k, v in r["headers"]:
                if sv in v and not (k.lower() == "set-cookie" and v.startswith("zm_sess=" + sv)):
                    sess_hits.append((src, r["path"], k))
    check(R, f"0 seat tokens / token hashes in {len(every)} served responses (bodies + headers), creation page excepted", not hits, hits[:10])
    check(R, "0 zm_<64 hex> strings outside the one creation page", not zm_hits, zm_hits[:10])
    check(R, "session ids appear only in their own Set-Cookie header", not sess_hits, sess_hits[:10])
    tp = [r for r in RESP if r.get("token_page")]
    check(R, "the creation page carried exactly the new token, once", len(tp) == 1 and len(re.findall(r"zm_[0-9a-f]{64}", tp[0]["body"].decode())) == 1, len(tp))
    al = open(os.path.join(s.home, "audit.log")).read()
    check(R, "audit.log holds no token, hash or session id", not any(v in al for v in list(secrets_.values()) + sess), None)
    return R


def main():
    args = sys.argv[1:]
    bin_ = os.path.join(SCR, "zigmem")
    port, tag, only = 18196, "panel", None
    if "--bin" in args:
        bin_ = args[args.index("--bin") + 1]
    if "--port" in args:
        port = int(args[args.index("--port") + 1])
    if "--tag" in args:
        tag = args[args.index("--tag") + 1]
    if "--only" in args:
        only = set(args[args.index("--only") + 1].split(","))
    want = lambda g: only is None or g in only
    s = Srv(bin_, port, tag)
    s.token("adm", "person:ana,person:ben", "--writes", "--trusted", "--admin", person="ana")
    s.token("ana", "person:ana", "--writes", person="ana")
    s.token("ro", "person:ana")
    s.token("ben", "person:ben", "--writes", "--trusted", person="ben")
    hh = {"members": [{"id": "sam", "display": "Pat Synth", "role": "principal", "relation": "father"},
                      {"id": "ana", "display": "Ana Synth", "role": "child"}, {"id": "ben", "display": "Ben Synth", "role": "child"}],
          "seats": [{"name": n, "member": m} for n, m in [("adm", "sam"), ("ana", "ana"), ("ro", "ana"), ("ben", "ben"), ("victim", "ana"), ("newseat", "ana"), ("sneaky", "ana"), ("evil", "ana")]]}
    json.dump(hh, open(os.path.join(s.home, "household.json"), "w"))
    subprocess.run([s.bin, "household", "bootstrap", "--home", s.home, "--file", os.path.join(s.home, "household.json")], check=True, capture_output=True)
    s.start()
    out = {"bin": bin_, "bin_sha256": hashlib.sha256(open(bin_, "rb").read()).hexdigest(), "port": port, "gates": {}}
    try:
        ids = seed(s)
        adm, ana, ro = login(s, "adm"), login(s, "ana"), login(s, "ro")
        if want("auth"):
            out["gates"]["auth"] = gate_auth(s, ids)
        if want("csrf"):
            out["gates"]["csrf"] = gate_csrf(s, ids, adm, ana)
        br = browser_gates(s, ids, adm, do_csrf=want("csrf"), do_xss=want("xss") or want("secrets"), do_mobile=want("mobile"))
        if want("csrf"):
            out["gates"]["csrf"] += br["csrf"]
        if want("xss"):
            out["gates"]["xss"] = br["xss"] + raw_xss()
        if want("mobile"):
            out["gates"]["mobile"] = br["mobile"]
        if want("function"):
            out["gates"]["function"] = gate_function(s, ids, adm, ana, ro)
        if want("secrets"):
            out["gates"]["secrets"] = gate_secrets(s, br["seen"]) + br["secrets"]
    finally:
        s.stop()
    out["stops"] = STOPS
    out["summary"] = {g: f"{sum(r['ok'] for r in rs)}/{len(rs)}" for g, rs in out["gates"].items()}
    green = all(r["ok"] for rs in out["gates"].values() for r in rs)
    out["verdict"] = "GREEN" if green else "RED"
    for g, rs in out["gates"].items():
        for r in rs:
            if isinstance(r.get("detail"), (bytes, bytearray)):
                r["detail"] = repr(r["detail"])
    with open(os.path.join(REC, tag + ".json"), "w") as f:
        json.dump(out, f, indent=1, default=str)
    print(json.dumps(out["summary"]), out["verdict"])
    sys.exit(0 if green else 1)


if __name__ == "__main__":
    main()
