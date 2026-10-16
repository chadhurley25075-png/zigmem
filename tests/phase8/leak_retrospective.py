#!/usr/bin/env python3
"""INFORMATIONAL retrospective of the LEAK gate on an existing soak receipt's samples (that soak had no pre-run ceiling, so this is not
a gate run). Ceiling = the formula of soak.py with the settings read from the candidate's tree and the soak's own first RSS
sample as start RSS (connections = 1 + readers default; the run's db fd count was not recorded). The original receipt is untouched.
  leak_retrospective.py TAG SRC_TREE"""
import json, os, re, statistics, sys
ZM = os.path.expanduser("~/zigmem"); tag, src = sys.argv[1], sys.argv[2]
r = json.load(open(f"{ZM}/receipts/phase8/soak_{tag}.json"))
sch = open(f"{src}/src/store/schema.zig").read(); hub = open(f"{src}/src/api/hub.zig").read()
cache = abs(int(re.search(r"cache_size=(-?\d+)", sch).group(1))) * 1024; mm = int(re.search(r"mmap_size=(\d+)", sch).group(1))
conns = 1 + int(re.search(r"readers:\s*usize\s*=\s*(\d+)", hub).group(1))
S = r["samples"]; base = S[0]["rss_mb"]
ceil = round(base + (conns * (cache + mm) + 64 * (16 * 1024 + 512 * 1024)) / 2**20, 1)
last = [(x["t"], x["rss_mb"]) for x in S if x["t"] >= r["secs"] - 3600 and "rss_mb" in x]
mt = statistics.mean(t for t, _ in last); mr = statistics.mean(v for _, v in last)
slope = sum((t - mt) * (v - mr) for t, v in last) / sum((t - mt) ** 2 for t, _ in last) * 3600
k = r["kill"]["at_s"]; after = [x["rss_mb"] for x in S if x["t"] >= k and "rss_mb" in x]
# where in the last hour the steps happen (plateau check)
steps = [(S[i]["t"], round(S[i]["rss_mb"] - S[i - 1]["rss_mb"], 1)) for i in range(1, len(S)) if S[i]["t"] >= r["secs"] - 3600 and abs(S[i]["rss_mb"] - S[i - 1]["rss_mb"]) > 5]
out = {"tag": tag, "binary_sha256": r["binary_sha256"], "kind": "INFORMATIONAL retrospective, not a gate run (no pre-run ceiling on that soak)",
       "ceiling_mb": ceil, "ceiling_inputs": {"start_rss_mb(first sample)": base, "connections": conns, "cache_size_mib": cache / 2**20, "mmap_size_mib": mm / 2**20, "index_mb": 0},
       "max_rss_mb": r["rss"]["max_mb"], "last60_slope_mb_per_h": round(slope, 3), "last60_samples": len(last), "steps_gt_5mb_in_last60": steps,
       "max_rss_after_kill_mb": max(after),
       "would_pass": {"never_above_ceiling": r["rss"]["max_mb"] <= ceil, "last60_slope_le_1mb_h": slope <= 1.0, "restart_within_ceiling": max(after) <= ceil}}
json.dump(out, open(f"{ZM}/receipts/phase8/soak_{tag}_leak_retrospective.json", "w"), indent=1)
print(json.dumps(out))
