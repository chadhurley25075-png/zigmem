#!/usr/bin/env python3
"""Phase-8 SAFETY gates on an exact candidate binary: auth matrix, bind refusal, fuzz, p95 latency @100K atoms and kill -9
durability — the integration lane's port of the phase-4 gates (tests/integration/p4_gates.py, unchanged, household-shaped
setup), run as subprocesses with ZIGMEM_BIN / ZIGMEM_STOREBENCH = the candidate's, receipts → receipts/phase8/p4_<tag>/
(the integration receipts are not touched), scratch → scratch/p8/p4_<tag>/. Load (uptime + /proc/loadavg) is recorded at the
start and end of every gate. Ports 18180–18189 are the integration lane's: refuses to start if any of them is listening.
  python3 tests/phase8/p4_safety.py --rel CANDIDATE_DIR --tag T [--gates auth,bind,fuzz,latency,crash]"""
import argparse, hashlib, json, os, socket, subprocess, sys, datetime
ap = argparse.ArgumentParser(); ap.add_argument("--rel", required=True); ap.add_argument("--tag", required=True)
ap.add_argument("--gates", default="auth,bind,fuzz,latency,crash")
a = ap.parse_args()
ZM = os.path.expanduser("~/zigmem")
PB = int(os.environ.get("ZIGMEM_PORT_BASE", "18180"))  # merge lane 10/13: overrides; defaults unchanged
P8S = os.environ.get("ZIGMEM_P8_SCRATCH", f"{ZM}/scratch/p8")
GATES_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "integration", "p4_gates.py")
busy = [p for p in range(PB, PB + 10) if socket.socket().connect_ex(("127.0.0.1", p)) == 0]
if busy:
    sys.exit(f"ports busy {busy} (another lane runs its gates) — not started")
env = dict(os.environ, ZIGMEM_BIN=f"{a.rel}/zigmem", ZIGMEM_STOREBENCH=f"{a.rel}/zigmem-storebench",
           ZIGMEM_SCR=f"{P8S}/p4_{a.tag}", ZIGMEM_REC=f"{ZM}/receipts/phase8/p4_{a.tag}")
up = lambda: subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()
out_path = f"{ZM}/receipts/phase8/safety_{a.tag}.json"
prev = json.load(open(out_path)) if os.path.exists(out_path) else {}
res, load = dict(prev.get("gate_raw", {})), dict(prev.get("load", {}))
for g in a.gates.split(","):
    l0 = up()
    p = subprocess.run([sys.executable, GATES_PY, g], env=env, capture_output=True, text=True)
    res[g] = p.returncode == 0
    load[g] = {"start": l0, "end": up()}
    open(f"{P8S}/safety_{a.tag}_{g}.log", "w").write(p.stdout[-20000:] + p.stderr[-5000:])
    print("GATE", g, "GREEN" if res[g] else "RED", load[g], flush=True)
sha = hashlib.sha256(open(f"{a.rel}/zigmem", "rb").read()).hexdigest()
rec = {"tag": a.tag, "when": datetime.datetime.now().astimezone().isoformat(timespec="seconds"), "binary_sha256": sha,
       "gate_raw": res, "gate": {f"{k}_green": v for k, v in res.items()}, "load": load,
       "receipts_dir": f"receipts/phase8/p4_{a.tag}", "harness": "tests/integration/p4_gates.py (unchanged)",
       "pass": all(res.values()) and set(res) >= {"auth", "bind", "fuzz", "latency", "crash"}}
json.dump(rec, open(out_path, "w"), indent=1)
print(json.dumps({k: v for k, v in rec.items() if k != "load"}))
sys.exit(0 if rec["pass"] else 1)
