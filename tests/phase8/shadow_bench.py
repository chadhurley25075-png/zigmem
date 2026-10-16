#!/usr/bin/env python3
"""Phase-8 SHADOW bench: the running zigmem hub (HTTP /v1/recall, seat token) vs the LIVE the reranked lane lane (the exact
UserPromptSubmit hook env from ~/.claude/settings.json: rerank_lane_plus.py + its flags), on
  bench  = the 130-q bench (FAMILY 93 with dead values + BENCH91 15 + HISTORY 22; imported from bench.py, never copied),
  seat   = >= 200 real recent seat prompts (scratch/p8/seat_prompts.jsonl, privacy-filtered; text never leaves the dev box).
Graded exactly like bench.py (truth regex, re.I) and family_memory_eval.dead_hits. Seat-prompt leak screen = dead_hits against
the union of every FAMILY item's dead values + any '<private' tag + any zigmem token string in the block.
Both lanes run SEQUENTIALLY (one request at a time) so latency is like for like: live = one hook subprocess per prompt (what a
seat pays), zigmem = one HTTP request per prompt to the warm hub.
  python3 tests/phase8/shadow_bench.py --url http://127.0.0.1:18191 --token-file F --bin-sha SHA --tag T
Full outputs → scratch/p8/bench_<tag>.json (the dev box only). Counts → receipts/phase8/shadow_bench_<tag>.json."""
import argparse, json, os, re, statistics, sys, time, urllib.request, datetime
HOME = os.path.expanduser("~")
ZM = f"{HOME}/zigmem"
sys.path.insert(0, f"{HOME}/bench_lane"); sys.path.insert(0, f"{HOME}/bench_eval")
import bench as B
from family_memory_eval import dead_hits

ap = argparse.ArgumentParser()
ap.add_argument("--url", required=True)
ap.add_argument("--token-file", required=True)
ap.add_argument("--bin-sha", required=True)
ap.add_argument("--tag", default=time.strftime("%Y%m%d-%H%M"))
ap.add_argument("--sets", default="bench,seat")
ap.add_argument("--lanes", default="zigmem,live")
ap.add_argument("--seat-file", default=f"{ZM}/scratch/p8/seat_prompts.jsonl")
ap.add_argument("--recall-bin", default="")
ap.add_argument("--recall-db", default="")
args = ap.parse_args()
TOKEN = open(args.token_file).read().strip()

# the live hook env, read from settings.json at run time (not copied) — fall back to the phase-3 constant only if absent
LIVE_ENV = {"BLEND_SOURCES": "journal,synth,vault,facts,notes,agi,osmem", "BLEND_MIN_SCORE": "0.50", "BLEND_EXTRA_SOURCES": "smfacts,smsynth",
            "BLEND_TEMPORAL_K": "8", "BLEND_PER_SOURCE": "5", "BLEND_RERANK_CHARS": "700", "BLEND_BUDGET": "3000"}
LIVE_SCRIPT = f"{HOME}/bench_lane/rerank_lane_plus.py"
try:
    st = json.load(open(f"{HOME}/.claude/settings.json"))
    cmds = [h["command"] for g in st["hooks"]["UserPromptSubmit"] for h in g["hooks"] if "blend_rerank" in h.get("command", "")]
    parts = cmds[0].split()
    LIVE_ENV = dict(p.split("=", 1) for p in parts if re.match(r"^[A-Z_]+=", p))
    LIVE_SCRIPT = [p for p in parts if p.endswith(".py")][0]
    LIVE_FROM = "settings.json"
    # LIVE-LOCAL (as the integration lane's gate 3): the two off-box hops pinned to the dev box, so family text never leaves it —
    # reranker = the dev box :18098 (not the LAN reranker), no the cloud store cloud extras. Same hook code and knobs otherwise.
    LIVE_ENV.update({"BLEND_EXTRA_SOURCES": "", "BLEND_RERANK_URL": "http://127.0.0.1:18098/rerank", "BLEND_RERANK_FALLBACK": ""})
    LIVE_FROM += " → live-local (BLEND_EXTRA_SOURCES='', BLEND_RERANK_URL=the dev box :18098, no fallback)"
except Exception as e:
    LIVE_FROM = f"fallback ({e.__class__.__name__})"

qs = []
if "bench" in args.sets:
    for q, truth, dead, cls in B.ITEMS: qs.append(("FAMILY", q, truth, dead))
    for q, truth, cls in B.BENCH91: qs.append(("BENCH91", q, truth, []))
    for q, truth in B.HISTORY: qs.append(("HISTORY", q, truth, []))
ALL_DEAD = sorted({d for _, _, dead, _ in B.ITEMS for d in dead})
if "seat" in args.sets:
    for l in open(args.seat_file):
        qs.append(("SEAT", json.loads(l)["prompt"], None, ALL_DEAD))
TOKRE = re.compile(r"zm_[0-9a-f]{64}")


def zig(q):
    body = json.dumps({"query": q}).encode()
    req = urllib.request.Request(f"{args.url}/v1/recall", data=body, method="POST",
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            j = json.loads(r.read()); code = r.status
    except urllib.error.HTTPError as e:
        j, code = {}, e.code
    ms = (time.time() - t) * 1000
    out = j.get("context") if isinstance(j.get("context"), str) else ""
    return out, ms, {"code": code, "strategy": j.get("strategy"), "memory_count": j.get("memory_count")}


CLI_CACHE = {}


def zigcli_all():
    """phase-3 retriever in one process for every prompt (the bench_zigmem.py 'zigmem' lane flags), same store as the hub."""
    import subprocess
    cmd = [args.recall_bin, "query", "--db", args.recall_db, "--ledger", f"{HOME}/.claude/current_facts_ledger.json",
           "--today", datetime.date.today().isoformat(), "--min-rerank", "0.50",
           "--rerank", "http://127.0.0.1:18098/rerank", "--rerank-fallback", "none"]
    inp = "".join(json.dumps({"prompt": q[1]}) + "\n" for q in qs)
    p = subprocess.run(cmd, input=inp.encode(), capture_output=True, timeout=7200)
    lines = [json.loads(l) for l in p.stdout.decode().split("\n") if l]
    assert len(lines) == len(qs), (len(lines), p.stderr.decode()[-800:])
    for (st, q, *_), l in zip(qs, lines):
        CLI_CACHE.setdefault(q, (l.get("out", ""), l.get("ms", 0), {"rerank": l.get("rerank")}))


def zigcli(q):
    if not CLI_CACHE: zigcli_all()
    return CLI_CACHE[q]


def live(q):
    o, ms = B.run_lane((LIVE_SCRIPT, LIVE_ENV), q)
    return o, ms, {}


LOAD0 = open("/proc/loadavg").read().split()[:3]
rows, summ = [], {}
for lane in args.lanes.split(","):
    fn = {"zigmem": zig, "zigcli": zigcli, "live": live}[lane]
    t0 = time.time()
    R = []
    for i, (st, q, truth, dead) in enumerate(qs):
        out, ms, meta = fn(q)
        hit = bool(re.search(truth, out, re.I)) if (truth and out) else (None if truth is None else False)
        lk = dead_hits(out, dead) if out else []
        extra = []
        if "<private" in out.lower(): extra.append("private-tag")
        if TOKRE.search(out): extra.append("token")
        R.append({"lane": lane, "set": st, "i": i, "q": q, "hit": hit, "leak": bool(lk or extra), "leaks": lk + extra, "chars": len(out), "ms": round(ms, 1), "out": out, **meta})
    rows += R
    s = {"wall_s": round(time.time() - t0, 1)}
    for st in ("FAMILY", "BENCH91", "HISTORY", "SEAT"):
        S = [r for r in R if r["set"] == st]
        if not S: continue
        ms = sorted(r["ms"] for r in S); ch = sorted(r["chars"] for r in S)
        s[st] = {"n": len(S), "hits": sum(1 for r in S if r["hit"]) if st != "SEAT" else None, "leaks": sum(r["leak"] for r in S),
                 "fired": sum(1 for r in S if r["chars"] > 20), "p50_ms": round(statistics.median(ms)), "p95_ms": round(ms[int(0.95 * (len(ms) - 1))]),
                 "avg_chars": round(statistics.mean(ch)), "p95_chars": ch[int(0.95 * (len(ch) - 1))], "max_chars": ch[-1]}
    B130 = [r for r in R if r["set"] in ("FAMILY", "BENCH91", "HISTORY")]
    if B130: s["bench130_hits"] = sum(1 for r in B130 if r["hit"])
    s["leaks_total"] = sum(r["leak"] for r in R)
    if lane == "zigmem": s["http_codes"] = {str(c): sum(1 for r in R if r.get("code") == c) for c in sorted({r.get("code") for r in R})}
    summ[lane] = s
    print(lane, json.dumps(s))
gate = {}
for zl in ("zigmem", "zigcli"):
    if zl not in summ: continue
    z = summ[zl]
    gate[f"{zl}_zero_leaks_all_sets"] = z["leaks_total"] == 0
    if zl == "zigmem": gate["zigmem_all_http_200"] = set(z.get("http_codes", {})) == {"200"}
    if "live" in summ and "bench130_hits" in z:
        gate[f"{zl}_bench130_ge_live"] = z["bench130_hits"] >= summ["live"]["bench130_hits"]
# per-question deltas on the bench (indexes only)
delta = {}
for zl in [x for x in ("zigmem", "zigcli") if {x, "live"} <= set(summ)]:
    zr = {r["i"]: r for r in rows if r["lane"] == zl}; lr = {r["i"]: r for r in rows if r["lane"] == "live"}
    delta[f"{zl}_only_hits"] = [i for i in zr if zr[i]["hit"] and not lr[i]["hit"] and zr[i]["set"] != "SEAT"]
    delta[f"live_only_hits_vs_{zl}"] = [i for i in zr if lr[i]["hit"] and not zr[i]["hit"] and zr[i]["set"] != "SEAT"]
    delta[f"{zl}_seat_fired_both"] = sum(1 for i in zr if zr[i]["set"] == "SEAT" and zr[i]["chars"] > 20 and lr[i]["chars"] > 20)
    delta[f"{zl}_seat_fired_only"] = sum(1 for i in zr if zr[i]["set"] == "SEAT" and zr[i]["chars"] > 20 and lr[i]["chars"] <= 20)
    delta[f"live_seat_fired_only_vs_{zl}"] = sum(1 for i in zr if zr[i]["set"] == "SEAT" and zr[i]["chars"] <= 20 and lr[i]["chars"] > 20)
fd = os.open(f"{ZM}/scratch/p8/bench_{args.tag}.json", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f: json.dump(rows, f, ensure_ascii=False)
rec = {"load_end": open("/proc/loadavg").read().split()[:3], "load_start": LOAD0, "tag": args.tag, "when": datetime.datetime.now().astimezone().isoformat(timespec="seconds"), "binary_sha256": args.bin_sha,
       "url": args.url, "live_script": LIVE_SCRIPT, "live_env": LIVE_ENV, "live_env_from": LIVE_FROM, "sets": args.sets,
       "n_questions": len(qs), "summary": summ, "gate": gate, "delta_question_indexes": delta,
       "pass": bool(gate) and all(gate.values())}
json.dump(rec, open(f"{ZM}/receipts/phase8/shadow_bench_{args.tag}.json", "w"), indent=1)
print(json.dumps({"gate": gate, "pass": rec["pass"], "delta": {k: (len(v) if isinstance(v, list) else v) for k, v in delta.items()}}))
