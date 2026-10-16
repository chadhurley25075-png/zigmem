"""Gate (a): kill -9 a child mid-write 20 times on ONE database; after each kill, verify integrity and that every
commit the child reported (it prints "C <seq>" only after its commit returned) is present byte-exact.
Synthetic rows only. Usage: python3 -I crash_harness.py BENCH_BIN DB_PATH OUT_DIR [rounds] [rows]"""
import json, os, random, signal, sqlite3, subprocess, sys

bench, db, out = sys.argv[1], sys.argv[2], sys.argv[3]
rounds = int(sys.argv[4]) if len(sys.argv) > 4 else 20
rows = int(sys.argv[5]) if len(sys.argv) > 5 else 10000
rng = random.Random(20261012)
results = []
for r in range(1, rounds + 1):
    target = rng.randint(50, rows - 500)
    p = subprocess.Popen([bench, "crashwrite", db, str(r), str(rows)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    committed, killed_at = [], None
    for raw in p.stdout:
        line = raw.decode().rstrip("\n")
        if line.startswith("C "):
            committed.append(line)
            if killed_at is None and len(committed) >= target:
                os.kill(p.pid, signal.SIGKILL)
                killed_at = len(committed)
        elif line == "DONE":
            break
    rc = p.wait()
    cf = os.path.join(out, f"round{r:02d}_committed.txt")
    open(cf, "w").write("\n".join(committed) + "\n")
    v = subprocess.run([bench, "verify", db, str(r), cf], capture_output=True, text=True)
    res = json.loads(v.stdout.strip().splitlines()[-1]) if v.stdout.strip() else {"error": v.stderr[-500:]}
    res.update({"kill_target": target, "killed_after_lines": killed_at, "child_rc": rc, "verify_rc": v.returncode,
                "rows_beyond_printed": res.get("rows_in_db_this_round", 0) - res.get("printed_commits", 0)})
    results.append(res)
    print(json.dumps(res), flush=True)
# cross-check with a different SQLite build (system Python, 3.45.x)
con = sqlite3.connect(db)
ic = con.execute("PRAGMA integrity_check").fetchone()[0]
con.execute("INSERT INTO atoms_fts(atoms_fts) VALUES (?)", ("integrity-check",))
con.execute("INSERT INTO l0_fts(l0_fts) VALUES (?)", ("integrity-check",))
summary = {"rounds": rounds, "killed_mid_write": sum(1 for x in results if x["child_rc"] == -9 and x["killed_after_lines"]),
           "integrity_ok": sum(1 for x in results if x.get("integrity") is True), "missing_total": sum(x.get("missing", 1) for x in results),
           "mismatch_total": sum(x.get("text_mismatch", 1) for x in results), "python_sqlite": sqlite3.sqlite_version,
           "python_integrity_check": ic, "python_fts_integrity": "ok",
           "atoms_total": con.execute("select count(*) from atoms").fetchone()[0], "l0_total": con.execute("select count(*) from l0").fetchone()[0]}
print(json.dumps(summary))
sys.exit(0 if summary["integrity_ok"] == rounds and summary["missing_total"] == 0 and summary["mismatch_total"] == 0 and ic == "ok" else 1)
