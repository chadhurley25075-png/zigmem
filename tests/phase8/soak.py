#!/usr/bin/env python3
"""Phase-8 SOAK: the release binary serving a COPY of tonight's shadow store for --secs (default 7200) on 127.0.0.1:18192.
Workload: 1 writer (POST /v1/capture of SYNTHETIC text into scope syn-soak every --write-every s, ack = HTTP 200 + id),
1 reader (POST /v1/recall with the real bench + seat prompts in turn every --read-every s). Once, at --kill-at s, the server
gets SIGKILL and is restarted at once on the same files (what Restart=on-failure does). Samples every 30 s: RSS, threads,
fds, /health. End: every acknowledged capture present and unaltered (sqlite, read-only), PRAGMA integrity_check ok,
server stopped by PID and verified gone, nothing listening.
  python3 tests/phase8/soak.py --bin BIN --home DIR --src SRC_TREE --tag T [--secs 7200 --kill-at 3600]
LEAK gate (supervisor 10/13): a ceiling computed BEFORE the workload from the binary's real settings (receipts/phase8/
soak_<tag>.pre.json) is never exceeded; the last 60 min RSS linear-fit slope <= 1 MB/h; the restart after kill -9 stays within
the ceiling. The old cold-start ratio (late/early <= 1.10) is still reported, as information only."""
import argparse, json, os, random, signal, socket, sqlite3, statistics, subprocess, sys, threading, time, urllib.request, datetime
HOME = os.path.expanduser("~")
ZM = f"{HOME}/zigmem"
sys.path.insert(0, f"{HOME}/bench_lane")
import bench as B
ap = argparse.ArgumentParser()
ap.add_argument("--bin", required=True); ap.add_argument("--home", required=True); ap.add_argument("--tag", required=True)
ap.add_argument("--port", type=int, default=18192); ap.add_argument("--secs", type=int, default=7200); ap.add_argument("--kill-at", type=int, default=3600)
ap.add_argument("--src", required=True, help="the candidate's source tree (git archive) — settings for the ceiling are read from it")
ap.add_argument("--write-scope", default="seat:soak", help="scope the synthetic captures go to (integrated binary: the seat's own seat scope)")
ap.add_argument("--write-every", type=float, default=0.5); ap.add_argument("--read-every", type=float, default=5.0)
a = ap.parse_args()
WSCOPE = a.write_scope
URL = f"http://127.0.0.1:{a.port}"
TOK = open(f"{a.home}/soak.token").read().strip()
BIN_SHA = subprocess.run(["sha256sum", a.bin], capture_output=True, text=True).stdout.split()[0]
prompts = [q for q, *_ in B.ITEMS] + [q for q, *_ in B.BENCH91] + [q for q, *_ in B.HISTORY]
try:
    prompts += [json.loads(l)["prompt"] for l in open(f"{ZM}/scratch/p8/seat_prompts.jsonl")]
except OSError:
    pass
log = open(f"{ZM}/scratch/p8/soak_{a.tag}.log", "a")
def L(*x):
    s = time.strftime("%H:%M:%S ") + " ".join(str(y) for y in x); print(s); log.write(s + "\n"); log.flush()


def start():
    p = subprocess.Popen([a.bin, "serve", "--home", a.home, "--port", str(a.port), "--bind", "127.0.0.1", "--extract", "none"],
                         stdout=open(f"{a.home}/serve.log", "a"), stderr=subprocess.STDOUT, start_new_session=True)
    t = time.time()
    while time.time() - t < 600:   # the vector index (~395K x 768) loads before /health answers
        try:
            with urllib.request.urlopen(f"{URL}/health", timeout=2) as r:
                if r.status == 200: return p, round(time.time() - t, 2)
        except OSError:
            time.sleep(0.2)
    raise SystemExit("server did not come up")


def post(path, body, timeout=60):
    req = urllib.request.Request(URL + path, data=json.dumps(body).encode(), method="POST",
                                 headers={"Authorization": f"Bearer {TOK}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, json.loads(r.read())


def proc(pid):
    try:
        st = open(f"/proc/{pid}/status").read()
        g = lambda k: int([l for l in st.splitlines() if l.startswith(k)][0].split()[1])
        return {"rss_mb": round(g("VmRSS:") / 1024, 1), "threads": g("Threads:"), "fds": len(os.listdir(f"/proc/{pid}/fd"))}
    except (OSError, IndexError):
        return None


P, up_s = start()
L("start pid", P.pid, "up", up_s, "s", "bin", BIN_SHA[:16])


def ceiling_for(pid):
    """Configured memory ceiling from the binary's REAL settings, computed BEFORE the workload (supervisor rulings 10/13):
    page cache  = C x cache_size, C = 1 writer + readers + extraction workers (0 with --extract none), never below the db fds
                  measured on the live pid;  mmap = mmap_size ONCE (shared file pages, INTEGRATION.md section 2);
    index       = vec rows (kind atom) x (bytes per embedding + 8) — the in-RAM vector index, loaded at start;
    process     = start RSS measured after /health 200 MINUS the index (binary, heap, gate contexts), floored at 0;
    http        = 64 connections x (16 KiB head + 512 KiB body)."""
    import re as _re
    sch = open(f"{a.src}/src/store/schema.zig").read()
    cache_b = abs(int(_re.search(r"cache_size=(-?\d+)", sch).group(1))) * 1024       # negative = KiB
    mmap_b = int(_re.search(r"mmap_size=(\d+)", sch).group(1))
    hub = open(f"{a.src}/src/api/hub.zig").read()
    readers = int(_re.search(r"readers:\s*usize\s*=\s*(\d+)", hub).group(1))
    workers = 0  # this soak runs --extract none
    db = os.path.realpath(f"{a.home}/zigmem.db")
    fds = sum(1 for f in os.listdir(f"/proc/{pid}/fd") if os.path.realpath(f"/proc/{pid}/fd/{f}") == db)
    conns = max(1 + readers + workers, fds)
    with urllib.request.urlopen(f"{URL}/health", timeout=5) as r:
        retr = json.loads(r.read()).get("retriever", "")
    con = sqlite3.connect(f"file:{a.home}/zigmem.db?mode=ro", uri=True)
    n, blen = con.execute("SELECT count(*), coalesce(max(length(emb)),0) FROM vec WHERE kind='atom'").fetchone()
    con.close()
    idx = 0 if "stub" in retr else n * (blen + 8)
    start = proc(pid)["rss_mb"] * 2**20
    process = max(start - idx, 0)
    http_b = 64 * (16 * 1024 + 512 * 1024)
    total = process + idx + conns * cache_b + mmap_b + http_b
    M = lambda x: round(x / 2**20, 1)
    return {"retriever": retr, "connections": conns, "connections_math": f"1 writer + {readers} readers + {workers} workers = {1 + readers + workers}; db fds measured {fds}",
            "cache_size_mib": M(cache_b), "page_cache_mb": M(conns * cache_b), "mmap_mb": M(mmap_b),
            "index_rows": n, "index_bytes_per_row": blen + 8, "index_mb": M(idx), "start_rss_mb": M(start), "process_mb": M(process), "http_buffers_mb": M(http_b),
            "ceiling_mb": M(total),
            "math": f"process {M(process)} + index {n} x {blen + 8} B = {M(idx)} + page cache {conns} x {M(cache_b)} = {M(conns * cache_b)} + mmap {M(mmap_b)} + http {M(http_b)} = {M(total)} MB"}


time.sleep(1)
CEIL = ceiling_for(P.pid)
json.dump({"tag": a.tag, "binary_sha256": BIN_SHA, "written": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
           "ceiling": CEIL, "note": "written BEFORE the workload starts"}, open(f"{ZM}/receipts/phase8/soak_{a.tag}.pre.json", "w"), indent=1)
L("CEILING", json.dumps(CEIL))
lock = threading.Lock()
acked, errs, reads = [], {"w": 0, "r": 0}, {"ok": 0, "ms": []}
stop = threading.Event()
WORDS = ["kal", "vor", "min", "dus", "pel", "tor", "sab", "lin", "rue", "gat"]


def writer():
    n = 0
    while not stop.is_set():
        text = f"syn soak {a.tag} n{n} " + " ".join(random.choice(WORDS) for _ in range(8))
        try:
            st, b = post("/v1/capture", {"user_content": text, "session_key": f"soak{n // 100}", "scope": WSCOPE}, timeout=10)
            if st == 200 and b.get("ids"):
                with lock: acked.append((b["ids"][0], text))
        except Exception:
            errs["w"] += 1
        n += 1
        stop.wait(a.write_every)


def reader():
    i = 0
    while not stop.is_set():
        q = prompts[i % len(prompts)]; i += 1
        t = time.time()
        try:
            st, b = post("/v1/recall", {"query": q})
            if st == 200: reads["ok"] += 1; reads["ms"].append((time.time() - t) * 1000)
        except Exception:
            errs["r"] += 1
        stop.wait(a.read_every)


th = [threading.Thread(target=writer, daemon=True), threading.Thread(target=reader, daemon=True)]
[x.start() for x in th]
samples, killed, t0 = [], None, time.time()
while time.time() - t0 < a.secs:
    time.sleep(30)
    el = round(time.time() - t0)
    if killed is None and el >= a.kill_at:
        acked_before = len(acked)
        os.kill(P.pid, signal.SIGKILL); P.wait()
        gone = not os.path.exists(f"/proc/{P.pid}")
        P2, up2 = start()
        killed = {"at_s": el, "old_pid": P.pid, "old_gone": gone, "new_pid": P2.pid, "restart_s": up2, "acked_before": acked_before}
        L("KILL -9", killed); P = P2
    try:
        with urllib.request.urlopen(f"{URL}/health", timeout=5) as r: h = r.status; hj = json.loads(r.read())
    except Exception:
        h, hj = 0, {}
    s = {"t": el, "load1": float(open("/proc/loadavg").read().split()[0]), "pid": P.pid, "health": h, "rows": hj.get("rows"), **(proc(P.pid) or {"dead": True}), "acked": len(acked), "werr": errs["w"], "reads": reads["ok"], "rerr": errs["r"]}
    samples.append(s); L(json.dumps(s))
stop.set(); [x.join(timeout=70) for x in th]
# verify every acknowledged capture (read-only connection while the server still runs — WAL)
con = sqlite3.connect(f"file:{a.home}/zigmem.db?mode=ro", uri=True)
missing = sum(1 for rid, text in acked if con.execute("SELECT text, scope FROM l0 WHERE id = ?", (rid,)).fetchone() != (text, WSCOPE))
integ = con.execute("PRAGMA integrity_check").fetchone()[0]
con.close()
# stop by PID
P.send_signal(signal.SIGTERM)
try: P.wait(timeout=20)
except subprocess.TimeoutExpired: P.kill(); P.wait()
time.sleep(0.5)
s = socket.socket(); s.settimeout(0.5); listening = s.connect_ex(("127.0.0.1", a.port)) == 0; s.close()
seg = lambda lo, hi, pid: [x["rss_mb"] for x in samples if lo <= x["t"] < hi and x.get("pid") == pid and "rss_mb" in x]
k = killed["at_s"] if killed else a.secs
pid1 = samples[0]["pid"] if samples else None; pid2 = killed["new_pid"] if killed else None
def stab(lo1, hi1, lo2, hi2, pid):
    A, Bm = seg(lo1, hi1, pid), seg(lo2, hi2, pid)
    return {"early_median_mb": statistics.median(A) if A else None, "late_median_mb": statistics.median(Bm) if Bm else None,
            "ratio": round(statistics.median(Bm) / statistics.median(A), 3) if A and Bm else None}
rss = {"life1": stab(600, 1500, k - 900, k, pid1)}
if killed: rss["life2"] = stab(k + 600, k + 1500, a.secs - 900, a.secs + 60, pid2)
rss["max_mb"] = max((x.get("rss_mb", 0) for x in samples), default=None)
# old cold-start ratio: reported for comparison only (supervisor 10/13: it counts cache warm-up as growth)
rss_cold_ratio_le_110 = all(v["ratio"] is not None and v["ratio"] <= 1.10 for k_, v in rss.items() if k_.startswith("life"))
# LEAK gate (supervisor 10/13): ceiling never exceeded · last 60 min linear slope <= 1 MB/h · restart after kill -9 within ceiling
last = [(x["t"], x["rss_mb"]) for x in samples if x["t"] >= a.secs - 3600 and "rss_mb" in x]
if len(last) >= 10:
    mt = statistics.mean(t for t, _ in last); mr = statistics.mean(r for _, r in last)
    slope_mb_h = sum((t - mt) * (r - mr) for t, r in last) / sum((t - mt) ** 2 for t, _ in last) * 3600
else:
    slope_mb_h = None
after_kill = [x["rss_mb"] for x in samples if killed and x["t"] >= killed["at_s"] and "rss_mb" in x]
# the raw last-60-min series (every 30 s sample, spikes NOT filtered, no smoothing) — the "plot numbers" for the slope fit
leak_series = [[t, r_] for t, r_ in last]
last_load = [x["load1"] for x in samples if x["t"] >= a.secs - 3600 and "load1" in x]
leak = {"ceiling_mb": CEIL["ceiling_mb"], "ceiling_math": CEIL["math"], "last60_load1_min_med_max": [min(last_load), statistics.median(last_load), max(last_load)] if last_load else None,
        "last60_series_t_s_rss_mb": leak_series, "max_rss_mb": rss["max_mb"], "last60_slope_mb_per_h": None if slope_mb_h is None else round(slope_mb_h, 3),
        "last60_samples": len(last), "max_rss_after_kill_mb": max(after_kill) if after_kill else None}
g = {"zero_rows_lost": missing == 0 and len(acked) > 0, "integrity_ok": integ == "ok", "kill9_restart_ok": bool(killed and killed["old_gone"]),
     "no_crash": all(x["health"] == 200 for x in samples) and all("dead" not in x for x in samples),
     "soak_at_least_2h": a.secs >= 7200,
     "leak_rss_never_above_ceiling": rss["max_mb"] is not None and rss["max_mb"] <= CEIL["ceiling_mb"],
     "leak_last60_slope_le_1mb_h": slope_mb_h is not None and slope_mb_h <= 1.0,
     "leak_restart_within_ceiling": bool(after_kill) and max(after_kill) <= CEIL["ceiling_mb"],
     "stopped_nothing_listening": (not listening) and P.poll() is not None}
rec = {"tag": a.tag, "when": datetime.datetime.now().astimezone().isoformat(timespec="seconds"), "binary_sha256": BIN_SHA, "secs": a.secs,
       "acked": len(acked), "missing_or_altered": missing, "write_errors": errs["w"], "reads_ok": reads["ok"], "read_errors": errs["r"],
       "read_p50_ms": round(statistics.median(reads["ms"])) if reads["ms"] else None, "kill": killed, "rss": rss, "integrity": integ,
       "samples": samples, "leak": leak, "ceiling": CEIL,
       "rss_cold_start_ratio_le_110_info": rss_cold_ratio_le_110, "gate": g, "pass": all(g.values())}
json.dump(rec, open(f"{ZM}/receipts/phase8/soak_{a.tag}.json", "w"), indent=1)
L("RESULT", json.dumps({k_: v for k_, v in rec.items() if k_ != "samples"}))
