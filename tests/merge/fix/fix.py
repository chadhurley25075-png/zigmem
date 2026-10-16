#!/usr/bin/python3 -I
import sys
p = sys.argv[1] + "/src/api/hub.zig"; s = open(p).read()
def sub(old, new):
    global s
    assert s.count(old) == 1, (old[:80], s.count(old)); s = s.replace(old, new)
sub("""/// Cached database check for /health. It runs on its own read-only connection (never a pooled reader, never the writer),
/// so the hot paths do not wait for it: first at startup in the background, then every `db_check_every_ms`, and on demand.""",
"""/// Cached database check for /health. Each run opens a FRESH short-lived read-only connection (never a pooled reader, never
/// the writer, never kept between runs), so the hot paths do not wait for it: first at startup in the background, then every
/// `db_check_every_ms`, and on demand. Merge-lane fix 10/14: a connection KEPT between runs reported FTS5 "corruption found
/// reading blob" on every other check once the writer had rewritten FTS5 segments (stale cached structure; the file was
/// sound: receipts/merge/hub_stale_*.json, fix/repro_*.txt). A fresh connection per run never did.""")
sub("""    /// Serialises runs (the dedicated connection is single-threaded).
    run_mu: std.Io.Mutex = .init,""", """    /// Serialises runs (one check at a time).
    run_mu: std.Io.Mutex = .init,""")
sub("""    conn: ?store.Store = null,
    state:""", """    state:""")
sub("""    /// `PRAGMA quick_check(5)` on the check's own read-only connection; result cached for /health.""",
    """    /// `PRAGMA quick_check(5)` on a fresh read-only connection opened for this run and closed after it; result cached for /health.""")
sub("""        if (c.conn == null) {
            c.conn = store.Store.open(hub.gpa, hub.io, hub.db_path, .{ .read_only = true }) catch |e| blk: {
                msg = std.fmt.bufPrint(&buf, "cannot open: {s}", .{@errorName(e)}) catch "cannot open";
                break :blk null;
            };
        }
        if (c.conn) |*cs| {
            if (quickCheck(cs, &buf)) |m| {
                msg = m;
                ok = std.mem.eql(u8, m, "ok");
            } else |e| {
                msg = std.fmt.bufPrint(&buf, "quick_check error: {s}", .{@errorName(e)}) catch "quick_check error";
            }
            if (!ok) { // reopen next time: a failed connection must not mask a later repair
                cs.close();
                c.conn = null;
            }
        }""", """        var conn: ?store.Store = store.Store.open(hub.gpa, hub.io, hub.db_path, .{ .read_only = true }) catch |e| blk: {
            msg = std.fmt.bufPrint(&buf, "cannot open: {s}", .{@errorName(e)}) catch "cannot open";
            break :blk null;
        };
        if (conn) |*cs| {
            defer cs.close(); // never kept between runs (see DbCheck)
            if (quickCheck(cs, &buf)) |m| {
                msg = m;
                ok = std.mem.eql(u8, m, "ok");
            } else |e| {
                msg = std.fmt.bufPrint(&buf, "quick_check error: {s}", .{@errorName(e)}) catch "quick_check error";
            }
        }""")
open(p, "w").write(s); print("hub.zig patched")
