#!/usr/bin/env python3
"""Gate (a): differential test — the Zig gates (zig-out/bin/zigmem-gate) vs the Python originals (~/reference_filters.py,
imported READ-ONLY; its trace + medscope log side effects are redirected to scratch) on a generated corpus.

  python3 tests/phase3/diff_gates.py --ledger synthetic|malformed|real [--n 3000] [--seed 7] [--show 20]
                                                        [--extra-queries FILE]   (one query per line, e.g. the family-eval questions)
Writes receipts/phase3/diff_<ledger>_<seed>.json (summary) + diff_<ledger>_<seed>_mismatches.jsonl (on this box only).
--show prints mismatch examples; it refuses with --ledger real (family values never leave the dev box's disk)."""
import argparse, datetime, json, os, random, re, subprocess, sys, tempfile, time

HOME = os.path.expanduser("~")
ZM = os.path.join(HOME, "zigmem")
sys.path.insert(0, HOME)
import reference_filters as F

ap = argparse.ArgumentParser()
ap.add_argument("--ledger", default="synthetic")
ap.add_argument("--n", type=int, default=3000)
ap.add_argument("--seed", type=int, default=7)
ap.add_argument("--show", type=int, default=0)
ap.add_argument("--extra-queries")
ap.add_argument("--bin", default=os.path.join(ZM, "zig-out/bin/zigmem-gate"))
ap.add_argument("--ops", default="")
ap.add_argument("--red", action="store_true", help="negative control: perturb the Zig side (today -1 year, self-echo off); must go RED")
args = ap.parse_args()
if args.show and args.ledger == "real":
    sys.exit("refusing --show with the real ledger")

SCR = tempfile.mkdtemp(prefix="zm_diff_", dir=os.path.join(ZM, "scratch") if os.path.isdir(os.path.join(ZM, "scratch")) else None)
F._TRACE_ON = False
F._MEDSCOPE_LOG = os.path.join(SCR, "medscope_shadow.jsonl")
R = random.Random(args.seed)

# ---------------------------------------------------------------- synthetic ledgers (same schema as the real one, invented values)
SYN = {"facts": [
    {"key": "floor", "as_of": "2026-06-24", "label": "Portfolio floor", "current": "$3.10M (set 6/24)", "dead_money_k": [2770, 2650],
     "dead_keywords": ["floor of $2.77M"], "query_keywords": ["floor", "safe floor"], "history": "$2.77M (5/31) · $2.65M (5/02)",
     "review_by": "2026-12-31", "source": "syn"},
    {"key": "draw", "as_of": "2026-08-18", "label": "Monthly draw", "current": "$11K/mo", "dead_money_k": [19], "query_keywords": ["draw", "monthly"],
     "dead_context": {"words": ["draw", "monthly", "per month"], "window": 40}, "review_by": "2026-01-01"},
    {"key": "zork", "as_of": "2026-07-19", "label": "ZORK position", "current": "1,402 shares", "dead_keywords": ["845 shares", "ZORK 845", "holds 845"],
     "query_keywords": ["zork", "shares"], "review_by": "2027-01-01"},
    {"key": "chair", "as_of": "2026-05-01", "label": "Guild chair", "current": "Marlowe", "dead_keywords": ["Thistlewood is chair", "chair Thistlewood"],
     "query_keywords": ["guild chair"], "review_by": "2026-11-01"},
    {"key": "pill", "as_of": "2026-09-10", "label": "Wren's tablet", "current": "quellamine 10 mg", "dead_keywords": ["takes velastrin", "on velastrin"],
     "dead_core": ["velastrin"], "query_keywords": ["wren", "tablet", "medication"], "review_by": "2026-10-01"},
    {"key": "trip", "as_of": "2026-09-03", "label": "Harbor trip", "current": "Nov 14", "dead_keywords": ["harbor trip oct 1", "trip on october 1"],
     "query_keywords": ["harbor trip", "trip"], "dead_context": {"words": ["trip", "harbor"], "window": 30}, "review_by": "2026-12-01"},
    {"key": "ip", "as_of": "2026-06-27", "label": "Hub address", "current": "203.0.113.8", "dead_keywords": ["203.0.113.7"], "query_keywords": ["hub address", "ip"]},
]}
MAL = {"facts": SYN["facts"] + [
    {"key": "bad0", "as_of": "2026-10-08", "label": "bad zero", "current": "x", "dead_money_k": 0, "query_keywords": ["bad"]},
    {"key": "bad5", "as_of": "2026-10-08", "label": "bad five", "current": "x", "dead_money_k": 5, "query_keywords": ["bad"]},
    {"key": "badstr", "as_of": "2026-10-08", "label": "bad str", "current": "x", "dead_money_k": "abc", "dead_keywords": "zz", "query_keywords": ["bad"]},
    {"key": "badnull", "as_of": None, "label": None, "current": 7, "dead_keywords": None, "query_keywords": None},
    {"key": "badnum", "as_of": 20261008, "label": "num asof", "current": "y", "dead_keywords": ["quorble 999", "quorble 9999"], "query_keywords": [3]},
    "not-a-dict",
]}

if args.ledger == "real":
    led_path = F.LEDGER_PATH
else:
    led_path = os.path.join(SCR, "ledger.json")
    json.dump(SYN if args.ledger == "synthetic" else MAL, open(led_path, "w"))
F.LEDGER_PATH = led_path
F.LEDGER = F._load_ledger()
F._LEDGER_MTIME = os.path.getmtime(led_path)
LED = F.LEDGER
REAL_DEAD, REAL_WORDS = [], []
if args.ledger == "real":   # real-shaped corpus: the ledger's own dead phrasings/figures, mixed in on this box only, never printed
    for f in LED:
        if not isinstance(f, dict): continue
        REAL_DEAD += [k for k in (f.get("dead_keywords") or []) if isinstance(k, str)]
        REAL_DEAD += ["$%sK" % k for k in (f.get("dead_money_k") or []) if isinstance(k, (int, float))]
        REAL_DEAD += ["$%.2fM" % (k / 1000) for k in (f.get("dead_money_k") or []) if isinstance(k, (int, float))]
        REAL_WORDS += [k for k in (f.get("query_keywords") or []) if isinstance(k, str)]
        REAL_WORDS += [str(f.get("current", ""))[:60]]

# ---------------------------------------------------------------- corpus
NAMES = ["Alex", "Morgan", "morgan's", "MORGAN", "Taylor", "Jordan", "Quinn", "Rowan", "rowans", "Sam", "sam", "Dana", "Edith", "Alex’s",
         "the wife", "my daughter", "the girls", "User", "husband", "Morgana", "Quinlan", "alexis"]
MEDS = ["Prozac", "lisinopril 50mg", "lisinopril", "20 mg", "labs", "lab results", "ADHD", "eczema", "asthma", "a1c", "ldl", "Augmentin",
        "UTI", "strep", "birth control", "inhaler", "the pharmacy refill", "antibiotics", "RSV", "hand foot mouth", "medication", "meds", "Rx"]
MONEY = ["$1.5M", "$1,500,000", "$2.0 million", "$16K", "$ 5 k", "$2.77M", "$2,770,000", "$2.65 million", "$19K", "$19,000", "$11K",
         "$0.5k", "$2.5k", "$1.0005M", "$3.10M", "$7 thousand", "$12.5", "$999999999999999999999", "$١٢٣k", "$ 5K", "$5 m", "$1,880"]
DATES = ["Mon 2026-09-22", "Tuesday, 9/22/2026", "Sep 22, 2026 (Tue)", "Tue 9/24", "Fri Oct 3", "Wed, the 2026-10-07", "Sunday 10/12/26",
         "Thu Feb 30, 2026", "Mon 2/29", "Sat 13/45", "Saturday Oct 11", "fri 10/9", "MON 2026-10-12", "Wednesday Jan 5, 2026", "Tue Nov 12",
         "Sun 9/22", "ſun 9/21", "2026-09-21 (Mon)", "Oct 1, 2026, Thursday", "Tue the 9/30", "Friday 2026-02-31"]
LDATES = ["· written 2026-09-21 ", "[Vol 10 · 2026-09-29] ", "[Vol 9b · 2026-06-30] ", "· written 2026-13-40 ", "· written 2026-09-2١ "]
REL = ["yesterday", "today", "tonight", "last night", "tomorrow", "this morning", "Yesterday", "TODAY"]
CUES = ["no longer", "was $", "superseded", "previously", "⟵", "corrected", "replaced", "not valid", "instead of", "is dead", "never quote"]
SEP = ["; ", ": ", ", ", ". ", " — ", " - ", " but ", " | ", "\n", " ", " and "]
ECHO = ["Assistant reported that", "The assistant noted", "Assistant has updated", "assistant (the assistant) ran", "Let me check",
        "I'll look", "Here's what", "As of 2026-07-23, the assistant notes that", "On 2026-07-01, Assistant", "[ASSISTANT]: ok", "Still here.",
        "Assistant is here", "Done.", "got it—", "the assistant is wrong and corrected it"]
TRANS = ["[Session 2026-07-08] [USER]: hi", "[warm-up: do not speak any of this]", "=== PAST MEMORIES ===", "### 07:24", "| a | b | c |",
         "ok", "ready", "<task-notification>x</task-notification>", "--- vector store (3) ---", "[voice call with Alex]"]
TOOL = ["Wrote /home/x/notes/file.md: ---", "Edited ~/proj/a.py", "User wrote a markdown file titled 'X' located at /mnt/c/a/b.md classified as note",
        "User edited /home/user/heartbeat.py on 2026-07-02", "Alex created a Bash script at /tmp/x/y.sh defining", "see toolu_01ABCDEFGHIJKL",
        "ran /opt/app/scripts/x.sh", "foo /var/log/syslog"]
MT = ["READY", "ping | pong", "Q: reply with the single word READY | A: READY", "Session abc123 ended.", "session over",
      "<relevant-memories>old stuff</relevant-memories> hello there", "[Assistant Session 2026-07-08] [USER]: ready", "CONTINUITY-CANARY 42",
      "PRIME TEST row", "[voice warm-up] reply now", "User: ping", "A: pong | Q: ready", "[x] Reply with the single word READY.",
      "Morgan's recheck is Nov 3", "hello <private>pin 4455</private> there", "a <PRIVATE >b", "x < / private > y"]
PRIV = ["<private>secret</private>", "< PRIVATE >s</ private >", "<private>unclosed", "<PrIvAtE>x</pRiVaTe>", "<prİvate>i</private>",
        "<prıvate>dotless</prıvate>", "<private>a</private> mid <private>b</private>", "< private >nbsp</private>"]
UNI = ["İstanbul", "ıi", "ſtrong", "K", "x y", "café", "naïve", "ＡＢＣ１２３", "١٢٣", "Straße", "ǅ", "ﬁle", "Ωmega", "é"]
WORDS = ("the of and family house plan money portfolio note vault memory floor draw trip zork shares harbor chair guild hub address tablet "
         "wren quellamine velastrin Thistlewood Marlowe holds takes on is was set agreed with Stan every each typically currently right now "
         "just now at the moment weekly sold bought 845 1,402 203.0.113.7 203.0.113.8 floor-reclaim october 1 oct 1 nov 14 monthly per month").split()
SYN_DEAD = ["floor of $2.77M", "845 shares", "ZORK 845", "holds 845", "845 ZORK shares", "Thistlewood is chair", "takes velastrin",
            "medications include Velastrin", "harbor trip oct 1", "trip on october 1", "203.0.113.7", "$19K draw", "monthly draw of $19,000",
            "$2.65 million floor", "the $19K request in October"]
QUERIES = ["what medications does Morgan take", "whats morgan taking for her mood", "what is Rowan's adhd med", "how is Jordan's asthma",
           "what did Alex and Morgan decide", "what is the floor", "what is the monthly draw", "who is the guild chair", "zork shares",
           "what is Wren's tablet", "when is the harbor trip", "hub address ip", "what does she take", "Quinn labs", "sam's pills",
           "does Dana have a prescription", "Edith", "what is the plan", "Taylor’s antibiotics", "MORGAN meds", "bad"]

def frag():
    k = R.random()
    pools = [NAMES, MEDS, MONEY, DATES, REL, CUES, WORDS, WORDS, WORDS, SYN_DEAD, UNI] + ([REAL_DEAD, REAL_DEAD, REAL_WORDS] if REAL_DEAD else [])
    return R.choice(R.choice(pools))

def line():
    k = R.random()
    if k < 0.08: head = R.choice(ECHO)
    elif k < 0.13: head = R.choice(TRANS)
    elif k < 0.18: head = R.choice(TOOL)
    elif k < 0.25: head = R.choice(MT)
    elif k < 0.30: head = R.choice(LDATES)
    else: head = ""
    parts = [head] if head else []
    for _ in range(R.randint(1, 14)):
        parts.append(frag())
        if R.random() < 0.45: parts.append(R.choice(SEP))
        elif R.random() < 0.05: parts.append(R.choice(PRIV))
    s = " ".join(p for p in parts if p).replace("  ", " ")
    if R.random() < 0.1: s = "  " + s + "  \n"
    if R.random() < 0.05: s = s.upper()
    return s

FIXED = ["a <private>secret pw</private> b", "x < PRIVATE >secret</ private > y", "keep this <private>secret forever",
         "<private>a</private> mid <private>b</private>", "plain text", "Morgan said <private>her diagnosis</private> today",
         F.strip_private("Morgan said <private>x</private> today about the nails"),
         json.dumps({"type": "user", "message": {"role": "user", "content": "go ahead <private>my bank pin is 4455\nand \"quoted\"</private> thanks"}}),
         json.dumps({"c": "a <private>leak"}), '{"a": 1}', "hello there <private>x</private> friend", "<private>x</private>",
         "", " ", "\n", "Prozac is NOT Morgan's prescription; Jordan takes Prozac.", "Morgan takes lisinopril. Jordan takes Prozac 20mg.",
         "The wife takes lisinopril; Rowan has asthma.", "Alex's labs: a1c 5.4", "Mon 2026-09-22 was busy", "Tue 9/24 meeting",
         "· written 2026-09-21 [x] yesterday we met", "[Vol 10 · 2026-09-29] tonight and tomorrow", "floor is $2.77M", "floor was $2.77M, now $3.10M",
         "the $2.77M floor is no longer valid", "ZORK 845 position", "We hold 845 ZORK shares", "Velastrin is on the list for Wren",
         "medications include Velastrin", "monthly draw $19K", "The $19K October request", "harbor trip oct 1!", "trip on October 1 to the harbor",
         "203.0.113.7 is the hub", "LAN address changed from 203.0.113.7 to 203.0.113.8", "⚠[LEDGER already] floor $2.77M"]
lines = FIXED + [line() for _ in range(args.n)]
queries = QUERIES[:]
if args.extra_queries:
    queries += [q.strip() for q in open(args.extra_queries) if q.strip()]
    if args.show: sys.exit("refusing --show with extra (real) queries")

TARGETS = ["alex", "morgan", "taylor", "jordan", "quinn", "rowan", "sam", "dana", "edith"]
CREATED = [None, None, "2026-01-01", "2026-06-24", "2026-06-25T10:00", "2027-01-01", "", "2026-09-10"]
reqs = []
want_ops = set(args.ops.split(",")) if args.ops else None
for i, t in enumerate(lines):
    for op in ["has_private", "strip_private", "private_line", "is_machine_traffic", "is_self_echo", "is_dated_claim", "is_transcript_dump",
               "is_tool_log", "is_correction", "ledger_scrub", "weekday_check", "resolve_relative", "money_tokens_k", "named_family"]:
        reqs.append({"op": op, "text": t})
    c = R.choice(CREATED)
    reqs.append({"op": "rejection_reason", "text": t, "created": c})
    reqs.append({"op": "ledger_reject", "text": t, "created": R.choice(CREATED)})
    tg = R.choice(TARGETS)
    reqs.append({"op": "medical_cross_person", "text": t, "target": tg})
    reqs.append({"op": "medical_mixed_others", "text": t, "target": tg})
for i in range(0, len(lines), 5):
    for q in R.sample(queries, min(3, len(queries))):
        reqs.append({"op": "medical_subject_gate", "rows": lines[i:i + 5], "query": q, "mode": R.choice(["enforce", "enforce", "shadow", "off"])})
for q in queries + [l for l in lines[:300]]:
    reqs.append({"op": "ledger_lines", "text": q})
if want_ops: reqs = [r for r in reqs if r["op"] in want_ops]

# ---------------------------------------------------------------- python side
def py(r):
    op, t = r["op"], r.get("text", "")
    if op == "has_private": return F.has_private(t)
    if op == "strip_private": return F.strip_private(t)
    if op == "private_line": return F.private_line(t)
    if op == "is_machine_traffic": return F.is_machine_traffic(t)
    if op == "is_self_echo": return F.is_self_echo(t)
    if op == "is_dated_claim": return F.is_dated_claim(t)
    if op == "is_transcript_dump": return F.is_transcript_dump(t)
    if op == "is_tool_log": return F.is_tool_log(t)
    if op == "is_correction": return F.is_correction(t)
    if op == "ledger_scrub": return F.ledger_scrub(t)
    if op == "weekday_check": return F.weekday_check(t)
    if op == "resolve_relative": return F.resolve_relative(t)
    if op == "money_tokens_k": return sorted(F.money_tokens_k(t))
    if op == "named_family": return sorted(F.named_family(t))
    if op == "rejection_reason": return F.rejection_reason(t, r["created"])
    if op == "ledger_reject": return F.ledger_reject(t, r["created"]) == "superseded"
    if op == "medical_cross_person": return F.medical_cross_person(t, r["target"])
    if op == "medical_mixed_others": return F.medical_mixed_others(t, r["target"])
    if op == "medical_subject_gate":
        os.environ["ZIGMEM_MEDSCOPE_MODE"] = r["mode"]
        return F.medical_subject_gate(r["rows"], query=r["query"])
    if op == "ledger_lines": return "".join(x + "\n" for x in F.ledger_lines(t))
    raise ValueError(op)

t0 = time.time()
want = [py(r) for r in reqs]
t_py = time.time() - t0
cfg = ",".join("1" if F.CONFIG.get(k, True) else "0" for k in ("drop_self_echo", "drop_dated_claims", "drop_transcript_dumps", "drop_tool_logs"))
today = datetime.date.today().isoformat()
inp = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in reqs)
t0 = time.time()
ztoday, zcfg = (today, cfg) if not args.red else ((datetime.date.today() - datetime.timedelta(days=366)).isoformat(), "0" + cfg[1:])
p = subprocess.run([args.bin, "--ledger", led_path, "--today", ztoday, "--cfg", zcfg], input=inp.encode(), capture_output=True)
t_zig = time.time() - t0
got = [json.loads(l) for l in p.stdout.decode().split("\n") if l]
assert len(got) == len(reqs), (len(got), len(reqs), p.stderr.decode()[-2000:])

per = {}
mism = []
cov = {}
def nontrivial(r, w):
    t = r.get("text", "")
    if isinstance(w, bool): return w
    if w is None: return False
    if isinstance(w, str): return w != t and not (r["op"] == "ledger_lines" and w == "")
    if isinstance(w, list): return (w != r.get("rows")) if r["op"] == "medical_subject_gate" else bool(w)
    return True
t_in = lambda r: r.get("text", "")
for r, w, gz in zip(reqs, want, got):
    o = per.setdefault(r["op"], [0, 0, 0])
    o[0] += 1
    cov[r["op"]] = cov.get(r["op"], 0) + bool(nontrivial(r, w))
    z = gz.get("out", ("ERR", gz.get("err")))
    if isinstance(w, list) and r["op"] == "money_tokens_k":
        ok = isinstance(z, list) and [float(x) for x in w] == [float(x) for x in z]
    else:
        ok = (w == z)
    if not ok:
        # Known reference leak (listed, never hidden): private_line's fast path `"rivate" not in line.lower()` misses tags spelled with
        # U+0131/U+0130 (and, before the supervisor's fix, mixed case) although its own regex matches them; the Zig strips them.
        if r["op"] == "private_line" and w == t_in(r) and F._PRIV_OPEN_RE.search(t_in(r)) and z != w:
            o[2] += 1
            mism.append({"class": "py_leak_private_fastpath", "req": r, "py": w, "zig": z})
            continue
        o[1] += 1
        mism.append({"class": "mismatch", "req": r, "py": w, "zig": z})
tot = sum(v[0] for v in per.values()); bad = sum(v[1] for v in per.values()); leak = sum(v[2] for v in per.values())
summary = {"ledger": args.ledger, "seed": args.seed, "lines": len(lines), "queries": len(queries), "calls": tot, "mismatches": bad, "py_reference_leaks_zig_stricter": leak,
           "match_pct": round(100.0 * (tot - bad) / max(tot, 1), 4), "per_op": {k: {"calls": v[0], "mismatch": v[1], "py_leak": v[2], "nontrivial_py_results": cov.get(k, 0)} for k, v in sorted(per.items())},
           "red_control": args.red,
           "today": today, "cfg": cfg, "py_s": round(t_py, 2), "zig_s": round(t_zig, 2), "source_sha16": __import__("hashlib").sha256(open(F.__file__, "rb").read()).hexdigest()[:16]}
os.makedirs(os.path.join(ZM, "receipts/phase3"), exist_ok=True)
base = os.path.join(ZM, "receipts/phase3", f"diff_{args.ledger}_{args.seed}" + ("_RED" if args.red else ""))
json.dump(summary, open(base + ".json", "w"), indent=1, ensure_ascii=False)
with open(base + "_mismatches.jsonl", "w") as f:
    for m in mism: f.write(json.dumps(m, ensure_ascii=False) + "\n")
print(json.dumps({k: v for k, v in summary.items() if k != "per_op"}))
print("coverage (non-trivial python results per op):", {k: v["nontrivial_py_results"] for k, v in summary["per_op"].items()})
for k, v in summary["per_op"].items():
    if v["mismatch"] or v["py_leak"]: print(f"  {k}: mismatch {v['mismatch']}/{v['calls']} · python-leak (zig stricter) {v['py_leak']}")
for m in [m for m in mism if m["class"] == "mismatch"][:args.show]:
    print(json.dumps(m, ensure_ascii=False)[:700])
