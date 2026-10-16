"""For each consistent base: integrity of (db file alone) and (db + its full WAL), plus the db file's change counter vs the
WAL header checkpoint sequence — tells whether the db file already holds pages from the current WAL generation."""
import os, shutil, sqlite3, struct, sys, json
work = sys.argv[1]; tmp = f"{work}/probe"; os.makedirs(tmp, exist_ok=True)
for b in range(5):
    src = f"{work}/base/b{b}"
    res = {"base": b, "db_bytes": os.path.getsize(f"{src}/zigmem.db"), "wal_bytes": os.path.getsize(f"{src}/zigmem.db-wal")}
    wal = open(f"{src}/zigmem.db-wal", "rb").read(32); res["wal_ckpt_seq"] = struct.unpack(">I", wal[12:16])[0]
    for name, use_wal in (("db_only", False), ("db_plus_wal", True)):
        d = f"{tmp}/b{b}_{name}"; os.makedirs(d)
        shutil.copyfile(f"{src}/zigmem.db", f"{d}/zigmem.db")
        if use_wal: shutil.copyfile(f"{src}/zigmem.db-wal", f"{d}/zigmem.db-wal")
        try:
            con = sqlite3.connect(f"{d}/zigmem.db"); res[name] = [con.execute("PRAGMA integrity_check").fetchone()[0][:120],
                                                                 con.execute("SELECT count(*) FROM l0").fetchone()[0]]; con.close()
        except Exception as e: res[name] = f"{type(e).__name__}: {e}"
        shutil.rmtree(d)
    print(json.dumps(res))
os.rmdir(tmp)
