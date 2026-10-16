#!/usr/bin/env python3
"""zigmem phase-7 gate: every adapter end to end where its tool exists here, and "no other tool's files modified".

Stages (each writes receipts/phase7/<stage>.json; synthetic data only, invented people ana/ben, scopes syn-*):
  snap_before  sha256 of ~/.claude/settings.json, ~/.pi/, ~/.codex/, ~/.openclaw/ (+ ~/.hermes if present), ~/.claude.json parsed
  connect      `zigmem connect <tool> --print` for the 6 tools, refusals
  hub          start zigmem serve (127.0.0.1:18160, extract primary x1 worker, proxy 18161 for seat-proxy)
  cc_helper    Claude Code via headersHelper: add-json --scope local in a scratch dir, claude -p store, extract, claude -p recall, remove
  cc_header    Claude Code via plain --header: same round trip, token in ~/.claude.json only while registered
  pi           staged pi extension in a throwaway pi (PI_CODING_AGENT_DIR = scratch), store then recall
  proxy        python + curl clients through the zigmem proxy to the primary engine, vs the same request direct
  codex/openclaw  snippet parse-check in ISOLATED homes (CODEX_HOME / OPENCLAW_CONFIG_PATH in scratch), no model run
  stop + snap_after + diff
"""
import hashlib, json, os, signal, sqlite3, subprocess, sys, time, urllib.request

HOME = os.path.expanduser("~")
ROOT = f"{HOME}/zigmem"
Z = f"{ROOT}/scratch/p7/out/bin/zigmem"
S = f"{ROOT}/scratch/p7"
R = f"{ROOT}/receipts/phase7"
NODE = f"{HOME}/.nvm/versions/node/v22.22.3/bin"
ENV = dict(os.environ, PATH=f"{NODE}:{HOME}/.local/bin:" + os.environ.get("PATH", ""))
CLAUDE = f"{NODE}/claude"
PORT, PPORT = 18160, 18161
ENGINE = "http://127.0.0.1:18080"
HUBHOME = f"{S}/home"
TOKDIR = f"{S}/tokens"
os.makedirs(R, exist_ok=True)
STOPS = []
TOKS = []
RESULTS = {}


def receipt(name, obj):
    with open(f"{R}/{name}.json", "w") as f:
        json.dump(obj, f, indent=1, default=str)


def run(cmd, timeout=300, cwd=None, env=None, input=None):
    t = time.time()
    p = subprocess.run(cmd, cwd=cwd, env=env or ENV, capture_output=True, text=True, timeout=timeout, input=input)
    return {"cmd": cmd if isinstance(cmd, str) else " ".join(cmd), "rc": p.returncode, "out": p.stdout[-4000:], "err": p.stderr[-2000:], "s": round(time.time() - t, 2)}


# ---------- snapshots ----------
def tree(path):
    out = {}
    if not os.path.exists(path):
        return {"__absent__": True}
    if os.path.isfile(path):
        return {path: sha(path)}
    for d, _, fs in os.walk(path):
        for f in fs:
            p = os.path.join(d, f)
            if os.path.islink(p) or not os.path.isfile(p):
                out[p] = "link-or-special:" + (os.readlink(p) if os.path.islink(p) else "?")
                continue
            try:
                out[p] = sha(p)
            except OSError as e:
                out[p] = "unreadable:" + str(e)
    return out


def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def snapshot():
    snap = {k: tree(f"{HOME}/{k}") for k in [".claude/settings.json", ".pi", ".codex", ".openclaw", ".hermes"]}
    with open(f"{HOME}/.claude.json") as f:
        snap["claude_json"] = json.load(f)
    snap["claude_json_sha"] = sha(f"{HOME}/.claude.json")
    return snap


def jdiff(a, b, path=""):
    out = []
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            p = f"{path}/{k}"
            if k not in a:
                out.append(("added", p))
            elif k not in b:
                out.append(("removed", p))
            else:
                out += jdiff(a[k], b[k], p)
    elif a != b:
        out.append(("changed", path))
    return out


# ---------- hub ----------
def token_add(seat, scopes, *flags):
    r = run([Z, "token", "add", "--home", HUBHOME, "--seat", seat, "--scopes", scopes, *flags])
    assert r["rc"] == 0, r
    tok = r["out"].strip()
    p = f"{TOKDIR}/{seat}.token"
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, (tok + "\n").encode())
    os.close(fd)
    return tok, p


def http(method, path, body=None, tok=None, port=PORT, headers=None, timeout=30):
    h = {"Content-Type": "application/json", **(headers or {})}
    if tok:
        h["Authorization"] = f"Bearer {tok}"
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method, headers=h,
                                 data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")


def spark_busy():
    try:
        with urllib.request.urlopen(f"{ENGINE}/metrics", timeout=5) as r:
            txt = r.read().decode()
        v = {}
        for line in txt.splitlines():
            for k in ("vllm:num_requests_running{", "vllm:num_requests_waiting{"):
                if line.startswith(k):
                    v[k[:-1]] = float(line.rsplit(" ", 1)[1])
        return v
    except Exception as e:
        return {"error": str(e)}


def db():
    return sqlite3.connect(f"file:{HUBHOME}/zigmem.db?mode=ro", uri=True)


def wait_jobs(timeout=240):
    t = time.time()
    while time.time() - t < timeout:
        con = db()
        n = con.execute("SELECT count(*) FROM jobs WHERE state IN ('queued','running')").fetchone()[0]
        con.close()
        if n == 0:
            return round(time.time() - t, 1)
        time.sleep(2)
    return None


def atoms(scope):
    con = db()
    rows = con.execute("SELECT id, subject, scope, status, text FROM atoms WHERE scope = ?", (scope,)).fetchall()
    con.close()
    return rows


def claude_p(cwd, prompt, tools, sources="project,local"):
    # user-scope MCP servers load only with the user setting source; every hook stays off (disableAllHooks, flag settings win)
    return run([CLAUDE, "-p", prompt, "--setting-sources", sources, "--settings", '{"disableAllHooks":true}',
                "--allowedTools", ",".join(tools), "--output-format", "text"], timeout=400, cwd=cwd)


def claude_mcp(cwd, *args):
    return run([CLAUDE, "mcp", *args], timeout=120, cwd=cwd)


def cc_stage(name, register_cmd, scope, seat_tok, fact, keyword, seat_token_file, cc_scope):
    cwd = f"{S}/{name}_client"
    os.makedirs(cwd, exist_ok=True)
    rows = {}
    log = {"register": None}
    r = run(register_cmd, cwd=cwd, timeout=120)
    log["register"] = {k: r[k] for k in ("cmd", "rc", "out", "err")}
    log["register"]["cmd"] = log["register"]["cmd"].replace(seat_tok, "<TOKEN>")
    lst = claude_mcp(cwd, "list")
    log["list"] = [l for l in lst["out"].splitlines() if "zigmem" in l]
    rows["registered + Connected"] = any("zigmem" in l and "Connected" in l for l in log["list"])
    with open(f"{HOME}/.claude.json") as f:
        cj = f.read()
    rows["token absent from ~/.claude.json while registered" if name == "cc_helper" else "token present in ~/.claude.json while registered (expected for --header)"] = \
        (seat_tok not in cj) if name == "cc_helper" else (seat_tok in cj)
    store = claude_p(cwd, f"Use the zigmem MCP server. Call its memory_add tool with text exactly \"{fact}\" and session_key \"{name}\". "
                          "Then reply with exactly one line: STORED=<the result status or message from the tool>.",
                     ["mcp__zigmem__memory_add"], "user,project,local" if cc_scope == "user" else "project,local")
    log["store"] = store
    rows["claude -p #1 rc 0"] = store["rc"] == 0
    log["spark_after_store"] = spark_busy()
    log["extract_wait_s"] = wait_jobs()
    log["atoms"] = atoms(scope)
    rows["extraction made an atom with the fact"] = any(keyword.lower() in a[4].lower() for a in log["atoms"])
    recall = claude_p(cwd, f"Use the zigmem MCP server. Call its memory_search tool with query \"{keyword}\". "
                           "Reply with exactly one line: FOUND=<text of the first hit> or FOUND=NONE.",
                      ["mcp__zigmem__memory_search"], "user,project,local" if cc_scope == "user" else "project,local")
    log["recall"] = recall
    rows["claude -p #2 (fresh process) recalls the fact"] = recall["rc"] == 0 and keyword.lower() in recall["out"].lower()
    rm = claude_mcp(cwd, "remove", "--scope", cc_scope, "zigmem")
    log["remove"] = {k: rm[k] for k in ("rc", "out", "err")}
    lst2 = claude_mcp(cwd, "list")
    rows["after remove: not listed"] = "zigmem" not in lst2["out"]
    with open(f"{HOME}/.claude.json") as f:
        cj = json.load(f)
    proj = cj.get("projects", {}).get(cwd, {})
    rows["after remove: no zigmem key in the project's mcpServers"] = "zigmem" not in (proj.get("mcpServers") or {})
    rows["after remove: no zigmem key in the user mcpServers"] = "zigmem" not in (cj.get("mcpServers") or {})
    rows["after remove: token absent from ~/.claude.json"] = seat_tok not in json.dumps(cj)
    log["rows"] = rows
    receipt(name, log)
    RESULTS[name] = rows
    return rows


def main():
    stages = sys.argv[1:] or ["all"]
    before = snapshot()
    with open(f"{S}/snap_before.json", "w") as f:
        json.dump(before, f)
    print("snapshot before:", {k: len(v) if isinstance(v, dict) else v for k, v in before.items() if k != "claude_json"})

    # --- connect CLI
    c = {t: run([Z, "connect", t, "--print"]) for t in ["claude-code", "pi", "openai", "codex", "openclaw", "hermes"]}
    refuse = run([Z, "connect", "claude-code"])
    bad = run([Z, "connect", "pi", "--print", "--url", "http://0.0.0.0:8470"])
    RESULTS["connect"] = {
        "6/6 tools print, rc 0": all(v["rc"] == 0 and len(v["out"]) > 200 for v in c.values()),
        "no --print → rc 2, nothing on stdout": refuse["rc"] == 2 and refuse["out"] == "",
        "0.0.0.0 url → rc 2, nothing on stdout": bad["rc"] == 2 and bad["out"] == "",
    }
    receipt("connect", {"runs": c, "refuse": refuse, "bad_url": bad, "rows": RESULTS["connect"]})

    # --- hub
    subprocess.run(["rm", "-rf", HUBHOME, TOKDIR])
    os.makedirs(TOKDIR, mode=0o700)
    tok_cc, f_cc = token_add("seat-cc", "syn-cc", "--writes")
    tok_cc2, f_cc2 = token_add("seat-cc2", "syn-cc2", "--writes")
    tok_pi, f_pi = token_add("seat-pi", "syn-pi", "--writes")
    tok_px, f_px = token_add("seat-proxy", "syn-px")
    TOKS.extend([tok_cc, tok_cc2, tok_pi, tok_px])
    for pid in ("ana", "ben"):
        assert run([Z, "people", "add", "--home", HUBHOME, "--id", pid, "--display", pid.title()])["rc"] == 0
    busy0 = spark_busy()
    log = open(f"{S}/serve.log", "w")
    sp = subprocess.Popen([Z, "serve", "--home", HUBHOME, "--port", str(PORT), "--extract", "primary", "--workers", "1",
                           "--proxy-upstream", ENGINE, "--proxy-port", str(PPORT), "--proxy-seat", "seat-proxy"],
                          stdout=log, stderr=subprocess.STDOUT, env=ENV)
    time.sleep(1.0)
    st, h = http("GET", "/health")
    print("hub up:", st, "pid", sp.pid, "primary-engine before:", busy0)
    try:
        if "all" in stages or "cc" in stages:
            helper = f"{ROOT}/adapters/claude-code/zigmem_headers.sh {f_cc}"
            cc_stage("cc_helper", [CLAUDE, "mcp", "add-json", "--scope", "user", "zigmem",
                                   json.dumps({"type": "http", "url": f"http://127.0.0.1:{PORT}/mcp", "headersHelper": helper})],
                     "syn-cc", tok_cc, "Ana keeps the copper kettle in the green attic.", "kettle", f_cc, "user")
            cc_stage("cc_header", [CLAUDE, "mcp", "add", "--scope", "local", "--transport", "http", "zigmem",
                                   f"http://127.0.0.1:{PORT}/mcp", "--header", f"Authorization: Bearer {tok_cc2}"],
                     "syn-cc2", tok_cc2, "Ben parks the red canoe behind the old mill.", "canoe", f_cc2, "local")
        if "all" in stages or "pi" in stages:
            pi_stage(f_pi)
        if "all" in stages or "proxy" in stages:
            proxy_stage()
        if "all" in stages or "iso" in stages:
            iso_stage()
    finally:
        sp.send_signal(signal.SIGTERM)
        try:
            sp.wait(5)
        except subprocess.TimeoutExpired:
            sp.kill()
            sp.wait(5)
        alive = os.path.exists(f"/proc/{sp.pid}")
        STOPS.append({"what": "zigmem serve", "pid": sp.pid, "alive_after": alive})
        log.close()
        lsn = run(["bash", "-c", "ss -ltn | grep -E ':(1816[0-9]|8470) ' || true"], timeout=10)
        STOPS.append({"listeners_18160-18169_8420": lsn["out"].strip()})
        audit = open(f"{HUBHOME}/audit.log").read().splitlines() if os.path.exists(f"{HUBHOME}/audit.log") else []
        receipt("audit_mcp_lines", [l for l in audit if "/mcp" in l][-80:])
    after = snapshot()
    diff = {}
    cjd = jdiff(before["claude_json"], after["claude_json"])
    for k in [".claude/settings.json", ".pi", ".codex", ".openclaw", ".hermes"]:
        a, b = before[k], after[k]
        ch = sorted(p for p in set(a) | set(b) if a.get(p) != b.get(p))
        diff[k] = ch
    RESULTS["no_foreign_files"] = {
        "~/.claude/settings.json identical": diff[".claude/settings.json"] == [],
        "~/.pi/ identical": diff[".pi"] == [],
        "~/.codex/ identical": diff[".codex"] == [],
        "~/.openclaw/ identical": diff[".openclaw"] == [],
        "~/.hermes absent before and after": before[".hermes"] == after[".hermes"] == {"__absent__": True},
        "~/.claude.json: 'zigmem' count unchanged (before vs after)": json.dumps(before["claude_json"]).count("zigmem") == json.dumps(after["claude_json"]).count("zigmem"),
        "~/.claude.json: no diff path under mcpServers (user or any project)": not any("mcpServers" in d[1] for d in cjd),
        "~/.claude.json: no test token anywhere after": not any(t in json.dumps(after["claude_json"]) for t in TOKS),
    }
    receipt("foreign_files", {"tree_diffs": diff, "claude_json_diff": cjd, "claude_json_sha": [before["claude_json_sha"], after["claude_json_sha"]],
                              "rows": RESULTS["no_foreign_files"]})
    receipt("summary", {"results": RESULTS, "stops": STOPS})
    ok = True
    for stage, rows in RESULTS.items():
        for k, v in rows.items():
            print(("ok  " if v else "FAIL"), stage, "|", k)
            ok &= bool(v)
    print("claude.json diff paths:", len(cjd))
    for d in cjd[:40]:
        print("   ", d)
    print("stops:", STOPS)
    print("GATE phase7", "GREEN" if ok else "RED")
    sys.exit(0 if ok else 1)


def pi_stage(f_pi):
    agent = f"{S}/piagent"
    cwd = f"{S}/pi_client"
    subprocess.run(["rm", "-rf", agent])
    os.makedirs(agent, mode=0o700)
    os.makedirs(cwd, exist_ok=True)
    with open(f"{agent}/models.json", "w") as f:
        json.dump({"providers": {"primary": {"baseUrl": f"{ENGINE}/v1", "api": "openai-completions", "apiKey": "unused",
                                              "compat": {"supportsDeveloperRole": False, "maxTokensField": "max_tokens"},
                                              "models": [{"id": "glm-5.3-flash", "name": "GLM-5.3-Flash (the primary engine, phase-7 test)",
                                                          "contextWindow": 131072, "maxTokens": 4096, "reasoning": True,
                                                          "input": ["text"], "temperature": 0.2}]}}}, f)
    env = dict(ENV, PI_CODING_AGENT_DIR=agent, PI_OFFLINE="1", PI_TELEMETRY="0", ZIGMEM_URL=f"http://127.0.0.1:{PORT}", ZIGMEM_TOKEN_FILE=f_pi)
    base = [f"{NODE}/pi", "--offline", "--no-session", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes",
            "--no-context-files", "-e", f"{ROOT}/adapters/pi/zigmem_memory.ts", "--model", "primary/glm-5.3-flash", "--thinking", "off"]
    rows, log = {}, {}
    fact, kw = "Ana hides the brass whistle inside the cedar box.", "whistle"
    log["store"] = run(base + ["--tools", "zigmem_memory_add", "-p",
                               f"Call the zigmem_memory_add tool with text \"{fact}\" and session_key \"p7pi\". Then reply with one line: STORED."],
                       timeout=300, cwd=cwd, env=env)
    rows["pi run #1 rc 0"] = log["store"]["rc"] == 0
    log["extract_wait_s"] = wait_jobs()
    log["atoms"] = atoms("syn-pi")
    rows["memory_add from pi reached zigmem (atom with the fact)"] = any(kw in a[4].lower() for a in log["atoms"])
    log["recall"] = run(base + ["--tools", "zigmem_memory_search", "-p",
                                f"Call the zigmem_memory_search tool with query \"{kw}\". Reply with one line: FOUND=<text of the first hit> or FOUND=NONE."],
                        timeout=300, cwd=cwd, env=env)
    rows["pi run #2 (fresh process) recalls the fact"] = log["recall"]["rc"] == 0 and kw in log["recall"]["out"].lower() and "cedar" in log["recall"]["out"].lower()
    rows["extension registers no pi.on hooks (source check)"] = "pi.on(" not in open(f"{ROOT}/adapters/pi/zigmem_memory.ts").read().replace("no pi.on(...)", "")
    log["agent_dir_files"] = sorted(os.listdir(agent))
    log["rows"] = rows
    receipt("pi", log)
    RESULTS["pi"] = rows


def proxy_stage():
    con = sqlite3.connect(f"{HUBHOME}/zigmem.db")
    con.execute("INSERT INTO persona(subject, scope, text, rev, built_ms) VALUES ('ana','syn-px',?,1,0)",
                ("Ana's synthetic test codeword is PELICAN-4471.",))
    con.commit()
    con.close()
    q = "What is Ana's synthetic test codeword? Answer with the codeword only, or UNKNOWN if you do not know it."
    client = f"{ROOT}/adapters/openai/zigmem_client.py"
    rows, log = {}, {"spark_before": spark_busy()}
    log["py_proxy"] = run(["python3", client, "--base", f"http://127.0.0.1:{PPORT}/v1", "--session", "p7a", "--no-thinking", q], timeout=180)
    log["spark_mid"] = spark_busy()
    body = json.dumps({"model": "glm-5.3-flash", "temperature": 0, "max_tokens": 64, "chat_template_kwargs": {"enable_thinking": False},
                       "messages": [{"role": "system", "content": "You are a helpful assistant. Answer in one short sentence."}, {"role": "user", "content": q}]})
    log["curl_proxy"] = run(["curl", "-s", "-m", "120", f"http://127.0.0.1:{PPORT}/v1/chat/completions", "-H", "Content-Type: application/json",
                             "-H", "x-zigmem-session: p7b", "-d", body], timeout=180)
    log["curl_direct_engine"] = run(["curl", "-s", "-m", "120", f"{ENGINE}/v1/chat/completions", "-H", "Content-Type: application/json", "-d", body], timeout=180)

    def content(r):
        try:
            return json.loads(r["out"])["choices"][0]["message"]["content"] or ""
        except Exception:
            return r["out"][:300]
    log["curl_proxy_answer"] = content(log["curl_proxy"])
    log["curl_direct_answer"] = content(log["curl_direct_engine"])
    rows["python client through proxy answers PELICAN-4471"] = log["py_proxy"]["rc"] == 0 and "PELICAN-4471" in log["py_proxy"]["out"]
    rows["curl through proxy answers PELICAN-4471"] = "PELICAN-4471" in log["curl_proxy_answer"]
    rows["same request direct to the primary engine does NOT know it (control)"] = "PELICAN-4471" not in log["curl_direct_answer"]
    rows["the primary engine never above 2 in flight at samples"] = all((v.get("vllm:num_requests_running") or 0) <= 2 for v in (log["spark_before"], log["spark_mid"]) if "error" not in v)
    log["rows"] = rows
    receipt("proxy", log)
    RESULTS["proxy"] = rows


def iso_stage():
    rows, log = {}, {}
    ch = f"{S}/codexhome"
    subprocess.run(["rm", "-rf", ch])
    os.makedirs(ch, mode=0o700)
    env = dict(ENV, CODEX_HOME=ch)
    log["codex_add"] = run(["codex", "mcp", "add", "zigmem", "--url", f"http://127.0.0.1:{PORT}/mcp", "--bearer-token-env-var", "ZIGMEM_TOKEN"], env=env, timeout=60)
    log["codex_get"] = run(["codex", "mcp", "get", "zigmem", "--json"], env=env, timeout=60)
    cfg = open(f"{ch}/config.toml").read() if os.path.exists(f"{ch}/config.toml") else ""
    log["codex_config_written_in_isolated_home"] = cfg
    snippet = open(f"{ROOT}/adapters/codex/config.toml.snippet").read()
    import tomllib
    a = tomllib.loads(cfg).get("mcp_servers", {}).get("zigmem") if cfg else None
    b = tomllib.loads(snippet).get("mcp_servers", {}).get("zigmem")
    b = dict(b, url=f"http://127.0.0.1:{PORT}/mcp")
    log["codex_parsed"] = {"codex_wrote": a, "our_snippet": b}
    rows["codex: its own `mcp add` writes exactly our snippet's table (isolated CODEX_HOME)"] = a == b
    rows["codex: `mcp get` reads it back"] = log["codex_get"]["rc"] == 0 and "ZIGMEM_TOKEN" in log["codex_get"]["out"]
    oc = f"{S}/ochome"
    subprocess.run(["rm", "-rf", oc])
    os.makedirs(oc, mode=0o700)
    env2 = dict(ENV, OPENCLAW_CONFIG_PATH=f"{oc}/openclaw.json", OPENCLAW_STATE_DIR=oc)
    srv = json.loads(open(f"{ROOT}/adapters/openclaw/mcp-server.json").read())
    srv["url"] = f"http://127.0.0.1:{PORT}/mcp"
    srv["headers"]["Authorization"] = "Bearer zm_SYNTHETIC_NOT_A_REAL_TOKEN"
    log["oc_set"] = run(["openclaw", "mcp", "set", "zigmem", json.dumps(srv)], env=env2, timeout=120)
    log["oc_show"] = run(["openclaw", "mcp", "show", "zigmem"], env=env2, timeout=120)
    ocfg = json.load(open(f"{oc}/openclaw.json")) if os.path.exists(f"{oc}/openclaw.json") else {}
    got = ocfg.get("mcp", {}).get("servers", {}).get("zigmem")
    log["oc_config_written_in_isolated_home"] = ocfg
    rows["openclaw: its own `mcp set` accepts our JSON (isolated OPENCLAW_CONFIG_PATH)"] = log["oc_set"]["rc"] == 0 and got is not None and got.get("url") == srv["url"] and got.get("transport") == "streamable-http"
    log["oc_unset"] = run(["openclaw", "mcp", "unset", "zigmem"], env=env2, timeout=120)
    log["files_in_isolated_homes"] = {"codex": sorted(os.listdir(ch)), "openclaw": sorted(os.listdir(oc))}
    log["rows"] = rows
    receipt("iso_codex_openclaw", log)
    RESULTS["iso"] = rows


if __name__ == "__main__":
    main()
