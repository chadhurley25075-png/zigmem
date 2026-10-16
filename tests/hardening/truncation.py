#!/usr/bin/env python3
"""zigmem hardening item 1(b), standalone re-run over the base snapshots powerloss.py took (server SIGSTOPped).
Fixes run 3's reference-cache bug (it was keyed by boundary only, so base N was compared with base 0's state).

For each base: parse the WAL like SQLite's recovery (salt + cumulative checksum) → valid frames and commit frames.
CHECKPOINT FLOOR: a page P whose db-file copy already equals P's latest WAL version has been checkpointed. A cut that
drops EVERY frame of such a page leaves the db file holding a page newer than the cut — a state real power loss cannot
leave, because SQLite syncs the WAL before it checkpoints a single page (synchronous=NORMAL). floor = max over checkpointed
pages of the index of their FIRST frame. Cuts whose last kept commit frame is >= floor are "power-loss-possible".
Gate (on power-loss-possible cuts): opens (system SQLite + zigmem storebench), integrity + FTS ok, 0 partial rows, and the
recovered rows are EXACTLY the rows of the same base cut at its last whole commit frame. Cuts below the floor are run
and reported too, as information.
Usage: python3 -I truncation.py --bench STOREBENCH --bases DIR --out DIR [--per-base 60] [--seed N]"""
import argparse, hashlib, json, os, random, shutil, sqlite3, struct, subprocess, sys
ap = argparse.ArgumentParser()
ap.add_argument("--bench", required=True); ap.add_argument("--bases", required=True); ap.add_argument("--out", required=True)
ap.add_argument("--per-base", type=int, default=60); ap.add_argument("--seed", type=int, default=20261014)
a = ap.parse_args(); rng = random.Random(a.seed)
SCR = f"{a.bases}/../trunc2"; os.makedirs(SCR, exist_ok=False); os.makedirs(a.out, exist_ok=True)
def h32(s): return hashlib.sha256(s.encode()).hexdigest()[:32]

def frames(wal):
    """[(end_offset, page_no, is_commit, data)] for every VALID frame, and the page size."""
    if len(wal) < 32: return [], None
    magic, ver, psz, ckpt, s1, s2, c1, c2 = struct.unpack(">IIIIIIII", wal[:32])
    if magic not in (0x377F0682, 0x377F0683): return [], None
    big = magic & 1
    def cks(data, x, y):
        xs = struct.unpack((">" if big else "<") + f"{len(data) // 4}I", data)
        for j in range(0, len(xs), 2):
            x = (x + xs[j] + y) & 0xFFFFFFFF; y = (y + xs[j + 1] + x) & 0xFFFFFFFF
        return x, y
    x, y = cks(wal[:24], 0, 0)
    if (x, y) != (c1, c2): return [], psz
    fs = 24 + psz; off = 32; out = []
    while off + fs <= len(wal):
        pg, dbsz, f1, f2, k1, k2 = struct.unpack(">IIIIII", wal[off:off + 24])
        if (f1, f2) != (s1, s2) or pg == 0: break
        x, y = cks(wal[off:off + 8], x, y); x, y = cks(wal[off + 24:off + fs], x, y)
        if (x, y) != (k1, k2): break
        out.append((off + fs, pg, dbsz != 0, wal[off + 24:off + fs])); off += fs
    return out, psz

def dup(src, dst, wal):
    os.makedirs(dst); shutil.copyfile(f"{src}/zigmem.db", f"{dst}/zigmem.db")
    open(f"{dst}/zigmem.db-wal", "wb").write(wal)

def state(d):
    r = {"open": False}
    try:
        con = sqlite3.connect(f"{d}/zigmem.db"); r["open"] = True
        r["integrity"] = con.execute("PRAGMA integrity_check").fetchone()[0][:200]
        try:
            con.execute("INSERT INTO l0_fts(l0_fts, rank) VALUES ('integrity-check', 1)")
            con.execute("INSERT INTO atoms_fts(atoms_fts, rank) VALUES ('integrity-check', 1)"); r["fts"] = "ok"
        except sqlite3.DatabaseError as e: r["fts"] = str(e)[:120]
        rows, partial = {}, 0
        for i_, t in con.execute("SELECT id, text FROM l0"):
            if not isinstance(t, str): partial += 1; continue
            rows[i_] = hashlib.sha256(t.encode()).hexdigest()
            if t.startswith("synpl "):
                try:
                    hh, b = t.split(" h=", 1)[1].split(" | ", 1)
                    partial += h32(b) != hh
                except ValueError: partial += 1
        con.close(); r["rows"] = len(rows); r["partial"] = partial
        return r, rows
    except Exception as e:
        r["error"] = f"{type(e).__name__}: {e}"[:200]; return r, None

def zig(d):
    e = f"{d}/.empty"; open(e, "w").close()
    v = subprocess.run([a.bench, "verify", f"{d}/zigmem.db", "0", e], capture_output=True, text=True, timeout=600)
    try: j = json.loads(v.stdout.strip().splitlines()[-1])
    except (IndexError, ValueError): j = {}
    return {"zig_rc": v.returncode, "zig_integrity": j.get("integrity"), "zig_l0": j.get("l0_total")}

res, bases_info = [], {}
for b in sorted(os.listdir(a.bases)):
    bdir = f"{a.bases}/{b}"; wal = open(f"{bdir}/zigmem.db-wal", "rb").read(); db = open(f"{bdir}/zigmem.db", "rb")
    fr, psz = frames(wal); fs = 24 + psz
    first, last = {}, {}
    for i, (end, pg, com, data) in enumerate(fr):
        first.setdefault(pg, i + 1); last[pg] = (i + 1, data)
    ck = []
    for pg, (li, data) in last.items():
        db.seek((pg - 1) * psz); cur = db.read(psz)
        if cur == data: ck.append(pg)
    floor_frame = max((first[p] for p in ck), default=0)
    commits = [(i + 1, end) for i, (end, pg, com, data) in enumerate(fr) if com]
    bases_info[b] = {"valid_frames": len(fr), "commits": len(commits), "pages_in_wal": len(last), "pages_already_checkpointed": len(ck),
                     "floor_frame": floor_frame, "floor_offset": 32 + floor_frame * fs}
    offs = {0, 31, 32, 33, len(wal)}
    for ci, ce in rng.sample(commits, min(6, len(commits))): offs |= {ce - 1, ce, ce + 1}
    fl = 32 + floor_frame * fs; offs |= {fl - 1, fl, fl + 1}
    while len(offs) < a.per_base: offs.add(rng.randint(0, len(wal)))
    refs = {}
    for oi, o in enumerate(sorted(offs)):
        for variant in ("cut", "cut+garbage"):
            if variant == "cut+garbage" and oi % 2: continue
            kept = [(i, e) for i, e in commits if e <= o]
            bframe, boff = kept[-1] if kept else (0, 0)
            data = wal[:o] + (os.urandom(rng.randint(1, 2 * fs)) if variant == "cut+garbage" else b"")
            d = f"{SCR}/{b}_o{o}_{variant.replace('+', '_')}"; dup(bdir, d, data)
            s, rows = state(d); z = zig(d)
            if boff not in refs:
                rd = f"{SCR}/ref_{b}_{boff}"; dup(bdir, rd, wal[:boff]); rs_, rr = state(rd); refs[boff] = (rs_, rr); shutil.rmtree(rd)
            ref_s, ref_rows = refs[boff]
            possible = bframe >= floor_frame
            same = rows is not None and ref_rows is not None and rows == ref_rows
            ok = (s.get("integrity") == "ok" and s.get("fts") == "ok" and s.get("partial") == 0 and z["zig_rc"] == 0
                  and z["zig_integrity"] is True and same and z["zig_l0"] == s.get("rows"))
            rec = {"base": b, "offset": o, "variant": variant, "kept_commit_frame": bframe, "floor_frame": floor_frame,
                   "power_loss_possible": possible, "state_equals_commit_boundary": same, **s, **z, "green": bool(ok)}
            res.append(rec)
            if ok: shutil.rmtree(d)
with open(f"{a.out}/truncation_v2.jsonl", "w") as f:
    for r in res: f.write(json.dumps(r) + "\n")
def summ(rs):
    return {"cases": len(rs), "green": sum(r["green"] for r in rs), "partial_rows": sum(r.get("partial") or 0 for r in rs),
            "integrity_bad": sum(1 for r in rs if r.get("integrity") != "ok"),
            "red": [(r["base"], r["offset"], r["variant"], r.get("integrity", r.get("error", ""))[:60]) for r in rs if not r["green"]][:40]}
S = {"bases": bases_info, "power_loss_possible": summ([r for r in res if r["power_loss_possible"]]),
     "below_checkpoint_floor (not a power-loss state)": summ([r for r in res if not r["power_loss_possible"]])}
json.dump(S, open(f"{a.out}/truncation_v2_summary.json", "w"), indent=1)
print(json.dumps(S, indent=1))
p = S["power_loss_possible"]
print("VERDICT (b)", "GREEN" if p["green"] == p["cases"] else "RED")
