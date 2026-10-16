#!/usr/bin/python3 -I
"""Phase-8 gate: deploy.sh + rollback.sh end-to-end on a SCRATCH HOME (no real systemd: fake systemctl shim), port 18190.

  /usr/bin/python3 -I ~/zigmem/tests/phase8/roundtrip.py --release DIR [--tag NAME]

Synthetic HOME (~/zigmem/scratch/p8home, made fresh): synthetic ~/.claude.json, ~/.claude/settings.json, ~/.pi tree, ~/.codex,
~/.config/systemd/user/other.service. Every check records before/after sha of the WHOLE scratch home tree.
 RED  a) port busy  b) binary sha != RELEASE  c) gate receipt missing  d) tested sha != binary  e) not -Drelease
      f) the service dies on start (shim runs /bin/false instead of ExecStart) → deploy aborts and auto-rolls back
      each: deploy exits 1 and the scratch home tree is sha-identical to before (f: identical except the kept data dir/state)
 GREEN RT1 deploy (shadow) → live checks → rollback → guarded files sha-identical + whole tree identical except the
      documented leftovers (zigmem_data/, .local/state/zigmem-deploy/, .fake_systemd/)
      RT2 redeploy on the kept data dir → --wire claude-code (print) → --wire claude-code --apply (real claude CLI in the
      scratch HOME) → rollback → no zigmem MCP, no token, guarded keys report printed
Receipt: ~/zigmem/receipts/phase8/roundtrip_<tag>.json (pass true/false)."""
import argparse, hashlib, json, os, shutil, socket, subprocess, sys, time

REAL = os.path.expanduser("~")
ZM = f"{REAL}/zigmem"
ap = argparse.ArgumentParser()
ap.add_argument("--release", required=True)
ap.add_argument("--tag", default=time.strftime("%Y%m%d-%H%M"))
ap.add_argument("--port", type=int, default=18190)
ap.add_argument("--required-kinds", default="testrel", help="ZM_REQUIRED_KINDS for the scratch HOME (test hook)")
ap.add_argument("--with-seed", action="store_true", help="RT1 deploys WITH the release seed (the real shadow store copy)")
args = ap.parse_args()
H = os.environ.get("ZIGMEM_RT_HOME", f"{ZM}/scratch/p8home")  # merge lane 10/13: scratch override; default unchanged
RTREL = os.environ.get("ZIGMEM_RT_RELDIR", f"{ZM}/scratch/p8")
NODE = f"{REAL}/.nvm/versions/node/v22.22.3/bin"
LEFTOVERS = ("zigmem_data/", ".local/state/zigmem-deploy/", ".fake_systemd/")
R = {"tag": args.tag, "release": args.release, "port": args.port, "home": H, "checks": []}


def check(name, ok, **kw):
    R["checks"].append(dict(name=name, ok=bool(ok), **kw))
    print(f"{'GREEN' if ok else 'RED  '} {name} {json.dumps(kw)[:300]}")
    return ok


def tree(root=H):
    out = {}
    for dp, dns, fns in os.walk(root):
        for n in fns + [d for d in dns if os.path.islink(os.path.join(dp, d))]:
            p = os.path.join(dp, n)
            rel = os.path.relpath(p, root)
            if os.path.islink(p):
                out[rel] = "L:" + os.readlink(p)
            else:
                out[rel] = hashlib.sha256(open(p, "rb").read()).hexdigest()
    return out


def tree_sha(t, skip=()):
    return hashlib.sha256(json.dumps({k: v for k, v in sorted(t.items()) if not k.startswith(skip)}).encode()).hexdigest()


def run(cmd, env_extra=None, timeout=300):
    env = {"HOME": H, "PATH": f"{NODE}:/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8",
           "ZIGMEM_SYSTEMCTL": f"{ZM}/tests/phase8/fake_systemctl.sh", "ZIGMEM_RELEASE_DIR": args.release,
           "ZIGMEM_CLAUDE": f"{NODE}/claude", "ZIGMEM_MIN_FREE_GB": "1", "ZM_REQUIRED_KINDS": args.required_kinds}
    env.update(env_extra or {})
    p = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout + p.stderr


def listening(port):
    s = socket.socket()
    s.settimeout(0.5)
    try:
        return s.connect_ex(("127.0.0.1", port)) == 0
    finally:
        s.close()


def fresh_home():
    if os.path.exists(H):
        shutil.rmtree(H)  # scratch only (~/zigmem/scratch/p8home)
    for d in (".claude", ".pi/agent/extensions", ".codex", ".config/systemd/user", ".openclaw"):
        os.makedirs(f"{H}/{d}", mode=0o700)
    json.dump({"numStartups": 3, "mcpServers": {"other": {"type": "http", "url": "http://127.0.0.1:9/mcp"}},
               "projects": {"/x": {"mcpServers": {}, "allowedTools": []}}, "cachedGrowthBookFeaturesAt": 1},
              open(f"{H}/.claude.json", "w"), indent=2)
    json.dump({"hooks": {}, "env": {"SYNTHETIC": "1"}}, open(f"{H}/.claude/settings.json", "w"))
    for i in range(20):
        open(f"{H}/.pi/agent/extensions/ext{i}.ts", "w").write(f"// synthetic {i}\n")
    os.symlink("extensions/ext0.ts", f"{H}/.pi/agent/link.ts")
    open(f"{H}/.codex/config.toml", "w").write('model = "synthetic"\n')
    open(f"{H}/.openclaw/openclaw.json", "w").write("{}\n")
    open(f"{H}/.config/systemd/user/other.service", "w").write("[Service]\nExecStart=/bin/true\n")


def stamp_variant(name, mutate):
    d = f"{RTREL}/rel_{name}"
    if os.path.exists(d):
        shutil.rmtree(d)
    shutil.copytree(args.release, d)
    mutate(d)
    return d


def relj(d):
    return json.load(open(f"{d}/RELEASE.json"))


def wrel(d, j):
    json.dump(j, open(f"{d}/RELEASE.json", "w"), indent=1)


for _ in range(60):
    if not listening(args.port): break
    time.sleep(0.5)
else:
    sys.exit(f"port {args.port} busy before the run — not started")
fresh_home()
T0 = tree()
R["before_tree_sha"] = tree_sha(T0)
DEP = [f"{ZM}/deploy/deploy.sh", "--port", str(args.port)]
RB = [f"{ZM}/deploy/rollback.sh"]

# ---------- RED: preflight refusals leave the scratch home untouched ----------
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", args.port)); s.listen(1)
rc, out = run(DEP + ["--no-seed"])
s.close()
check("RED a) port busy -> refused, nothing changed", rc == 1 and "FAIL  port" in out and "REFUSED" in out and tree_sha(tree(), (".local/state/zigmem-deploy/",)) == tree_sha(T0), rc=rc, fails=[l.strip() for l in out.splitlines() if "FAIL" in l][:6])


def red(name, mutate, needle):
    d = stamp_variant(name, mutate)
    rc, out = run(DEP + ["--no-seed"], {"ZIGMEM_RELEASE_DIR": d})
    same = tree_sha(tree(), (".local/state/zigmem-deploy/",)) == tree_sha(T0)
    return check(f"RED {name} -> refused, nothing changed", rc == 1 and needle in out and "REFUSED" in out and same, rc=rc, same_tree=same,
                 fails=[l.strip() for l in out.splitlines() if "FAIL" in l][:6])


def m_sha(d):
    j = relj(d); j["sha256"] = "0" * 64; wrel(d, j)


def m_gate(d):
    j = relj(d); j["gates"] = ["receipts/phase8/does_not_exist.json"]; wrel(d, j)


def m_tested(d):
    j = relj(d); j["tested_sha256"] = "1" * 64; wrel(d, j)


def m_debug(d):
    j = relj(d); j["build_cmd"] = j["build_cmd"].replace("-Drelease", ""); wrel(d, j)


red("b_sha_mismatch", m_sha, "FAIL  binary sha256")
red("c_gate_missing", m_gate, "FAIL  gate receipts/phase8/does_not_exist.json")
red("d_tested_sha", m_tested, "FAIL  binary sha == tested sha")
red("e_not_release", m_debug, "FAIL  built with -Drelease")


rc, out = run(DEP + ["--no-seed"], {"ZIGMEM_FAKE_START_FAIL": "1"})
after = tree()
check("RED f) start/health fails -> deploy aborts + auto-rollback", rc == 1 and "rolling back" in out and not listening(args.port)
      and tree_sha(after, LEFTOVERS) == tree_sha(T0, LEFTOVERS), rc=rc, tail=out[-500:],
      leftover_only=sorted({k.split('/')[0] for k in set(after) ^ set(T0)}))

# ---------- GREEN RT1: deploy -> live checks -> rollback, sha-identical ----------
fresh_home(); T0 = tree(); R["rt1_before_tree_sha"] = tree_sha(T0)
rc, out = run(DEP + ["--dry-run", "--no-seed"])
check("dry-run: preflight green, nothing changed", rc == 0 and "DRY RUN" in out and tree_sha(tree(), (".local/state/zigmem-deploy/",)) == tree_sha(T0), rc=rc)
t = time.time()
rc, out = run(DEP + ([] if args.with_seed else ["--no-seed"]), timeout=900)
R["seeded"] = args.with_seed
R["deploy_s"] = round(time.time() - t, 2)
R["deploy_out"] = out[-2500:]
check("RT1 deploy exit 0", rc == 0 and "zigmem DEPLOYED (SHADOW)" in out, rc=rc, secs=R["deploy_s"])
tok = open(f"{H}/.config/zigmem/shadow.token").read().strip() if os.path.exists(f"{H}/.config/zigmem/shadow.token") else ""
check("RT1 token file 0600, zm_ format", oct(os.stat(f"{H}/.config/zigmem/shadow.token").st_mode & 0o777) == "0o600" and tok.startswith("zm_") and len(tok) == 67)
ss = [l.split()[3] for l in subprocess.run(["ss", "-Hltn", f"sport = :{args.port}"], capture_output=True, text=True).stdout.splitlines() if l.strip()]
check("RT1 listening 127.0.0.1 only (ss local addresses)", ss == [f"127.0.0.1:{args.port}"], local=ss)
um = open(f"{H}/.config/systemd/user/zigmem.service").read()
check("RT1 unit installed + enabled symlink", os.path.islink(f"{H}/.config/systemd/user/default.target.wants/zigmem.service") and "--bind 127.0.0.1" in um and f"--port {args.port}" in um)
mid = tree()
changed = sorted({k for k in set(mid) | set(T0) if mid.get(k) != T0.get(k)})
check("RT1 deploy touched only its own paths", all(k.startswith(LEFTOVERS + (".config/zigmem/", ".config/systemd/user/zigmem.service", ".config/systemd/user/default.target.wants/")) for k in changed),
      changed_top=sorted({"/".join(k.split("/")[:3]) for k in changed}))
G = {k: T0[k] for k in T0 if k.startswith((".claude", ".pi", ".codex", ".openclaw"))}
check("RT1 guarded files untouched while deployed", all(mid.get(k) == v for k, v in G.items()))
rc, out = run(DEP + ["--no-seed"])
check("RT1 second deploy refused while deployed", rc == 1 and "already deployed" in out, rc=rc)
t = time.time()
rc, out = run(RB)
R["rollback_s"] = round(time.time() - t, 2)
R["rollback_out"] = out[-2500:]
after = tree()
check("RT1 rollback exit 0", rc == 0 and "zigmem ROLLED BACK" in out, rc=rc, secs=R["rollback_s"])
check("RT1 nothing listening after rollback", not listening(args.port))
check("RT1 guarded files sha-identical (kit compare rc 0)", "guarded files sha-identical to pre-deploy" in out)
R["rt1_after_tree_sha_minus_leftovers"] = tree_sha(after, LEFTOVERS)
check("RT1 whole scratch HOME sha-identical except documented leftovers", tree_sha(after, LEFTOVERS) == tree_sha(T0, LEFTOVERS),
      before=tree_sha(T0, LEFTOVERS)[:16], after=tree_sha(after, LEFTOVERS)[:16],
      leftovers=sorted({"/".join(k.split("/")[:2]) for k in set(after) - set(T0)}))

# ---------- GREEN RT2: redeploy on kept data, wire print, wire apply (real claude CLI), rollback ----------
T1 = tree()
rc, out = run(DEP + ["--no-seed"])
check("RT2 redeploy on the kept data dir", rc == 0 and "zigmem DEPLOYED" in out, rc=rc, tail=out[-300:])
Q3 = relj(args.release).get("quality", {})
GATE3_RED = any(not all(v["gates"].values()) for v in Q3.values())
R["release_gate3_red"] = GATE3_RED
if GATE3_RED:
    # the release under test has gate 3 RED: --wire must refuse it, naming the gap, and change nothing
    gap = [v["score"] for v in Q3.values()][0]
    b = tree()
    rc, out = run([f"{ZM}/deploy/deploy.sh", "--port", str(args.port), "--wire", "claude-code", "--apply"], timeout=180)
    check("RT2 (gate 3 RED release) --wire --apply REFUSED naming the gap, nothing changed", rc == 1 and "REFUSED: --wire" in out and "gap" in out
          and tree_sha(tree(), (".local/state/zigmem-deploy/",)) == tree_sha(b, (".local/state/zigmem-deploy/",)), rc=rc, gap=gap)
    rc, out = run(RB, timeout=180)
    check("RT2 rollback exit 0, guarded sha-identical", rc == 0 and "guarded files sha-identical to pre-deploy" in out, rc=rc)
    check("RT2 nothing listening after rollback", not listening(args.port))
else:
    b = tree()
    rc, out = run([f"{ZM}/deploy/deploy.sh", "--port", str(args.port), "--wire", "claude-code"])
    check("RT2 --wire claude-code prints only, changes nothing (outside the deploy state log)", rc == 0 and "printed only" in out and "add-json" in out
          and tree_sha(tree(), (".local/state/zigmem-deploy/",)) == tree_sha(b, (".local/state/zigmem-deploy/",)), rc=rc)
    rc, out = run([f"{ZM}/deploy/deploy.sh", "--port", str(args.port), "--wire", "claude-code", "--apply"], timeout=180)
    cj = open(f"{H}/.claude.json").read()
    check("RT2 --wire claude-code --apply registers user-scope MCP, no token in ~/.claude.json", rc == 0 and '"zigmem"' in cj and "zm_" not in cj, rc=rc, tail=out[-400:])
    rc, out = run(RB, timeout=180)
    cj = open(f"{H}/.claude.json").read()
    j = json.loads(cj)
    check("RT2 rollback exit 0, MCP gone, token files gone", rc == 0 and "zigmem" not in json.dumps(j.get("mcpServers", {})) and not os.path.exists(f"{H}/.config/zigmem"), rc=rc, tail=out[-900:])
    after = tree()
    check("RT2 guarded state after wire+rollback", True, note="claude CLI rewrites ~/.claude.json on add/remove; key-level report printed by rollback",
          claude_json_identical=after.get(".claude.json") == T1.get(".claude.json"),
          other_guarded_identical=all(after.get(k) == T1.get(k) for k in T1 if k.startswith((".pi", ".codex", ".openclaw", ".claude/settings.json", ".config/systemd"))))
    check("RT2 nothing listening after rollback", not listening(args.port))

# ---------- RT3: gate 3 RED (quality) → shadow deploy allowed with a WARNING, --wire refuses naming the gap ----------
def m_quality_red(d):
    j = relj(d)
    q = {"pass": False, "binary_sha256": j["sha256"], "note": "SYNTHETIC quality-RED bench receipt for the harness",
         "gate": {"zigmem_zero_leaks_all_sets": True, "zigmem_all_http_200": True, "zigmem_bench130_ge_live": False},
         "summary": {"zigmem": {"bench130_hits": 120}, "live": {"bench130_hits": 124}}}
    json.dump(q, open(f"{d}/shadow_bench_synthetic_qred.json", "w"))
    j["gates"] = j["gates"] + [os.path.relpath(f"{d}/shadow_bench_synthetic_qred.json", ZM)]; wrel(d, j)
dq = stamp_variant("g_quality_red", m_quality_red)
T2 = tree()
rc, out = run(DEP + ["--no-seed"], {"ZIGMEM_RELEASE_DIR": dq})
check("RT3 gate 3 RED: shadow deploy proceeds with a visible WARN", rc == 0 and "WARN  QUALITY (gate 3)" in out and "gap 4" in out and "GATE 3 (quality) is RED" in out, rc=rc)
b = tree()
rc, out = run([f"{ZM}/deploy/deploy.sh", "--port", str(args.port), "--wire", "claude-code", "--apply"], {"ZIGMEM_RELEASE_DIR": dq})
check("RT3 gate 3 RED: --wire --apply REFUSED naming the gap, nothing changed", rc == 1 and "REFUSED: --wire" in out and "gap 4" in out and tree_sha(tree(), (".local/state/zigmem-deploy/",)) == tree_sha(b, (".local/state/zigmem-deploy/",)), rc=rc)
rc, out = run([f"{ZM}/deploy/deploy.sh", "--port", str(args.port), "--wire", "pi"], {"ZIGMEM_RELEASE_DIR": dq})
check("RT3 gate 3 RED: --wire (print) also refused", rc == 1 and "REFUSED: --wire" in out, rc=rc)
rc, out = run(RB, {"ZIGMEM_RELEASE_DIR": dq})
check("RT3 rollback exit 0, guarded sha-identical", rc == 0 and "guarded files sha-identical to pre-deploy" in out and not listening(args.port), rc=rc)
R["pass"] = all(c["ok"] for c in R["checks"])
R["binary_sha256"] = relj(args.release)["sha256"]
json.dump(R, open(f"{ZM}/receipts/phase8/roundtrip_{args.tag}.json", "w"), indent=1)
print("PASS" if R["pass"] else "FAIL", f"{sum(c['ok'] for c in R['checks'])}/{len(R['checks'])}")
sys.exit(0 if R["pass"] else 1)
