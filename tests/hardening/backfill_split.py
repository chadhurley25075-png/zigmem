"""Split the truncation cases by whether the cut lies BELOW the checkpoint backfill point. SQLite only checkpoints WAL
frames after syncing the WAL (synchronous=NORMAL syncs the WAL before every checkpoint), so on a real disk the WAL can
never lose frames that were already copied into the db file. A cut below nBackfill therefore pairs a db file that
already holds newer pages with an older WAL prefix: a state power loss cannot produce. nBackfill comes from the base's
-shm (WalCkptInfo.nBackfill at byte 96, native endian), read from the consistent (SIGSTOPped) base snapshot."""
import json, struct, sys, collections
work, recs = sys.argv[1], sys.argv[2]
info = {}
for b in range(5):
    shm = open(f"{work}/base/b{b}/zigmem.db-shm", "rb").read(136)
    wal = open(f"{work}/base/b{b}/zigmem.db-wal", "rb").read(32)
    psz = struct.unpack(">I", wal[8:12])[0]
    mx = struct.unpack("<I", shm[16:20])[0]          # WalIndexHdr.mxFrame
    nb = struct.unpack("<I", shm[96:100])[0]          # WalCkptInfo.nBackfill
    info[b] = {"page_size": psz, "mxFrame": mx, "nBackfill": nb, "backfill_end_offset": 32 + nb * (24 + psz)}
rs = [json.loads(l) for l in open(recs)]
for r in rs: r["below_backfill"] = r["offset"] < info[r["base"]]["backfill_end_offset"]
out = {"bases": info}
for k in (True, False):
    g = [r for r in rs if r["below_backfill"] == k]
    out["below_backfill" if k else "at_or_above_backfill (power-loss-possible)"] = {
        "cases": len(g), "green": sum(r["green"] for r in g), "red": [(r["base"], r["offset"], r["variant"]) for r in g if not r["green"]],
        "partial_rows": sum(r["partial"] for r in g)}
print(json.dumps(out, indent=1))
