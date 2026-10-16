#!/usr/bin/python3 -I
"""Merge lane diagnostic: independent check of the SOAK store (scratch copy of the shadow import) at a moment the hub's
periodic quick_check says FTS5 corruption. Read-only on the live file; FTS5 'integrity-check' runs on a .backup copy
(scratch/merge/run/soakcheck_<n>.db). Prints only check results, never row text."""
import json, os, sqlite3, sys, time, urllib.request, urllib.error
db = os.path.expanduser("~/zigmem/scratch/p8/soak-d70b91aa41fc/zigmem.db"); n = sys.argv[1]
out = {"when": time.strftime("%T")}
try:
    urllib.request.urlopen("http://127.0.0.1:18232/health", timeout=10)
except urllib.error.HTTPError as e:
    out["hub_health"] = [e.code, json.loads(e.read())["db"]["quick_check"]]
c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
t = time.time(); out["sys_quick_check_live"] = c.execute("PRAGMA quick_check(5)").fetchall(); out["sys_qc_s"] = round(time.time() - t, 2)
out["sqlite_version_py"] = sqlite3.sqlite_version
bk = os.path.expanduser(f"~/zigmem/scratch/merge/run/soakcheck_{n}.db"); assert not os.path.exists(bk)
b = sqlite3.connect(bk); c.backup(b); c.close()
for tbl in ("l0_fts", "atoms_fts"):
    try:
        b.execute(f"INSERT INTO {tbl}({tbl}) VALUES('integrity-check')"); out[f"backup_{tbl}_integrity"] = "ok"
    except Exception as e: out[f"backup_{tbl}_integrity"] = str(e)
out["backup_integrity_check"] = b.execute("PRAGMA integrity_check(5)").fetchall(); b.close()
print(json.dumps(out))
json.dump(out, open(os.path.expanduser(f"~/zigmem/receipts/merge/soak_store_check_{n}.json"), "w"), indent=1)
