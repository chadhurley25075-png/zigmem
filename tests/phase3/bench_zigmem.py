#!/usr/bin/env python3
"""Gates (b) + (c): zigmem retrieval through the Zig gates vs the live the reranked lane lanes, graded EXACTLY like
~/bench_lane/bench.py (truth regex, re.I) and ~/bench_eval/family_memory_eval.py (dead_hits: a dead value on a
line with no correction cue). Question sets are imported from those files, never copied.

  python3 tests/phase3/bench_zigmem.py --lanes zigmem,live,same [--zig-args "..."] [--tag NAME]

Lanes: live = the exact UserPromptSubmit hook env (rerank_lane_plus.py) · same = rerank_lane.py over the SAME sources zigmem
was loaded from (journal,synth,vault,facts,notes) with the live knobs · zigmem / zigmem-wide / zigmem-down (variants).
Full outputs → scratch/p3/bench_<tag>.json (family text, the dev box only). Counts → receipts/phase3/bench_<tag>.json."""
import argparse, json, os, re, statistics, subprocess, sys, time, datetime
import concurrent.futures as cf

HOME = os.path.expanduser("~")
ZM = f"{HOME}/zigmem"
sys.path.insert(0, f"{HOME}/bench_lane")
sys.path.insert(0, f"{HOME}/bench_eval")
import bench as B                       # ITEMS, BENCH91, HISTORY, run_lane (main() is guarded)
from family_memory_eval import dead_hits

ap = argparse.ArgumentParser()
ap.add_argument("--lanes", default="zigmem,live,same")
ap.add_argument("--db", default=f"{ZM}/scratch/p3/zm.db")
ap.add_argument("--bin", default=f"{ZM}/zig-out/p3dev/bin/zigmem-recall")
ap.add_argument("--zig-args", default="")
ap.add_argument("--tag", default=time.strftime("%Y%m%d-%H%M"))
ap.add_argument("--par", type=int, default=4)
args = ap.parse_args()

qs = []
for q, truth, dead, cls in B.ITEMS:
    qs.append(("FAMILY", cls, q, truth, dead))
for q, truth, cls in B.BENCH91:
    qs.append(("BENCH91", cls, q, truth, []))
for q, truth in B.HISTORY:
    qs.append(("HISTORY", "history", q, truth, []))

LIVE_ENV = {"BLEND_SOURCES": "journal,synth,vault,facts,notes,agi,osmem", "BLEND_MIN_SCORE": "0.50", "BLEND_EXTRA_SOURCES": "smfacts,smsynth",
            "BLEND_TEMPORAL_K": "8", "BLEND_PER_SOURCE": "5", "BLEND_RERANK_CHARS": "700", "BLEND_BUDGET": "3000"}
SAME_ENV = dict(LIVE_ENV, BLEND_SOURCES="journal,synth,vault,facts,notes", BLEND_EXTRA_SOURCES="")
PY_LANES = {"live": (f"{HOME}/bench_lane/rerank_lane_plus.py", LIVE_ENV),
            "same": (f"{HOME}/bench_lane/rerank_lane.py", SAME_ENV)}
ZIG_LANES = {"zigmem": ["--min-rerank", "0.50"],
             "zigmem-lenient": ["--min-rerank", "0.50", "--fill-lenient"],
             "zigmem-wide": ["--min-rerank", "0", "--keep", "24", "--rerank-n", "40", "--budget", "40000", "--fact-fill", "0"],
             "zigmem-down": ["--rerank", "http://127.0.0.1:9/rerank", "--rerank-fallback", "http://127.0.0.1:9/rerank"]}


def run_zig(extra):
    led = f"{HOME}/.claude/current_facts_ledger.json"
    cmd = [args.bin, "query", "--db", args.db, "--ledger", led, "--today", datetime.date.today().isoformat()] + extra + args.zig_args.split()
    inp = "".join(json.dumps({"prompt": q[2]}) + "\n" for q in qs)
    t = time.time()
    p = subprocess.run(cmd, input=inp.encode(), capture_output=True, timeout=3600)
    lines = [json.loads(l) for l in p.stdout.decode().split("\n") if l]
    assert len(lines) == len(qs), (len(lines), p.stderr.decode()[-1500:])
    return [(l.get("out", ""), l.get("ms", 0), l) for l in lines], round(time.time() - t, 1), p.stderr.decode()[-300:]


res, meta = {}, {}
for ln in args.lanes.split(","):
    if ln in ZIG_LANES:
        out, wall, err = run_zig(ZIG_LANES[ln])
        res[ln] = out
        meta[ln] = {"wall_s": wall, "stderr_tail": err, "rerank_used": {k: sum(1 for o in out if o[2].get("rerank") == k) for k in ("primary", "fallback", "down", "off")},
                    "embed_ok": sum(1 for o in out if o[2].get("embed")), "medical_dropped": sum(o[2].get("medical_dropped", 0) for o in out)}
    else:
        spec = PY_LANES[ln]
        with cf.ThreadPoolExecutor(args.par) as ex:
            outs = list(ex.map(lambda q: B.run_lane(spec, q[2]), qs))
        res[ln] = [(o, ms, {}) for o, ms in outs]

rows, summary = [], {}
for ln, outs in res.items():
    R = []
    for (st, cls, q, truth, dead), (out, ms, _) in zip(qs, outs):
        hit = bool(re.search(truth, out, re.I)) if out else False
        leaks = dead_hits(out, dead) if out else []
        R.append({"lane": ln, "set": st, "cls": cls, "q": q, "hit": hit, "leak": bool(leaks), "leaks": leaks, "chars": len(out), "ms": round(ms), "out": out})
    rows += R
    s = {"ALL": sum(r["hit"] for r in R), "n": len(R), "leaks": sum(r["leak"] for r in R),
         "family_leaks": sum(r["leak"] for r in R if r["set"] == "FAMILY"), "fired": sum(1 for r in R if r["chars"] > 20),
         "avg_chars": int(statistics.mean(r["chars"] for r in R)), "p50_ms": int(statistics.median(r["ms"] for r in R))}
    for st in ("FAMILY", "BENCH91", "HISTORY"):
        S = [r for r in R if r["set"] == st]
        s[st] = f"{sum(r['hit'] for r in S)}/{len(S)}"
    s.update(meta.get(ln, {}))
    summary[ln] = s
# per-question deltas (indices only in the receipt; question text stays in scratch)
lanes = list(res)
delta = {}
for a in lanes:
    for b in lanes:
        if a < b:
            ha = [r["hit"] for r in rows if r["lane"] == a]
            hb = [r["hit"] for r in rows if r["lane"] == b]
            delta[f"{a}_only_vs_{b}"] = [i for i, (x, y) in enumerate(zip(ha, hb)) if x and not y]
            delta[f"{b}_only_vs_{a}"] = [i for i, (x, y) in enumerate(zip(ha, hb)) if y and not x]
os.makedirs(f"{ZM}/scratch/p3", exist_ok=True)
json.dump(rows, open(f"{ZM}/scratch/p3/bench_{args.tag}.json", "w"), ensure_ascii=False)
json.dump({"tag": args.tag, "today": datetime.date.today().isoformat(), "zig_args": args.zig_args, "summary": summary, "delta_question_indexes": delta},
          open(f"{ZM}/receipts/phase3/bench_{args.tag}.json", "w"), indent=1)
print(f"{'lane':13}{'FAMILY':>9}{'BENCH91':>9}{'HISTORY':>9}{'ALL':>9}{'leaks':>7}{'famleak':>8}{'fired':>7}{'avgch':>7}{'p50ms':>7}")
for ln, s in summary.items():
    print(f"{ln:13}{s['FAMILY']:>9}{s['BENCH91']:>9}{s['HISTORY']:>9}{str(s['ALL'])+'/'+str(s['n']):>9}{s['leaks']:>7}{s['family_leaks']:>8}{s['fired']:>7}{s['avg_chars']:>7}{s['p50_ms']:>7}")
    if ln in meta: print("   ", {k: v for k, v in meta[ln].items() if k != "stderr_tail"})
for k, v in delta.items():
    print(f"  {k}: {len(v)}")
