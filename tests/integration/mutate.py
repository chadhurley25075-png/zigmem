#!/usr/bin/env python3
"""INTEGRATION gate 5: deliberate wiring breaks. Each mutant = a copy of the integrated tree with ONE small patch that
still compiles; built with -Drelease; then the gate(s) that should notice it are run against the mutant binary with
scratch/receipts redirected (the real receipts are never touched). A mutant is CAUGHT when a gate exits non-zero.
Usage: mutate.py [name ...]  → receipts/integration/mutations.json"""
import json, os, shutil, subprocess, sys, time

ROOT = os.path.expanduser("~/zigmem")
# env overrides (fix batch 10/13: run from a worktree without touching the main tree's scratch/receipts); defaults unchanged
TREE = os.environ.get("ZIGMEM_MUT_TREE", f"{ROOT}/scratch/integ/tree")
MUT = os.environ.get("ZIGMEM_MUT_DIR", f"{ROOT}/scratch/integ/mut")
ZIG = os.path.expanduser("~/tools/zig-linux/zig")
OUT = os.environ.get("ZIGMEM_MUT_OUT", f"{ROOT}/receipts/integration/mutations.json")
NICE = ["nice", "-n", "10"] if os.environ.get("ZIGMEM_MUT_NICE") == "1" else []  # + -j4: a soak shares the box
JOBS = ["-j4"] if NICE else []
PY = os.path.expanduser("python3")

MUTANTS = {
    "scope_check_skipped": ("src/api/access.zig", "    for (want) |s| if (!w.mayRead(s)) return null;\n    return want;",
                            "    return want; // MUTANT: requested scopes not checked"),
    "household_gate_off_on_search": ("src/api/retrieval.zig",
                                     "        return out;\n    }\n\n    fn rowFilter",
                                     "        @memset(out, true); // MUTANT: the household row filter keeps everything\n        return out;\n    }\n\n    fn rowFilter"),
    "trust_seat_header": ("src/api/rest.zig", "    au.seat = who.seat.name;\n    var c: Ctx",
                          "    const who = if (req.header(\"x-zigmem-seat\")) |hs| blk: {\n"
                          "        const t = h.tokens.current() orelse break :blk who_tok;\n"
                          "        const s2 = t.find(hs) orelse break :blk who_tok;\n"
                          "        break :blk switch (try identifySeat(h, a, s2)) {\n            .ok => |w2| w2,\n            else => who_tok,\n        };\n"
                          "    } else who_tok; // MUTANT: honours a seat-name header\n    au.seat = who.seat.name;\n    var c: Ctx"),
    "turns_not_person_gated": ("src/api/retrieval.zig", "    const g = try house.gate(a, who.L, who.actor, q.text, rows.items, q.narrow);\n    // phase-3 medical",
                               "    var g = try house.gate(a, who.L, who.actor, q.text, rows.items, q.narrow);\n    g.rows = rows.items; // MUTANT: turns not person-gated\n    // phase-3 medical"),
    "token_narrowing_ignored": ("src/api/access.zig", "    for (seat.scopes) |x| if (std.mem.eql(u8, x, \"*\") or std.mem.eql(u8, x, s)) return true;\n    return false;",
                                "    _ = seat;\n    _ = s;\n    return true; // MUTANT: the token's scope list is ignored"),
    "principal_personal_exemption": ("src/household/house.zig", "                const about = switch (tg) {",
                                     "                const about = act.principal() or switch (tg) { // MUTANT: principals skip the personal-row rule"),
    "get_by_id_ungated": ("src/api/rest.zig", "        if (!try retrieval.gateOne(&c.h.eng, c.a, rd, slot, &c.who, row, \"\", x.subject)) return null;\n        x.text",
                          "        _ = row; // MUTANT: no row gate on get-by-id\n        x.text"),
    "proxy_token_unchecked": ("src/proxy.zig", "        const m = if (tok) |t| f(cfg.memory.ctx, t, session) else null;",
                              "        const m: ?[]const u8 = if (tok) |t| f(cfg.memory.ctx, t, session) else \"\"; // MUTANT: no token → passthrough"),
    "privacy_screen_off": ("src/api/rest.zig", "    fn screenText(c: *Ctx, field: []const u8, text: []const u8) !void {\n        if (c.seat.trusted) return;",
                           "    fn screenText(c: *Ctx, field: []const u8, text: []const u8) !void {\n        if (true) return; // MUTANT\n        if (c.seat.trusted) return;"),
}
# the dispatch mutant needs the original binding renamed
RENAME = {"trust_seat_header": ("src/api/rest.zig", "    const who = switch (try identify(h, a, tok)) {", "    const who_tok = switch (try identify(h, a, tok)) {")}

GATES = {
    "scope_check_skipped": [("p4 auth", ["python3", "tests/integration/p4_gates.py", "auth"]), ("p5 api", [PY, "tests/integration/p5_api_gate.py"])],
    "household_gate_off_on_search": [("p5 api", [PY, "tests/integration/p5_api_gate.py"])],
    "trust_seat_header": [("p4 auth", ["python3", "tests/integration/p4_gates.py", "auth"]), ("p5 api", [PY, "tests/integration/p5_api_gate.py"])],
    "turns_not_person_gated": [("p5 api", [PY, "tests/integration/p5_api_gate.py"])],
    "token_narrowing_ignored": [("p5 api", [PY, "tests/integration/p5_api_gate.py"])],
    "principal_personal_exemption": [("p5 api", [PY, "tests/integration/p5_api_gate.py"]), ("p5 in-process", ["bash", "-c", "rm -f $ZIGMEM_SCR/x.db*; mkdir -p $ZIGMEM_SCR; $ZIGMEM_BINDIR/zigmem-household-gate --db $ZIGMEM_SCR/x.db > /dev/null"])],
    "get_by_id_ungated": [("p5 api", [PY, "tests/integration/p5_api_gate.py"])],
    "proxy_token_unchecked": [("proxy no-token probe", [PY, "tests/integration/proxy_probe.py"])],
    "privacy_screen_off": [("p4 auth", ["python3", "tests/integration/p4_gates.py", "auth"])],
}


def patch(root, f, old, new):
    p = os.path.join(root, f)
    s = open(p).read()
    assert s.count(old) == 1, (f, old[:60], s.count(old))
    open(p, "w").write(s.replace(old, new))


def main():
    names = sys.argv[1:] or list(MUTANTS)
    res = json.load(open(OUT)) if os.path.exists(OUT) else {}
    for n in names:
        d = f"{MUT}/{n}"
        subprocess.run(["rm", "-rf", d], check=True)
        shutil.copytree(TREE, d, ignore=shutil.ignore_patterns(".zig-cache", "out", "__pycache__"))
        if n in RENAME:
            patch(d, *RENAME[n])
        patch(d, *MUTANTS[n])
        t = time.time()
        b = subprocess.run(NICE + [ZIG, "build", "-Drelease"] + JOBS + ["install", "household-gate", "hh-fixture", "--prefix", "out"], cwd=d, capture_output=True, text=True)
        r = {"file": MUTANTS[n][0], "build_rc": b.returncode, "build_err": b.stderr[-600:] if b.returncode else "", "gates": {}}
        if b.returncode == 0:
            env = dict(os.environ, ZIGMEM_BIN=f"{d}/out/bin/zigmem", ZIGMEM_BINDIR=f"{d}/out/bin", ZIGMEM_SCR=f"{d}/scr", ZIGMEM_REC=f"{d}/rec",
                       ZIGMEM_STOREBENCH=os.environ.get("ZIGMEM_STOREBENCH", f"{TREE}/out/bin/zigmem-storebench"), P5_QUICK="1")
            for gname, cmd in GATES[n]:
                g = subprocess.run(cmd, cwd=TREE, env=env, capture_output=True, text=True, timeout=3600)
                tail = [l for l in (g.stdout + g.stderr).splitlines() if l.strip()][-3:]
                r["gates"][gname] = {"rc": g.returncode, "tail": tail}
        r["caught"] = b.returncode == 0 and any(v["rc"] != 0 for v in r["gates"].values())
        r["s"] = round(time.time() - t, 1)
        res[n] = r
        print(n, "CAUGHT" if r["caught"] else ("DID NOT COMPILE" if b.returncode else "MISSED"), {k: v["rc"] for k, v in r["gates"].items()}, flush=True)
        json.dump(res, open(OUT, "w"), indent=1)
        subprocess.run(["rm", "-rf", d], check=True)  # mutant trees are deleted; only the receipt stays


if __name__ == "__main__":
    main()
