#!/usr/bin/python3 -I
"""zigmem deploy kit helper (stdlib only, run with the system python3 -I).

  zm_kit.py snapshot OUT.json            sha256 of every guarded path (files, whole trees) + per-key hashes of ~/.claude.json
  zm_kit.py compare PRE.json             re-hash and compare; exit 0 = sha-identical, 2 = changed but only outside mcpServers
                                         with no zigmem entry and no zigmem token (Claude Code's own bookkeeping), 1 = FAIL
  zm_kit.py release-check REL.json BIN [shadow|wire]   release preflight: sha, -Drelease, arch, tested sha; SAFETY gates green;
                                         gate 3 (hub 130-q >= live) = WARN in shadow, required for wire
  zm_kit.py mget MANIFEST KEY            print one manifest field (JSON)
  zm_kit.py mset MANIFEST KEY JSON       set one manifest field (atomic rewrite, 0600)
  zm_kit.py madd MANIFEST KEY JSON       append to a list field
Guarded paths are derived from $HOME (never hardcoded to a body). Nothing here writes outside the given OUT/MANIFEST path.
"""
import hashlib, json, os, re, stat, sys

HOME = os.path.expanduser("~")
GUARDED = [".claude.json", ".claude/settings.json", ".claude/settings.local.json", ".pi", ".codex/config.toml",
           ".openclaw/openclaw.json", ".config/systemd/user"]
TOKEN_RE = re.compile(rb"zm_[0-9a-f]{64}")


def h_file(p):
    d = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            d.update(b)
    return d.hexdigest()


def h_path(p):
    if os.path.islink(p) and not os.path.isdir(p):
        return {"kind": "link", "sha": hashlib.sha256(os.readlink(p).encode()).hexdigest()}
    if os.path.isfile(p):
        return {"kind": "file", "sha": h_file(p), "mode": oct(stat.S_IMODE(os.stat(p).st_mode))}
    if os.path.isdir(p):
        d, n = hashlib.sha256(), 0
        for root, dirs, files in os.walk(p, followlinks=False):
            dirs.sort()
            for name in sorted(files + [x for x in dirs if os.path.islink(os.path.join(root, x))]):
                fp = os.path.join(root, name)
                rel = os.path.relpath(fp, p)
                if os.path.islink(fp):
                    d.update(f"L {rel} -> {os.readlink(fp)}\n".encode())
                elif os.path.isfile(fp):
                    try:
                        d.update(f"F {rel} {h_file(fp)}\n".encode())
                    except OSError as e:
                        d.update(f"E {rel} {e.errno}\n".encode())
                n += 1
        return {"kind": "dir", "sha": d.hexdigest(), "files": n}
    return {"kind": "absent", "sha": "absent"}


def keyhashes(obj, prefix="", depth=0, out=None):
    """sha of every key down to depth 2, and of every mcpServers subtree at any depth (JSON pointer -> sha)."""
    out = {} if out is None else out
    if isinstance(obj, dict):
        for k, v in obj.items():
            ptr = f"{prefix}/{k}"
            if depth < 2 or k == "mcpServers" or "/mcpServers" in prefix:
                out[ptr] = hashlib.sha256(json.dumps(v, sort_keys=True).encode()).hexdigest()
            keyhashes(v, ptr, depth + 1, out)
    return out


def claude_json_facts(p):
    if not os.path.isfile(p):
        return {"absent": True}
    raw = open(p, "rb").read()
    facts = {"token_present": bool(TOKEN_RE.search(raw)), "zigmem_mcp": []}
    try:
        j = json.loads(raw)
    except ValueError:
        facts["unparsable"] = True
        return facts
    facts["keys"] = keyhashes(j)
    def walk(o, ptr=""):
        if isinstance(o, dict):
            for k, v in o.items():
                if k == "mcpServers" and isinstance(v, dict) and "zigmem" in v:
                    facts["zigmem_mcp"].append(f"{ptr}/mcpServers/zigmem")
                walk(v, f"{ptr}/{k}")
    walk(j)
    return facts


def snapshot():
    snap = {"home": HOME, "paths": {g: h_path(os.path.join(HOME, g)) for g in GUARDED}}
    snap["claude_json"] = claude_json_facts(os.path.join(HOME, ".claude.json"))
    return snap


def compare(pre_path):
    pre, now = json.load(open(pre_path)), snapshot()
    worst, lines = 0, []
    for g in GUARDED:
        a, b = pre["paths"].get(g, {}).get("sha"), now["paths"][g]["sha"]
        if a == b:
            lines.append(f"IDENTICAL {g} {b[:16]}")
            continue
        if g == ".claude.json":
            pk, nk = pre["claude_json"].get("keys", {}), now["claude_json"].get("keys", {})
            changed = sorted(k for k in set(pk) | set(nk) if pk.get(k) != nk.get(k))
            mcp = [k for k in changed if "mcpServers" in k]
            bad = mcp or now["claude_json"].get("zigmem_mcp") or now["claude_json"].get("token_present")
            lines.append(f"{'CHANGED-FAIL' if bad else 'CHANGED-BOOKKEEPING'} {g} keys={changed[:12]}{' …' if len(changed) > 12 else ''}"
                         f" zigmem_mcp={now['claude_json'].get('zigmem_mcp')} token={now['claude_json'].get('token_present')}")
            worst = max(worst, 2 if not bad else 3)
        else:
            lines.append(f"CHANGED-FAIL {g} {str(a)[:16]} -> {b[:16]}")
            worst = 3
    print("\n".join(lines))
    return {0: 0, 2: 2, 3: 1}[worst]


def elf_machine(p):
    with open(p, "rb") as f:
        h = f.read(20)
    if h[:4] != b"\x7fELF":
        return None
    return {0xB7: "aarch64", 0x3E: "x86_64"}.get(int.from_bytes(h[18:20], "little"), "other")


REQUIRED_KINDS = {"shadow_bench_": "0 leaks on every set (shadow bench)", "safety_": "auth matrix + bind 127.0.0.1 + fuzz + kill -9 durability",
                  "soak_": "2 h soak (0 acked rows lost across a process crash (kill -9), no crash, RSS stable; an acked write survives a process crash; a power loss may drop the last commits, never corrupts)", "roundtrip_": "deploy/rollback round trip"}


def split_gates(r):
    """SAFETY vs QUALITY for one receipt. Quality = gate 3 only (hub 130-q >= live, same night); everything else is safety.
    Receipts without a per-gate dict are all safety (their 'pass')."""
    g = r.get("gate")
    if isinstance(g, dict) and g:
        safety = {k: v for k, v in g.items() if "bench130" not in k}
        quality = {k: v for k, v in g.items() if k.startswith("zigmem_bench130")}
        return all(safety.values()) and bool(safety), safety, quality
    return r.get("pass") is True, {"pass": r.get("pass")}, {}


def ruled(r, gate_path, key, rulings):
    """A SAFETY key that is false passes ONLY if a recorded supervisor ruling names this receipt + key AND the receipt's leak
    items are EXACTLY the ruled ones (any other leak, or a family-93 leak, keeps it RED). Returns the ruling or None."""
    for ru in rulings or []:
        if ru.get("receipt") != gate_path or key not in ru.get("gates", []):
            continue
        lanes = (r.get("seat_rescore") or {}).get("lanes", {})
        ok = True
        for lane, items in ru.get("expect_seat_items", {}).items():
            got = sorted(x["i"] for x in lanes.get(lane, {}).get("seat_leak_items", []))
            ok = ok and got == sorted(items) and lanes.get(lane, {}).get("bench130_leaks_official", 1) == 0
        if ok:
            return ru
    return None


def gap_text(r):
    s = r.get("summary", {})
    z, l = s.get("zigmem", {}).get("bench130_hits"), s.get("live", {}).get("bench130_hits")
    return f"hub {z}/130 vs live {l}/130 (gap {l - z})" if isinstance(z, int) and isinstance(l, int) else "no score"


def release_check(rel_path, bin_path, mode="shadow"):
    """mode shadow: every SAFETY gate must be green; gate 3 (quality) is printed as a WARNING.
    mode wire: gate 3 must ALSO be green (a seat may only read zigmem when it beats what the seat has now)."""
    ok = True
    def say(good, msg):
        nonlocal ok
        ok = ok and good
        print(f"  {'PASS' if good else 'FAIL'}  {msg}")
    try:
        rel = json.load(open(rel_path))
    except (OSError, ValueError) as e:
        print(f"  FAIL  release manifest {rel_path}: {e}")
        return 1
    sha = h_file(bin_path) if os.path.isfile(bin_path) else "missing"
    say(sha == rel.get("sha256"), f"binary sha256 {sha[:16]} == RELEASE.sha256 {str(rel.get('sha256'))[:16]}")
    say(rel.get("optimize") == "ReleaseSafe" and "-Drelease" in rel.get("build_cmd", ""), f"built with -Drelease ({rel.get('build_cmd')})")
    mach, want = elf_machine(bin_path) if os.path.isfile(bin_path) else None, os.uname().machine
    say(mach == want, f"ELF arch {mach} == this host {want}")
    say(bool(rel.get("tested_sha256")) and rel.get("tested_sha256") == sha, f"binary sha == tested sha {str(rel.get('tested_sha256'))[:16]} (the binary the phase-8 gates ran on)")
    gates = rel.get("gates") or []
    say(len(gates) > 0, f"{len(gates)} gate receipts listed")
    base = os.environ.get("ZM_ROOT") or os.path.abspath(os.path.join(os.path.dirname(rel_path), "..", ".."))
    names = [os.path.basename(g) for g in gates]
    kinds = dict(REQUIRED_KINDS)
    ov = os.environ.get("ZM_REQUIRED_KINDS")
    scratch = os.path.join(os.path.realpath(os.environ.get("ZM_ROOT", "/nonexistent")), "scratch") + os.sep
    if ov is not None and os.path.realpath(HOME).startswith(scratch):
        kinds = {k: f"(test override) {k}" for k in ov.split(",") if k}   # test hook: honoured only for a scratch HOME
    for pre, what in kinds.items():
        say(any(n.startswith(pre) for n in names), f"safety gate present: {what}")
    for g in gates:
        p = os.path.join(base, g)
        try:
            r = json.load(open(p))
        except (OSError, ValueError) as e:
            say(False, f"gate {g}: {e.__class__.__name__}")
            continue
        same_bin = r.get("binary_sha256") in (None, sha)
        safe, safety, quality = split_gates(r)
        reds = [k for k, v in safety.items() if not v]
        rulings = {k: ruled(r, g, k, rel.get("rulings")) for k in reds}
        if reds and all(rulings.values()):
            say(same_bin, f"SAFETY {g}: RED as measured {reds}, covered by ruling: {list(rulings.values())[0].get('ruling')} (items exactly as ruled)")
        else:
            say(safe and same_bin, f"SAFETY {g}: {'green' if safe else 'RED ' + str(reds)} sha={str(r.get('binary_sha256'))[:16]}")
        for k, v in quality.items():
            if v:
                say(True, f"QUALITY {g} {k}: green ({gap_text(r)})")
            elif mode == "wire":
                say(False, f"QUALITY {g} {k}: RED — {gap_text(r)}. A seat may read zigmem only when it beats what it has now.")
            else:
                print(f"  WARN  QUALITY (gate 3) {g} {k}: RED — {gap_text(r)}. Shadow deploy allowed; --wire will refuse.")
    seed = rel.get("seed_db")
    if seed and mode == "shadow":
        sp = os.path.expanduser(seed)
        if os.path.isfile(sp):
            ssha = h_file(sp)
            say(ssha == rel.get("seed_sha256"), f"seed db {seed} sha {ssha[:16]} == RELEASE.seed_sha256")
        else:
            say(False, f"seed db {seed} missing")
    return 0 if ok else 1


def mload(p):
    try:
        return json.load(open(p))
    except (OSError, ValueError):
        return {}


def msave(p, m):
    tmp = p + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(m, f, indent=1, sort_keys=True)
        f.flush(); os.fsync(f.fileno())
    os.replace(tmp, p)


def main(a):
    if a[:1] == ["snapshot"]:
        msave(a[1], snapshot()); return 0
    if a[:1] == ["compare"]:
        return compare(a[1])
    if a[:1] == ["release-check"]:
        return release_check(a[1], a[2], a[3] if len(a) > 3 else "shadow")
    if a[:1] == ["mget"]:
        v = mload(a[1]).get(a[2]); print(json.dumps(v) if not isinstance(v, str) else v); return 0
    if a[:1] == ["mset"]:
        m = mload(a[1]); m[a[2]] = json.loads(a[3]); msave(a[1], m); return 0
    if a[:1] == ["madd"]:
        m = mload(a[1]); m.setdefault(a[2], []).append(json.loads(a[3])); msave(a[1], m); return 0
    print(__doc__); return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
