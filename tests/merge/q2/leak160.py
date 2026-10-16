#!/usr/bin/env python3
"""Merge lane: which ledger keyword made seat item 160 a leak on 5f8f13c12a4b, and the matched span ONLY (no row text leaves
this script except the matched span + boundary facts). Writes receipts/phase8/leak_160_analysis_5f8f13c12a4b.json."""
import json, os, re, sys
H = os.path.expanduser("~"); ZM = f"{H}/zigmem"; tag = "5f8f13c12a4b"
sys.path.insert(0, f"{H}/bench_eval"); sys.path.insert(0, f"{H}/bench_lane")
L = json.load(open(f"{H}/.claude/current_facts_ledger.json"))
rows = json.load(open(f"{ZM}/scratch/p8/bench_{tag}.json"))
out = {"receipt": f"shadow_bench_{tag}.json (unchanged, RED as measured)", "hits": []}
for r in rows:
    if r["set"] != "SEAT" or r["i"] != 160 or r["lane"] not in ("zigmem", "zigcli"): continue
    for f in L["facts"]:
        for k in f.get("dead_keywords", []):
            for line in (r["out"] or "").splitlines():
                m = re.search(k, line, re.I)
                if m:
                    e = m.end(); nxt = line[e:e + 1]
                    out["hits"].append({"lane": r["lane"], "ledger_fact": f.get("id") or f.get("key"), "keyword": k, "matched_text": line[m.start():e + 1],
                                        "next_char_is_digit": nxt.isdigit(), "dead_value_present": bool(re.search(re.escape(k) + r"(?!\d)", line, re.I))})
print(json.dumps(out, indent=1))
json.dump(out, open(f"{ZM}/receipts/phase8/leak_160_analysis_{tag}.json", "w"), indent=1)
