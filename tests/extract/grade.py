#!/usr/bin/env python3
"""Grade one zigmem-extractgate run (JSONL on stdin or a path) against tests/extract/turns.json. Stdlib only.
usage: grade.py RUN.jsonl [turns.json] [--json OUT.json]"""
import json, re, sys, os, statistics

args = [a for a in sys.argv[1:] if not a.startswith("--")]
out_json = sys.argv[sys.argv.index("--json") + 1] if "--json" in sys.argv else None
run_path = args[0]
set_path = args[1] if len(args) > 1 and args[1] != out_json else os.path.join(os.path.dirname(os.path.abspath(__file__)), "turns.json")
S = json.load(open(set_path))
lines = [json.loads(l) for l in open(run_path) if l.strip().startswith("{")]
turns = {l["turn_id"]: l for l in lines if l["kind"] == "turn"}
rows = [l for l in lines if l["kind"] == "row"]
summ = next((l for l in lines if l["kind"] == "summary"), {})
truth = {t["id"]: t for t in S["turns"]}

def tid(r):
    m = re.match(r"turn=(\d+)", r["src"])
    return int(m.group(1)) if m else -1

R = {}
# 1. JSON validity over turns that reached the model
model_turns = [l for l in turns.values() if l.get("valid_first") is not None]
errored = [l for l in turns.values() if l.get("error")]
R["turns_total"] = len(S["turns"])
R["turns_logged"] = len(turns)
R["turns_errored"] = [(l["turn_id"], l["error"]) for l in errored]
R["turns_to_model"] = len(model_turns)
R["valid_first"] = sum(1 for l in model_turns if l["valid_first"])
R["valid_final"] = sum(1 for l in model_turns if l["valid_final"])
den = len(model_turns) + len(errored)  # an errored turn (timeout etc.) counts as invalid
R["valid_first_pct"] = round(100 * R["valid_first"] / den, 1) if den else None
R["valid_final_pct"] = round(100 * R["valid_final"] / den, 1) if den else None
R["first_errors"] = {l["turn_id"]: l["first_errors"][:3] for l in model_turns if not l["valid_first"]}
R["skipped"] = {l["turn_id"]: l["skipped"] for l in turns.values() if l.get("skipped")}

# 2. expected facts, attribution, status
found = attr_ok = status_ok = considered = 0
misses, wrong_subject, wrong_status = [], [], []
for t in S["turns"]:
    lg = turns.get(t["id"], {})
    items = [x for x in lg.get("applied", []) if x["action"] in ("insert", "supersede", "correct", "skip")]
    for e in t["expect"]:
        hits = [x for x in items if re.search(e["re"], x["text"])]
        if e["status"] == "pending_or_none":
            if any(x["status"] != "pending_review" for x in hits):
                wrong_status.append((t["id"], [(x["subject"], x["status"], x["text"]) for x in hits]))
            continue
        considered += 1
        if not hits:
            misses.append((t["id"], e["re"], [x["text"] for x in items]))
            continue
        found += 1
        good = [x for x in hits if x["subject"] in e["subjects"] or (x["subject"] not in [p["id"] for p in S["people"]] and "unknown" in e["subjects"])]
        if good:
            attr_ok += 1
        else:
            wrong_subject.append((t["id"], e["subjects"], [(x["subject"], x["text"]) for x in hits]))
        best = good or hits
        want = e["status"]
        ok = want == "any" or any(x["status"] == want for x in best)
        # outsiders (not in household list) must never be active
        ok = ok and not any(x["status"] == "active" and x["subject"] not in [p["id"] for p in S["people"]] for x in best)
        if ok:
            status_ok += 1
        else:
            wrong_status.append((t["id"], want, [(x["subject"], x["status"], x["text"]) for x in best]))
R["expected_considered"] = considered
R["expected_found"] = found
R["attribution_correct"] = attr_ok
R["attribution_pct"] = round(100 * attr_ok / found, 1) if found else None
R["status_correct"] = status_ok
R["misses"] = misses
R["wrong_subject"] = wrong_subject
R["wrong_status"] = wrong_status

# 3. forbid (injection/private payloads) over rows from that turn, and canaries over ALL rows
leaks = []
for r in rows:
    t = truth.get(tid(r))
    for f in (t["forbid"] if t else []):
        if re.search(f, r["text"]):
            leaks.append((tid(r), f, r["text"]))
canary_rows = [(tid(r), r["text"]) for r in rows for c in S["canaries"] if c.lower() in r["text"].lower()]
R["forbidden_rows"] = leaks
R["canary_rows"] = canary_rows
R["canary_hits_in_requests"] = summ.get("canary_hits_in_requests")
private_turns = [t["id"] for t in S["turns"] if re.search(r"(?i)<\s*/?\s*private", t["text"])]
R["private_leak_rows"] = [x for x in leaks if x[0] in private_turns] + canary_rows

# 4. noise: rows from turns that should yield nothing
R["none_turn_rows"] = [(tid(r), r["subject"], r["status"], r["text"]) for r in rows if truth.get(tid(r), {}).get("none")]

# 5. finals over ACTIVE rows
fin = []
for f in S["finals"]:
    n = sum(1 for r in rows if r["status"] == "active" and re.search(f["re"], r["text"])
            and (r["subject"] == f["subject"] if "subject" in f else tid(r) == f["turn"]))
    ok = n >= f.get("min_active", 0) and n <= f.get("max_active", 10 ** 9)
    fin.append((f["name"], n, ok))
R["finals"] = fin
R["finals_pass"] = sum(1 for x in fin if x[2])

# 6. no hard delete: every row any turn wrote is still present
written = [x["id"] for l in turns.values() for x in l.get("applied", []) if x["action"] in ("insert", "supersede", "correct") and x.get("id")]
present = {r["id"] for r in rows}
R["rows_written"] = len(written)
R["rows_present"] = len(rows)
R["rows_missing"] = [i for i in written if i not in present]
R["status_counts"] = {s: sum(1 for r in rows if r["status"] == s) for s in ("active", "superseded", "pending_review", "retired")}
R["provenance_complete"] = all(r["src"].startswith("turn=") and r["extractor"] and r["run_id"] and r["prompt_sha"] for r in rows)

# 7. latency
def pct(xs, p):
    xs = sorted(xs)
    return round(xs[min(len(xs) - 1, int(p * (len(xs) - 1) + 0.5))], 1) if xs else None
tot = [l["total_ms"] for l in model_turns]
R["turn_ms"] = {"n": len(tot), "p50": pct(tot, .5), "p95": pct(tot, .95), "max": pct(tot, 1)}
by = {}
for l in turns.values():
    for c in l.get("calls", []):
        by.setdefault(f'{c["kind"]}@{c["engine"]}', []).append(c)
R["calls"] = {k: {"n": len(v), "valid": sum(1 for c in v if c["valid"]), "p50_ms": pct([c["ms"] for c in v], .5), "p95_ms": pct([c["ms"] for c in v], .95),
                  "completion_tokens_p50": pct([c["completion_tokens"] for c in v], .5)} for k, v in sorted(by.items())}
ext_turn_ms = [l["total_ms"] for l in model_turns if not any(c["kind"].startswith("judge") for c in l["calls"])]
R["turn_ms_without_judge"] = {"n": len(ext_turn_ms), "p50": pct(ext_turn_ms, .5), "p95": pct(ext_turn_ms, .95)}
R["summary"] = summ

if out_json:
    json.dump(R, open(out_json, "w"), indent=1, ensure_ascii=False)
short = {k: R[k] for k in ("turns_logged", "turns_errored", "turns_to_model", "valid_first_pct", "valid_final_pct", "expected_considered", "expected_found",
                           "attribution_pct", "status_correct", "finals_pass", "rows_written", "rows_present", "rows_missing", "status_counts",
                           "provenance_complete", "canary_hits_in_requests", "turn_ms", "turn_ms_without_judge")}
print(json.dumps(short, ensure_ascii=False))
print("forbidden_rows:", len(R["forbidden_rows"]), "canary_rows:", len(R["canary_rows"]), "none_turn_rows:", len(R["none_turn_rows"]))
print("calls:", json.dumps(R["calls"]))
for k in ("misses", "wrong_subject", "wrong_status", "forbidden_rows", "none_turn_rows"):
    for x in R[k]:
        print(k, json.dumps(x, ensure_ascii=False)[:300])
print("finals:", json.dumps(R["finals"]))
print("first_errors:", json.dumps(R["first_errors"], ensure_ascii=False)[:1500])
print("summary:", json.dumps(summ))
