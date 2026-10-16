#!/usr/bin/env python3
"""Collect >= 200 REAL recent seat prompts from Claude Code transcripts on the dev box (~/.claude/projects/<proj>/<session>.jsonl,
main sessions only, newest first), privacy-filtered: reference_filters.strip_private (fail-closed: a line still tagged
is dropped), is_machine_traffic (hooks/notifications/tool chatter), command/system tags, isMeta/sidechain rows, dedup.
Writes scratch/p8/seat_prompts.jsonl (0600, the dev box only). Prints COUNTS only — never prompt text.
  python3 tests/phase8/seat_prompts.py [--days 7] [--n 300]"""
import argparse, glob, json, os, re, sys
HOME = os.path.expanduser("~")
sys.path.insert(0, HOME)
import reference_filters as F

ap = argparse.ArgumentParser()
ap.add_argument("--days", type=float, default=7)
ap.add_argument("--n", type=int, default=300)
ap.add_argument("--out", default=f"{HOME}/zigmem/scratch/p8/seat_prompts.jsonl")
a = ap.parse_args()
import time
cut = time.time() - a.days * 86400
files = [f for f in glob.glob(f"{HOME}/.claude/projects/*/*.jsonl") if os.path.getmtime(f) >= cut]
files.sort(key=os.path.getmtime, reverse=True)
C = {"files": len(files), "user_rows": 0, "not_text": 0, "tagged": 0, "machine": 0, "private_dropped": 0, "len": 0, "dup": 0, "kept": 0, "zigmem_scratch_projects": 0}
seen, out = set(), []
TAG = re.compile(r"^\s*<(command-|local-command|task-notification|system-reminder|bash-|user-memory|tool_use|antml)", re.I)
for f in files:
    if "zigmem-scratch" in f:
        C["zigmem_scratch_projects"] += 1
        continue
    rows = []
    try:
        for line in open(f, errors="replace"):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("type") != "user" or r.get("isMeta") or r.get("isSidechain"):
                continue
            m = r.get("message") or {}
            c = m.get("content")
            C["user_rows"] += 1
            if isinstance(c, list):
                c = "\n".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
            if not isinstance(c, str) or not c.strip():
                C["not_text"] += 1
                continue
            rows.append((r.get("timestamp", ""), c))
    except OSError:
        continue
    for ts, c in reversed(rows):
        if TAG.match(c):
            C["tagged"] += 1; continue
        try:
            t = F.strip_private(c)
        except Exception:
            C["private_dropped"] += 1; continue
        if t is None or "<private" in t.lower() or "rivate>" in t.lower():
            C["private_dropped"] += 1; continue
        try:
            if F.is_machine_traffic(t):
                C["machine"] += 1; continue
        except Exception:
            C["machine"] += 1; continue
        t = t.strip()
        if not (15 <= len(t) <= 1500):
            C["len"] += 1; continue
        k = re.sub(r"\W+", " ", t.lower()).strip()[:300]
        if k in seen:
            C["dup"] += 1; continue
        seen.add(k)
        out.append({"ts": ts, "prompt": t})
    if len(out) >= a.n * 3:
        break
out.sort(key=lambda x: x["ts"], reverse=True)
out = out[: a.n]
C["kept"] = len(out)
fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as w:
    for o in out:
        w.write(json.dumps(o, ensure_ascii=False) + "\n")
C["newest"] = out[0]["ts"][:16] if out else None
C["oldest"] = out[-1]["ts"][:16] if out else None
print(json.dumps(C))
