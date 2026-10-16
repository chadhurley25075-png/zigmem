#!/usr/bin/python3 -I
"""Merge-time rulings (BOARD 10/13 ~15:25) + test-harness port/scratch overrides (defaults unchanged). Run in the worktree."""
import json, os, re, sys
os.chdir(sys.argv[1])
def sub(path, old, new, count=1):
    s = open(path).read()
    n = s.count(old)
    assert n == count, (path, old[:70], n)
    open(path, "w").write(s.replace(old, new))
    print("edited", path, "x%d" % n)

PROMISE = "an acked write survives a process crash; a power loss may drop the last commits, never corrupts"
# 1. durability wording (ruling 10/13 ~15:25: keep NORMAL, say "process crash")
sub("PHASE8.md", "**Durability GREEN, RSS gate RED (by the metric I set in advance).**",
    f"**Process-crash durability GREEN** ({PROMISE}; ruling BOARD 10/13 ~15:25), **RSS gate RED (by the metric I set in advance).**")
sub("PHASE8.md", "| soak: 0 rows lost, no crash, no leak | **GREEN on 0 lost / no crash / kill -9 (0.25 s restart).**",
    "| soak: 0 acked rows lost across a process crash (kill -9), no crash, no leak | **GREEN on 0 lost / no crash / kill -9 (0.25 s restart).**")
sub("deploy/DEPLOY.md", "| 2-hour soak (0 rows lost, no crash, no memory LEAK: see the leak gate below) |",
    f"| 2-hour soak (0 acked rows lost across a process crash (kill -9), no crash, no memory LEAK: see the leak gate below). Durability: {PROMISE} |")
sub("deploy/zm_kit.py", '"soak_": "2 h soak (0 rows lost, no crash, RSS stable)"',
    f'"soak_": "2 h soak (0 acked rows lost across a process crash (kill -9), no crash, RSS stable; {PROMISE})"')

# 2. phase-2 turn 28 label (ruling 10/13 ~15:25): the public half is kept by design; the password never appears; forbid unchanged
NOTE = ("label updated at the fixbatch merge (BOARD 10/13 ~15:25): was 'nothing to keep' (none=true) under the old drop-the-turn "
        "rule; extraction x2.2 rule 6 keeps the PUBLIC half ('the wifi password changed') by design, the password itself never "
        "appears; forbid + canaries unchanged, so the private-canary gate is unchanged; no expect added (found stays /46)")
sub("tests/extract/make_turns.py",
    't("s6", "Alex", d, "Note for later: the wifi password changed. <private>CANARY-PV4 hunter2-orchid</private>",\n  none=True, forbid=[r"CANARY", r"(?i)hunter2|orchid"])',
    't("s6", "Alex", d, "Note for later: the wifi password changed. <private>CANARY-PV4 hunter2-orchid</private>",\n  none=False, forbid=[r"CANARY", r"(?i)hunter2|orchid"],\n  note="' + NOTE + '")')
S = json.load(open("tests/extract/turns.json"))
t = S["turns"][27]; assert t["id"] == 28 and "wifi password changed" in t["text"] and t["none"] is True and t["note"] == ""
before = json.dumps(S, indent=1, ensure_ascii=False)

# 3. harness overrides (tests only; every default unchanged). Lane ports 18220-18239.
P4 = "tests/integration/p4_gates.py"
sub(P4, 'STOPS = []\n', 'STOPS = []\nPB = int(os.environ.get("ZIGMEM_PORT_BASE", "18180"))  # merge lane 10/13: test-port base override; default unchanged\n')
for k, p in enumerate(range(18180, 18186)):
    sub(P4, f"    port = {p}\n", f"    port = PB + {k}\n")
PS = "tests/phase8/p4_safety.py"
sub(PS, "busy = [p for p in range(18180, 18190) if",
    'PB = int(os.environ.get("ZIGMEM_PORT_BASE", "18180"))  # merge lane 10/13: overrides; defaults unchanged\n'
    'P8S = os.environ.get("ZIGMEM_P8_SCRATCH", f"{ZM}/scratch/p8")\n'
    'GATES_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "integration", "p4_gates.py")\n'
    "busy = [p for p in range(PB, PB + 10) if")
sub(PS, 'ZIGMEM_SCR=f"{ZM}/scratch/p8/p4_{a.tag}"', 'ZIGMEM_SCR=f"{P8S}/p4_{a.tag}"')
sub(PS, 'f"{ZM}/tests/integration/p4_gates.py"', "GATES_PY")
sub(PS, 'open(f"{ZM}/scratch/p8/safety_{a.tag}_{g}.log", "w")', 'open(f"{P8S}/safety_{a.tag}_{g}.log", "w")')
PP = "tests/integration/proxy_probe.py"
s = open(PP).read()
assert (s.count("18187"), s.count("18188"), s.count("18189")) == (2, 3, 3), (s.count("18187"), s.count("18188"), s.count("18189"))
sub(PP, 'srv = http.server.ThreadingHTTPServer(("127.0.0.1", 18189), Up)',
    'XB = int(os.environ.get("ZIGMEM_PROXY_PORT_BASE", "18187"))  # merge lane 10/13: hub XB, proxy XB+1, upstream XB+2; default unchanged\n'
    'srv = http.server.ThreadingHTTPServer(("127.0.0.1", XB + 2), Up)')
sub(PP, '"--port", "18187", "--proxy-upstream", "http://127.0.0.1:18189", "--proxy-port", "18188"]',
    '"--port", str(XB), "--proxy-upstream", f"http://127.0.0.1:{XB + 2}", "--proxy-port", str(XB + 1)]')
sub(PP, 'http.client.HTTPConnection("127.0.0.1", 18188, timeout=10)', 'http.client.HTTPConnection("127.0.0.1", XB + 1, timeout=10)')
s = open(PP).read(); print("proxy_probe remaining literal ports:", re.findall(r"1818[789]", s.split('"""', 2)[2]))
sub("tests/fixbatch/health_test.sh", 'PORT=18187; PY=', 'PORT="${ZIGMEM_HEALTH_PORT:-18187}"; PY=')
RT = "tests/phase8/roundtrip.py"
sub(RT, 'H = f"{ZM}/scratch/p8home"', 'H = os.environ.get("ZIGMEM_RT_HOME", f"{ZM}/scratch/p8home")  # merge lane 10/13: scratch override; default unchanged\nRTREL = os.environ.get("ZIGMEM_RT_RELDIR", f"{ZM}/scratch/p8")')
sub(RT, 'd = f"{ZM}/scratch/p8/rel_{name}"', 'd = f"{RTREL}/rel_{name}"')
the x86 box = "tests/phase8/x86_run.sh"
s = open(the x86 box).read(); n99, n98 = s.count("18199"), s.count("18198")
s = s.replace('set -uo pipefail\n', 'set -uo pipefail\nSP="${ZIGMEM_SMOKE_PORT:-18199}"; RP="${ZIGMEM_REFUSE_PORT:-18198}"   # merge lane 10/13: overrides; defaults unchanged\n', 1)
head, body = s.split("SP=\"${ZIGMEM_SMOKE_PORT", 1)
body = body.split("\n", 1)
body = body[0] + "\n" + body[1].replace("'sport = :18199'", '"sport = :$SP"').replace("18199", "$SP").replace("18198", "$RP")
open(the x86 box, "w").write(head + "SP=\"${ZIGMEM_SMOKE_PORT" + body); print("edited", the x86 box, n99, n98)

import subprocess
subprocess.run([sys.executable, "tests/extract/make_turns.py"], check=True)
S2 = json.load(open("tests/extract/turns.json")); S0 = json.loads(before)
diff = [i for i, (a, b) in enumerate(zip(S0["turns"], S2["turns"])) if a != b]
assert diff == [27] and {k for k in S2 if S2[k] != S0[k]} == {"turns"} and len(S0["turns"]) == len(S2["turns"]), diff
t2 = S2["turns"][27]; assert t2["none"] is False and t2["forbid"] == t["forbid"] and t2["expect"] == [] and t2["note"]
print("turns.json: only turn 28 changed:", {k: (t[k], t2[k]) for k in t if t[k] != t2[k]})
