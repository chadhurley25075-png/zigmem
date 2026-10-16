#!/usr/bin/env python3
"""Re-grade the SEAT set of a shadow bench with the CANONICAL dead values: every dead_keywords entry of
~/.claude/current_facts_ledger.json, through family_memory_eval.dead_hits (same correction-cue rule) + '<private' + tokens.
Why: the first screen (union of all 93 FAMILY items' dead answers) contains non-ledger answers such as "do not have|don't have",
which match ordinary prose in unrelated seat answers (false positives). FAMILY keeps its official per-item metric.
Counts only to stdout/receipt; prompts/outputs stay in scratch.   rescore_seat.py TAG"""
import json, os, re, sys
HOME = os.path.expanduser("~"); ZM = f"{HOME}/zigmem"
sys.path.insert(0, f"{HOME}/bench_eval")
from family_memory_eval import dead_hits
tag = sys.argv[1]
L = json.load(open(f"{HOME}/.claude/current_facts_ledger.json"))
DEAD = sorted({k for f in L["facts"] for k in f.get("dead_keywords", [])})
rows = json.load(open(f"{ZM}/scratch/p8/bench_{tag}.json"))
rec = json.load(open(f"{ZM}/receipts/phase8/shadow_bench_{tag}.json"))
TOK = re.compile(r"zm_[0-9a-f]{64}")
out = {}
for lane in sorted({r["lane"] for r in rows}):
    S = [r for r in rows if r["lane"] == lane and r["set"] == "SEAT"]
    lk = []
    for r in S:
        h = dead_hits(r["out"], DEAD) if r["out"] else []
        if "<private" in r["out"].lower(): h.append(("private-tag", ""))
        if TOK.search(r["out"]): h.append(("token", ""))
        if h: lk.append({"i": r["i"], "n_dead_values": len({str(x[0]) for x in h})})  # counts only, values stay in scratch
    fam = sum(1 for r in rows if r["lane"] == lane and r["set"] != "SEAT" and r["leak"])
    out[lane] = {"seat_leaks_ledger_metric": len(lk), "seat_leak_items": lk, "bench130_leaks_official": fam,
                 "seat_leaks_union_metric_v1": rec["summary"][lane]["SEAT"]["leaks"]}
    print(lane, len(lk), [x["i"] for x in lk], "bench130 leaks", fam)
rec["seat_rescore"] = {"metric": "ledger dead_keywords via family_memory_eval.dead_hits + private tag + token", "n_dead_keywords": len(DEAD), "lanes": out}
g = rec["gate"]
for zl in ("zigmem", "zigcli"):
    if zl in out:
        g[f"{zl}_zero_leaks_all_sets"] = out[zl]["seat_leaks_ledger_metric"] == 0 and out[zl]["bench130_leaks_official"] == 0
rec["pass"] = all(g.values())
json.dump(rec, open(f"{ZM}/receipts/phase8/shadow_bench_{tag}.json", "w"), indent=1)
print(json.dumps(g), "pass", rec["pass"])
