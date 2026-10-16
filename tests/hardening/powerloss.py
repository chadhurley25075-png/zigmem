#!/usr/bin/env python3
"""zigmem hardening item 1 — POWER-LOSS simulation without root (synthetic rows only).

(a) TORN COPY: a zigmem hub on 127.0.0.1:PORT takes /v1/capture from W writer threads at full rate. At random instants a
    copier takes raw byte copies of zigmem.db, then -wal, then -shm (one file after another = NOT atomic across files).
    Every copy is then opened by (1) system SQLite (python sqlite3), (2) zigmem's own SQLite via `zigmem-storebench verify`
    (integrity_check + both FTS5 integrity-checks), (3) `zigmem serve` on a test port (/health 200, row count agrees).
    Gate per copy: opens · integrity ok · FTS ok · every row ACKED BEFORE THE COPY STARTED is present and byte-exact
    (sha256 of the full text) · ZERO partial rows: every synpl row carries h=sha256(body)[:32] and must match it.
(b) WAL TRUNCATION: base snapshots taken with the server SIGSTOPped (consistent), then the WAL is cut at random byte
    offsets (and, separately, cut + random garbage appended = a torn sector). The WAL frames are parsed here (salt +
    cumulative checksum, as SQLite does) to find the last whole valid COMMIT frame inside the cut; recovery must give
    exactly the state of the WAL cut at that commit boundary — never a half frame, never a torn row.
Usage: python3 -I powerloss.py --bin ZIGMEM --bench STOREBENCH --work DIR --out RECEIPT_DIR [--copies 200] [--port 18161]
"""
import argparse, hashlib, json, os, random, shutil, signal, sqlite3, struct, subprocess, sys, threading, time, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--bin", required=True); ap.add_argument("--bench", required=True)
ap.add_argument("--work", required=True); ap.add_argument("--out", required=True)
ap.add_argument("--copies", type=int, default=200); ap.add_argument("--trunc-bases", type=int, default=5)
ap.add_argument("--trunc-per-base", type=int, default=40); ap.add_argument("--writers", type=int, default=4)
ap.add_argument("--port", type=int, default=18161); ap.add_argument("--check-port", type=int, default=18162)
ap.add_argument("--seed", type=int, default=20261013)
a = ap.parse_args()
rng = random.Random(a.seed)
W = a.work; os.makedirs(W, exist_ok=False); os.makedirs(a.out, exist_ok=True)
HOME = f"{W}/home"; os.makedirs(HOME)
LOG = open(f"{a.out}/powerloss.log", "a")
def L(*x):
    s = time.strftime("%H:%M:%S ") + " ".join(str(y) for y in x); print(s, flush=True); LOG.write(s + "\n"); LOG.flush()

TOK = subprocess.run([a.bin, "token", "add", "--seat", "synpl", "--scopes", "syn-pl", "--writes", "--home", HOME],
                     capture_output=True, text=True, check=True).stdout.strip()
SYL = ["ka", "lo", "mi", "ner", "tu", "sa", "vel", "dor", "pi", "qua", "ren", "zo", "bri", "fen", "gal", "hum"]
def word(r): return "".join(r.choice(SYL) for _ in range(r.randint(1, 3)))
def body_for(r):
    u = r.random()
    n = r.randint(8, 40) if u < 0.85 else (r.randint(150, 300) if u < 0.97 else r.randint(1200, 2500))  # 3 % overflow-page rows
    return " ".join(word(r) for _ in range(n))
def h32(s): return hashlib.sha256(s.encode()).hexdigest()[:32]
def full(s): return hashlib.sha256(s.encode()).hexdigest()

def wait_health(port, t=30, proc=None):
    t0 = time.time()
    while time.time() - t0 < t:
        if proc is not None and proc.poll() is not None: return None
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as r:
                if r.status == 200: return json.loads(r.read())
        except OSError:
            time.sleep(0.1)
    return None

def stop(p):
    if p.poll() is None:
        p.send_signal(signal.SIGTERM)
        try: p.wait(15)
        except subprocess.TimeoutExpired: p.kill(); p.wait()
    return not os.path.exists(f"/proc/{p.pid}")

def listening(port):
    return f":{port} " in subprocess.run(["ss", "-ltnH"], capture_output=True, text=True).stdout

srv = subprocess.Popen([a.bin, "serve", "--home", HOME, "--port", str(a.port), "--bind", "127.0.0.1", "--extract", "none"],
                       stdout=open(f"{W}/serve.log", "w"), stderr=subprocess.STDOUT, start_new_session=True)
assert wait_health(a.port), "hub did not come up"
L("hub pid", srv.pid, "port", a.port)

lock = threading.Lock()
acked = []            # (t_ack_monotonic, id, sha256(full text))
errs = [0]; stop_ev = threading.Event()
def writer(tid):
    r = random.Random(a.seed * 31 + tid); n = 0
    while not stop_ev.is_set():
        b = body_for(r)
        text = f"synpl t{tid} n{n} h={h32(b)} | {b}"
        req = urllib.request.Request(f"http://127.0.0.1:{a.port}/v1/capture", method="POST",
                                     data=json.dumps({"user_content": text, "session_key": f"pl{tid}-{n // 500}", "scope": "syn-pl"}).encode(),
                                     headers={"Authorization": f"Bearer {TOK}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                j = json.loads(resp.read())
            if resp.status == 200 and j.get("ids"):
                t = time.monotonic()
                with lock: acked.append((t, j["ids"][0], full(text)))
            else: errs[0] += 1
        except Exception:
            errs[0] += 1
        n += 1
ths = [threading.Thread(target=writer, args=(i,), daemon=True) for i in range(a.writers)]
[t.start() for t in ths]
time.sleep(3)

DB = f"{HOME}/zigmem.db"; FILES = ["zigmem.db", "zigmem.db-wal", "zigmem.db-shm"]
def hdr(path):
    try:
        with open(path, "rb") as f: return f.read(32).hex()
    except OSError: return None

# ---------------- (a) torn copies, taken while writing ----------------
copies = []
# variant "plain": cp db, wal, shm in turn — exactly as specified.
# variant "pinned": the same, but a separate read transaction (system SQLite) is held open on the live DB during the copy,
#   so a checkpoint may still write (tear) db pages while cp reads them, but the WAL cannot restart under the copy. That is
#   the disk shape real power loss can leave with synchronous=NORMAL (db pages torn, WAL frames that cover them intact).
for i in range(2 * a.copies):
    variant = "plain" if i < a.copies else "pinned"
    time.sleep(rng.uniform(0.0, 0.25))
    pin = None
    if variant == "pinned":
        pin = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, isolation_level=None)
        pin.execute("BEGIN"); pin.execute("SELECT count(*) FROM meta").fetchone()
    t0 = time.monotonic()
    with lock: durable = {i_: s for (t, i_, s) in acked if t < t0}
    d = f"{W}/torn/c{i:03d}"; os.makedirs(d)
    wal_hdr_before = hdr(f"{HOME}/zigmem.db-wal")
    for f in FILES:                                   # one file after another: not atomic across files
        try: shutil.copyfile(f"{HOME}/{f}", f"{d}/{f}")
        except FileNotFoundError: pass
    shutil.copyfile(f"{HOME}/tokens", f"{d}/tokens"); os.chmod(f"{d}/tokens", 0o600)
    took = time.monotonic() - t0
    if pin is not None: pin.execute("COMMIT"); pin.close()
    json.dump(durable, open(f"{d}/durable.json", "w"))
    copies.append({"i": i, "variant": variant, "dir": d, "durable": len(durable), "copy_s": round(took, 4),
                   "sizes": {f: os.path.getsize(f"{d}/{f}") if os.path.exists(f"{d}/{f}") else None for f in FILES},
                   "wal_hdr_changed_during_copy": wal_hdr_before != hdr(f"{d}/zigmem.db-wal")})
L("torn copies taken", len(copies), "acked so far", len(acked), "write errors", errs[0])

# ---------------- (b) consistent base snapshots for the truncation test (server SIGSTOPped) ----------------
bases = []
for k in range(a.trunc_bases):
    t1 = time.time()
    while os.path.getsize(f"{HOME}/zigmem.db-wal") < 1_500_000 and time.time() - t1 < 20: time.sleep(0.05)
    time.sleep(rng.uniform(0, 0.3))
    os.kill(srv.pid, signal.SIGSTOP)
    try:
        d = f"{W}/base/b{k}"; os.makedirs(d)
        for f in FILES: shutil.copyfile(f"{HOME}/{f}", f"{d}/{f}")
        shutil.copyfile(f"{HOME}/tokens", f"{d}/tokens"); os.chmod(f"{d}/tokens", 0o600)
    finally:
        os.kill(srv.pid, signal.SIGCONT)
    bases.append(d)
stop_ev.set(); [t.join(35) for t in ths]
total_acked = len(acked)
gone = stop(srv)
L("writers stopped; acked", total_acked, "errors", errs[0], "hub stopped", gone, "still listening", listening(a.port))

# ---------------- checkers ----------------
def dup(src, dst, wal_override=None, shm=True):
    os.makedirs(dst)
    shutil.copyfile(f"{src}/zigmem.db", f"{dst}/zigmem.db")
    if wal_override is not None:
        open(f"{dst}/zigmem.db-wal", "wb").write(wal_override)
    elif os.path.exists(f"{src}/zigmem.db-wal"):
        shutil.copyfile(f"{src}/zigmem.db-wal", f"{dst}/zigmem.db-wal")
    if shm and os.path.exists(f"{src}/zigmem.db-shm"): shutil.copyfile(f"{src}/zigmem.db-shm", f"{dst}/zigmem.db-shm")
    shutil.copyfile(f"{src}/tokens", f"{dst}/tokens"); os.chmod(f"{dst}/tokens", 0o600)   # zigmem refuses an open token file

def py_check(d):
    """System SQLite: integrity, FTS, row map id->sha256(text), partial rows."""
    r = {"py_open": False}
    try:
        con = sqlite3.connect(f"{d}/zigmem.db")
        r["py_open"] = True
        r["py_integrity"] = con.execute("PRAGMA integrity_check").fetchone()[0]
        try:
            con.execute("INSERT INTO l0_fts(l0_fts, rank) VALUES ('integrity-check', 1)")
            con.execute("INSERT INTO atoms_fts(atoms_fts, rank) VALUES ('integrity-check', 1)"); r["py_fts"] = "ok"
        except sqlite3.DatabaseError as e: r["py_fts"] = str(e)
        rows = {}; partial = []
        for i_, text in con.execute("SELECT id, text FROM l0"):
            if not isinstance(text, str): partial.append(i_); rows[i_] = None; continue
            rows[i_] = full(text)
            if text.startswith("synpl "):
                try:
                    hh, b = text.split(" h=", 1)[1].split(" | ", 1)
                    if h32(b) != hh: partial.append(i_)
                except (IndexError, ValueError): partial.append(i_)
        con.close()
        r["rows"] = len(rows); r["partial"] = partial
        return r, rows
    except Exception as e:                          # a malformed copy can fail anywhere: record it, never crash
        r["py_error"] = f"{type(e).__name__}: {e}"; return r, None

def zig_check(d):
    empty = f"{d}/.empty"; open(empty, "w").close()
    v = subprocess.run([a.bench, "verify", f"{d}/zigmem.db", "0", empty], capture_output=True, text=True, timeout=300)
    try: j = json.loads(v.stdout.strip().splitlines()[-1])
    except (IndexError, ValueError): j = {"error": (v.stderr or v.stdout)[-300:]}
    return {"zig_rc": v.returncode, "zig_integrity": j.get("integrity"), "zig_l0": j.get("l0_total"), "zig_err": j.get("error")}

def serve_check(d):
    p = subprocess.Popen([a.bin, "serve", "--home", d, "--port", str(a.check_port), "--bind", "127.0.0.1", "--extract", "none"],
                         stdout=open(f"{d}/serve.log", "w"), stderr=subprocess.STDOUT, start_new_session=True)
    h = wait_health(a.check_port, 30, p)
    gone_ = stop(p)
    return {"serve_health": bool(h and h.get("ok")), "serve_l0": (h or {}).get("rows", {}).get("l0"),
            "serve_stopped": gone_ and not listening(a.check_port)}

# ---------------- verify (a) ----------------
red_a = []; res_a = []
for c in copies:
    d = c["dir"]; durable = json.load(open(f"{d}/durable.json"))
    dup(d, f"{d}/py"); pr, rows = py_check(f"{d}/py")
    dup(d, f"{d}/zg"); zr = zig_check(f"{d}/zg"); sr = serve_check(f"{d}/zg")
    miss = alt = None
    if rows is not None:
        miss = sum(1 for k in durable if int(k) not in rows)
        alt = sum(1 for k, s in durable.items() if int(k) in rows and rows[int(k)] != s)
    rec = {**{k: v for k, v in c.items() if k != "dir"}, **pr, **zr, **sr, "durable_missing": miss, "durable_altered": alt}
    ok = (pr["py_open"] and pr.get("py_integrity") == "ok" and pr.get("py_fts") == "ok" and not pr.get("partial")
          and zr["zig_rc"] == 0 and zr["zig_integrity"] is True and sr["serve_health"] and sr["serve_stopped"]
          and sr["serve_l0"] == pr.get("rows") and miss == 0 and alt == 0)
    rec["green"] = bool(ok); rec["partial"] = len(pr.get("partial") or []) if pr.get("partial") is not None else None
    res_a.append(rec)
    if ok: shutil.rmtree(d)                       # keep only failing copies (own scratch)
    else: red_a.append(c["i"]); L("RED torn copy", c["i"], json.dumps(rec)[:600])
with open(f"{a.out}/torn_copies.jsonl", "w") as f:
    for r_ in res_a: f.write(json.dumps(r_) + "\n")
def subsum(rs):
    return {"copies": len(rs), "green": sum(r_["green"] for r_ in rs),
            "integrity_bad": sum(1 for r_ in rs if r_.get("py_integrity") != "ok" or r_.get("zig_integrity") is not True),
            "durable_missing_total": sum((r_["durable_missing"] or 0) for r_ in rs),
            "partial_rows_total": sum((r_["partial"] or 0) for r_ in rs)}
by_variant = {}
for v in ("plain", "pinned"):
    rv = [r_ for r_ in res_a if r_["variant"] == v]
    by_variant[v] = {"all": subsum(rv), "wal_restarted_during_copy": subsum([r_ for r_ in rv if r_["wal_hdr_changed_during_copy"]]),
                     "wal_not_restarted": subsum([r_ for r_ in rv if not r_["wal_hdr_changed_during_copy"]])}
sum_a = {"by_variant": by_variant, "copies": len(res_a), "green": sum(r_["green"] for r_ in res_a), "red_ids": red_a,
         "durable_rows_checked_total": sum(r_["durable"] for r_ in res_a),
         "durable_missing_total": sum((r_["durable_missing"] or 0) for r_ in res_a),
         "durable_altered_total": sum((r_["durable_altered"] or 0) for r_ in res_a),
         "partial_rows_total": sum((r_["partial"] or 0) for r_ in res_a),
         "copies_with_wal_reset_during_copy": sum(r_["wal_hdr_changed_during_copy"] for r_ in res_a),
         "max_db_mb": round(max(r_["sizes"]["zigmem.db"] for r_ in res_a) / 2**20, 1),
         "acked_total": total_acked, "write_errors": errs[0]}
L("SUMMARY (a)", json.dumps(sum_a))

# ---------------- (b) truncation ----------------
def wal_commits(wal):
    """Parse a WAL like SQLite's recovery: header magic/page size/salts/checksum, then frames while salt matches and the
    cumulative checksum holds. Returns (frame_size, [end offset of every valid COMMIT frame])."""
    if len(wal) < 32: return None, []
    magic, ver, psz, ckpt, s1, s2, c1, c2 = struct.unpack(">IIIIIIII", wal[:32])
    if magic not in (0x377F0682, 0x377F0683): return None, []
    big = magic & 1
    def cks(data, a1, a2):
        fmt = (">" if big else "<") + f"{len(data) // 4}I"
        xs = struct.unpack(fmt, data)
        for j in range(0, len(xs), 2):
            a1 = (a1 + xs[j] + a2) & 0xFFFFFFFF; a2 = (a2 + xs[j + 1] + a1) & 0xFFFFFFFF
        return a1, a2
    a1, a2 = cks(wal[:24], 0, 0)
    if (a1, a2) != (c1, c2): return None, []
    fs = 24 + psz; off = 32; commits = []
    while off + fs <= len(wal):
        fh = wal[off:off + 24]; pg, dbsz, fs1, fs2, fc1, fc2 = struct.unpack(">IIIIII", fh)
        if (fs1, fs2) != (s1, s2) or pg == 0: break
        a1, a2 = cks(fh[:8], a1, a2); a1, a2 = cks(wal[off + 24:off + fs], a1, a2)
        if (a1, a2) != (fc1, fc2): break
        off += fs
        if dbsz: commits.append(off)
    return fs, commits

res_b = []; red_b = []; ref_cache = {}
for bi, bdir in enumerate(bases):
    wal = open(f"{bdir}/zigmem.db-wal", "rb").read()
    fs, commits = wal_commits(wal)
    L("base", bi, "wal bytes", len(wal), "frame", fs, "valid commits", len(commits))
    offs = {0, 1, 31, 32, 33, len(wal) - 1, len(wal)}
    for c_end in rng.sample(commits, min(4, len(commits))): offs |= {c_end - 1, c_end, c_end + 1}
    while len(offs) < a.trunc_per_base: offs.add(rng.randint(0, len(wal)))
    for oi, o in enumerate(sorted(offs)):
        for variant in ("cut", "cut+garbage"):
            if variant == "cut+garbage" and oi % 2: continue          # garbage tail on half the offsets
            boundary = max([c for c in commits if c <= o], default=0)
            data = wal[:o] + (os.urandom(rng.randint(1, 2 * (fs or 4096))) if variant == "cut+garbage" else b"")
            d = f"{W}/trunc/b{bi}_o{o}_{variant.replace('+', '_')}"
            dup(bdir, d, wal_override=data, shm=(oi % 3 == 0))   # a stale -shm on a third of the cases
            pr, rows = py_check(d)
            zr = zig_check(d)
            if (bi, boundary) not in ref_cache:
                rd = f"{W}/trunc/ref_b{bi}_{boundary}"; dup(bdir, rd, wal_override=wal[:boundary], shm=False)
                ref_cache[(bi, boundary)] = py_check(rd)[1]; shutil.rmtree(rd)
            ref = ref_cache[(bi, boundary)]
            same = rows is not None and ref is not None and rows == ref
            ok = (pr["py_open"] and pr.get("py_integrity") == "ok" and pr.get("py_fts") == "ok" and not pr.get("partial")
                  and zr["zig_rc"] == 0 and zr["zig_integrity"] is True and same and zr["zig_l0"] == pr.get("rows"))
            rec = {"base": bi, "offset": o, "variant": variant, "boundary": boundary, "frames_dropped_bytes": o - boundary,
                   "rows": pr.get("rows"), "ref_rows": len(ref) if ref else None, "state_equals_commit_boundary": same,
                   "partial": len(pr.get("partial") or []), **{k: v for k, v in pr.items() if k != "partial"}, **zr, "green": bool(ok)}
            res_b.append(rec)
            if ok: shutil.rmtree(d)
            else: red_b.append(d); L("RED truncation", json.dumps(rec)[:600])
# zigmem serve opens a sample of truncated cases too
sample = [r_ for r_ in res_b if r_["green"]][:: max(1, len(res_b) // 10)][:10]
srv_ok = 0
for r_ in sample:
    bdir = bases[r_["base"]]; wal = open(f"{bdir}/zigmem.db-wal", "rb").read()
    d = f"{W}/trunc/serve_b{r_['base']}_o{r_['offset']}"; dup(bdir, d, wal_override=wal[:r_["offset"]])
    sr = serve_check(d); r_["serve"] = sr
    srv_ok += sr["serve_health"] and sr["serve_stopped"] and sr["serve_l0"] == r_["rows"]
    shutil.rmtree(d)
with open(f"{a.out}/truncation.jsonl", "w") as f:
    for r_ in res_b: f.write(json.dumps(r_) + "\n")
sum_b = {"cases": len(res_b), "green": sum(r_["green"] for r_ in res_b), "red_dirs": red_b,
         "cut": sum(r_["variant"] == "cut" for r_ in res_b), "cut_garbage": sum(r_["variant"] == "cut+garbage" for r_ in res_b),
         "partial_rows_total": sum(r_["partial"] for r_ in res_b),
         "cases_that_dropped_a_torn_tail": sum(r_["frames_dropped_bytes"] > 0 for r_ in res_b),
         "serve_sample": len(sample), "serve_sample_ok": srv_ok}
L("SUMMARY (b)", json.dumps(sum_b))
json.dump({"a": sum_a, "b": sum_b, "bin_sha256": hashlib.sha256(open(a.bin, "rb").read()).hexdigest(),
           "bench_sha256": hashlib.sha256(open(a.bench, "rb").read()).hexdigest(), "sqlite_py": sqlite3.sqlite_version},
          open(f"{a.out}/powerloss_summary.json", "w"), indent=1)
green = sum_a["green"] == sum_a["copies"] and sum_b["green"] == sum_b["cases"] and srv_ok == len(sample)
L("VERDICT", "GREEN" if green else "RED")
sys.exit(0 if green else 1)
