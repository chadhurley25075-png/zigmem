#!/usr/bin/env python3
"""INTEGRATION gate 3: the phase-3 bench THROUGH THE API. The 130 questions (FAMILY 93 + BENCH91 15 + HISTORY 22) and the
family-eval leak metric are IMPORTED from ~/bench_lane/bench.py and ~/bench_eval/family_memory_eval.py
(never copied), graded exactly like tests/phase3/bench_zigmem.py (truth regex re.I; dead_hits).

Lanes (all measured today, same box):
  zigmem-api  POST /v1/recall to `zigmem serve` over a COPY of the phase-3 bench store (scratch/p3/zm.db), as Alex's seat
              `alex-term` (household: alex + morgan principals, the four girls children; token `*`, read-only). Phase-3 gates +
              the household row gate. Reranker = the dev box 127.0.0.1:18098 only (family text stays on the dev box).
  zigmem-cli  the phase-3 CLI (zigmem-recall query) from the integrated tree on the same copy, --min-rerank 0.50, the dev box
              reranker only: the integration's privacy-code changes without the household layer (control).
  live-local  the live the reranked lane hook code (rerank_lane_plus.py) with the live knobs, but its two off-box hops pinned
              to the dev box: BLEND_RERANK_URL=the dev box (not the LAN reranker) and BLEND_EXTRA_SOURCES="" (no the cloud store cloud).
  live        (only with --allow-offbox) the exact live hook env — sends family questions to the x86 box + the cloud store. Not run by default.
Full outputs → scratch/integ/bench/bench_<tag>.json (family text, the dev box only); counts → receipts/integration/bench/."""
import argparse, datetime, http.client, json, os, re, shutil, signal, statistics, subprocess, sys, time
import concurrent.futures as cf

HOME = os.path.expanduser("~")
ZM = f"{HOME}/zigmem"
sys.path.insert(0, f"{HOME}/bench_lane")
sys.path.insert(0, f"{HOME}/bench_eval")
import bench as B
from family_memory_eval import dead_hits

ap = argparse.ArgumentParser()
ap.add_argument("--lanes", default="zigmem-api,zigmem-cli,live-local")
ap.add_argument("--bindir", default=f"{ZM}/scratch/integ/tree/out/bin")
ap.add_argument("--src", default=f"{ZM}/scratch/p3/zm.db")
ap.add_argument("--home", default=f"{ZM}/scratch/integ/bench/home")
ap.add_argument("--port", type=int, default=18195)
ap.add_argument("--par", type=int, default=4)
ap.add_argument("--tag", default=time.strftime("%Y%m%d-%H%M"))
ap.add_argument("--fresh", action="store_true", help="re-copy the bench store")
ap.add_argument("--allow-offbox", action="store_true")
ap.add_argument("--serve-args", default="", help="extra `zigmem serve` flags, e.g. --rerank http://127.0.0.1:18098/rerank (3 s leash)")
args = ap.parse_args()
REC = f"{ZM}/receipts/integration/bench"
SCR = f"{ZM}/scratch/integ/bench"
os.makedirs(REC, exist_ok=True)
os.makedirs(SCR, exist_ok=True)
TODAY = datetime.date.today().isoformat()
Z = f"{args.bindir}/zigmem"

qs = []
for q, truth, dead, cls in B.ITEMS:
    qs.append(("FAMILY", cls, q, truth, dead))
for q, truth, cls in B.BENCH91:
    qs.append(("BENCH91", cls, q, truth, []))
for q, truth in B.HISTORY:
    qs.append(("HISTORY", "history", q, truth, []))

LIVE_ENV = {"BLEND_SOURCES": "journal,synth,vault,facts,notes,agi,osmem", "BLEND_MIN_SCORE": "0.50", "BLEND_EXTRA_SOURCES": "smfacts,smsynth",
            "BLEND_TEMPORAL_K": "8", "BLEND_PER_SOURCE": "5", "BLEND_RERANK_CHARS": "700", "BLEND_BUDGET": "3000"}
LOCAL_ENV = dict(LIVE_ENV, BLEND_EXTRA_SOURCES="", BLEND_RERANK_URL="http://127.0.0.1:18098/rerank", BLEND_RERANK_FALLBACK="")
PLUS = f"{HOME}/bench_lane/rerank_lane_plus.py"
STOPS = []

HH = {"members": [{"id": "alex", "display": "Alex Harper", "role": "principal", "relation": "father"},
                  {"id": "morgan", "display": "Morgan Harper", "role": "principal", "relation": "mother"},
                  {"id": "taylor", "display": "Taylor Harper", "role": "child"}, {"id": "jordan", "display": "Jordan Harper", "role": "child"},
                  {"id": "quinn", "display": "Quinn Harper", "role": "child"}, {"id": "rowan", "display": "Rowan Harper", "role": "child"}],
      "seats": [{"name": "alex-term", "member": "alex"}]}


def setup():
    db = f"{args.home}/zigmem.db"
    if args.fresh or not os.path.exists(db):
        subprocess.run(["rm", "-rf", args.home], check=True)
        os.makedirs(args.home, mode=0o700)
        t = time.time()
        # a consistent copy (the source is idle; sqlite's backup API keeps it exact)
        import sqlite3
        src = sqlite3.connect(f"file:{args.src}?mode=ro", uri=True)
        dst = sqlite3.connect(db)
        src.backup(dst)
        dst.close()
        src.close()
        json.dump(HH, open(f"{args.home}/household.json", "w"))
        subprocess.run([Z, "household", "bootstrap", "--home", args.home, "--file", f"{args.home}/household.json"], check=True, capture_output=True)
        print("copied bench store in", round(time.time() - t, 1), "s")
    tf = f"{args.home}/alex-term.token"
    if not os.path.exists(tf):
        tok = subprocess.run([Z, "token", "add", "--home", args.home, "--seat", "alex-term", "--scopes", "*"], check=True, capture_output=True, text=True).stdout.strip()
        fd = os.open(tf, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(fd, tok.encode())
        os.close(fd)
    return open(tf).read().strip()


def start():
    log = open(f"{SCR}/serve_{args.tag}.log", "w")
    p = subprocess.Popen([Z, "serve", "--home", args.home, "--port", str(args.port), "--today", TODAY] + args.serve_args.split(), stdout=log, stderr=subprocess.STDOUT)
    for _ in range(600):  # the vector index (~395K x 768) loads first
        try:
            c = http.client.HTTPConnection("127.0.0.1", args.port, timeout=2)
            c.request("GET", "/health")
            if c.getresponse().status == 200:
                return p, log
        except OSError:
            pass
        if p.poll() is not None:
            raise RuntimeError("serve exited")
        time.sleep(0.5)
    raise RuntimeError("serve did not come up")


def api_lane(tok):
    def one(q):
        t = time.time()
        try:
            c = http.client.HTTPConnection("127.0.0.1", args.port, timeout=60)
            c.request("POST", "/v1/recall", body=json.dumps({"query": q}), headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"})
            r = c.getresponse()
            b = json.loads(r.read())
            c.close()
            return b.get("context", ""), (time.time() - t) * 1000, {"rerank": b.get("rerank"), "rows": b.get("memory_count")}
        except Exception as e:
            return "", (time.time() - t) * 1000, {"err": str(e)}
    with cf.ThreadPoolExecutor(args.par) as ex:
        return list(ex.map(lambda x: one(x[2]), qs))


def cli_lane():
    led = f"{HOME}/.claude/current_facts_ledger.json"
    cmd = [f"{args.bindir}/zigmem-recall", "query", "--db", f"{args.home}/zigmem.db", "--ledger", led, "--today", TODAY, "--min-rerank", "0.50",
           "--rerank", "http://127.0.0.1:18098/rerank", "--rerank-fallback", "none"]
    inp = "".join(json.dumps({"prompt": q[2]}) + "\n" for q in qs)
    p = subprocess.run(cmd, input=inp.encode(), capture_output=True, timeout=3600)
    lines = [json.loads(l) for l in p.stdout.decode().split("\n") if l]
    assert len(lines) == len(qs), (len(lines), p.stderr.decode()[-800:])
    return [(l.get("out", ""), l.get("ms", 0), {"rerank": l.get("rerank"), "rows": l.get("rows")}) for l in lines]


def py_lane(env):
    with cf.ThreadPoolExecutor(args.par) as ex:
        outs = list(ex.map(lambda q: B.run_lane((PLUS, env), q[2]), qs))
    return [(o, ms, {}) for o, ms in outs]


tok = setup()
res = {}
P = None
try:
    for ln in args.lanes.split(","):
        t = time.time()
        if ln == "zigmem-api":
            P, log = start()
            res[ln] = api_lane(tok)
            P.send_signal(signal.SIGTERM)
            P.wait(15)
            STOPS.append({"pid": P.pid, "gone": P.poll() is not None})
            log.close()
            P = None
        elif ln == "zigmem-cli":
            res[ln] = cli_lane()
        elif ln == "live-local":
            res[ln] = py_lane(LOCAL_ENV)
        elif ln == "live":
            if not args.allow_offbox:
                sys.exit("refusing the exact live lane without --allow-offbox (it sends family questions to the x86 box + the cloud store)")
            res[ln] = py_lane(LIVE_ENV)
        print(ln, "done in", round(time.time() - t, 1), "s", flush=True)
finally:
    if P is not None:
        P.kill()
        P.wait(5)
        STOPS.append({"pid": P.pid, "gone": P.poll() is not None, "killed": True})

rows, summary = [], {}
for ln, outs in res.items():
    R = []
    for (st, cls, q, truth, dead), (out, ms, meta) in zip(qs, outs):
        hit = bool(re.search(truth, out, re.I)) if out else False
        leaks = dead_hits(out, dead) if out else []
        R.append({"lane": ln, "set": st, "cls": cls, "q": q, "hit": hit, "leak": bool(leaks), "leaks": leaks, "chars": len(out), "ms": round(ms), "meta": meta, "out": out})
    rows += R
    s = {"ALL": sum(r["hit"] for r in R), "n": len(R), "leaks": sum(r["leak"] for r in R), "family_leaks": sum(r["leak"] for r in R if r["set"] == "FAMILY"),
         "fired": sum(1 for r in R if r["chars"] > 20), "avg_chars": int(statistics.mean(r["chars"] for r in R)), "p50_ms": int(statistics.median(r["ms"] for r in R)),
         "rerank": {k: sum(1 for r in R if r["meta"].get("rerank") == k) for k in ("primary", "fallback", "down", "off")}}
    for st in ("FAMILY", "BENCH91", "HISTORY"):
        S = [r for r in R if r["set"] == st]
        s[st] = f"{sum(r['hit'] for r in S)}/{len(S)}"
    summary[ln] = s
lanes = list(res)
delta = {}
for a in lanes:
    for b in lanes:
        if a < b:
            ha = [r["hit"] for r in rows if r["lane"] == a]
            hb = [r["hit"] for r in rows if r["lane"] == b]
            delta[f"{a}_only_vs_{b}"] = [i for i, (x, y) in enumerate(zip(ha, hb)) if x and not y]
            delta[f"{b}_only_vs_{a}"] = [i for i, (x, y) in enumerate(zip(ha, hb)) if y and not x]
leak_idx = {ln: [i for i, r in enumerate([r for r in rows if r["lane"] == ln]) if r["leak"]] for ln in lanes}
json.dump(rows, open(f"{SCR}/bench_{args.tag}.json", "w"), ensure_ascii=False)
json.dump({"tag": args.tag, "today": TODAY, "summary": summary, "delta_question_indexes": delta, "leak_question_indexes": leak_idx, "stops": STOPS,
           "lanes_note": __doc__.split("Lanes")[1].split("Full outputs")[0]}, open(f"{REC}/bench_{args.tag}.json", "w"), indent=1)
print(f"{'lane':13}{'FAMILY':>9}{'BENCH91':>9}{'HISTORY':>9}{'ALL':>9}{'leaks':>7}{'famleak':>8}{'fired':>7}{'avgch':>7}{'p50ms':>7}")
for ln, s in summary.items():
    print(f"{ln:13}{s['FAMILY']:>9}{s['BENCH91']:>9}{s['HISTORY']:>9}{str(s['ALL'])+'/'+str(s['n']):>9}{s['leaks']:>7}{s['family_leaks']:>8}{s['fired']:>7}{s['avg_chars']:>7}{s['p50_ms']:>7}  rerank={s['rerank']}")
for k, v in delta.items():
    print(f"  {k}: {v}")
print("leak question indexes:", leak_idx)
