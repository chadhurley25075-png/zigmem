//! Persistent job queue (embed/extract/scene/persona) that survives restarts, plus the provenance `runs` log.
const std = @import("std");
const root = @import("store.zig");
const Store = root.Store;
const Blob = root.sqlite.Blob;

pub const max_tries = 5;

/// Queue a job; a second enqueue of the same (kind, key) while one is queued is a no-op. Returns true if queued.
pub fn enqueue(st: *Store, kind: []const u8, key: []const u8, due_ms: i64) !bool {
    try st.db.run("INSERT OR IGNORE INTO jobs(kind, key, due_ms) VALUES (?1,?2,?3)", .{ kind, key, due_ms });
    return st.db.changes() == 1;
}

pub const Job = struct {
    id: i64,
    kind: []u8,
    key: []u8,
    tries: i64,
    pub fn deinit(j: Job, gpa: std.mem.Allocator) void {
        gpa.free(j.kind);
        gpa.free(j.key);
    }
};

/// Take the oldest due job (state queued → running, tries + 1). Null when nothing is due.
pub fn claim(st: *Store, gpa: std.mem.Allocator, now_ms: i64) !?Job {
    var s = try st.db.prepare(
        \\UPDATE jobs SET state = 'running', tries = tries + 1
        \\WHERE id = (SELECT id FROM jobs WHERE state = 'queued' AND due_ms <= ?1 ORDER BY due_ms, id LIMIT 1)
        \\RETURNING id, kind, key, tries
    );
    defer s.deinit();
    try s.bind(1, now_ms);
    if (!try s.step()) return null;
    const j: Job = .{ .id = s.int(0), .kind = try gpa.dupe(u8, s.text(1)), .key = try gpa.dupe(u8, s.text(2)), .tries = s.int(3) };
    while (try s.step()) {}
    return j;
}

/// Finish a running job: done, or back to queued after `retry_ms`, or `dead` after max_tries
/// (`merged` when an identical job was queued meanwhile — the queued twin will do the work).
pub fn finish(st: *Store, id: i64, err: ?[]const u8, retry_ms: i64) !void {
    if (err) |e| {
        try st.db.run(
            \\UPDATE jobs SET last_err = ?2, due_ms = ?3,
            \\  state = CASE WHEN tries >= ?4 THEN 'dead' WHEN EXISTS (SELECT 1 FROM jobs t WHERE t.kind = jobs.kind AND t.key = jobs.key AND t.state = 'queued')
            \\  THEN 'merged' ELSE 'queued' END WHERE id = ?1 AND state = 'running'
        , .{ id, e, st.nowMs() + retry_ms, max_tries });
    } else try st.db.run("UPDATE jobs SET state = 'done', last_err = NULL WHERE id = ?1 AND state = 'running'", .{id});
}

/// After a crash: every job left `running` goes back to `queued` (its try already counted). Returns how many.
pub fn recover(st: *Store) !i64 {
    try st.db.run("UPDATE jobs SET state = CASE WHEN EXISTS (SELECT 1 FROM jobs t WHERE t.kind = jobs.kind AND t.key = jobs.key AND t.state = 'queued') THEN 'merged' ELSE 'queued' END " ++
        "WHERE state = 'running'", .{});
    return st.db.changes();
}

pub fn count(st: *Store, state: []const u8) !i64 {
    return (try st.db.oneInt("SELECT count(*) FROM jobs WHERE state = ?1", .{state})) orelse 0;
}

/// Provenance: one row per extraction/scene/persona run, so a bad batch is found (and retired) with one query.
pub fn beginRun(st: *Store, id: []const u8, kind: []const u8, model: ?[]const u8, prompt_sha: ?[32]u8, in_ids: ?[]const u8) !void {
    try st.db.run("INSERT INTO runs(id, kind, model, prompt_sha, started_ms, in_ids) VALUES (?1,?2,?3,?4,?5,?6)", .{
        id, kind, model, if (prompt_sha) |*p| Blob{ .bytes = p } else null, st.nowMs(), in_ids,
    });
}

pub fn endRun(st: *Store, id: []const u8, out_ids: ?[]const u8, outcome: []const u8) !void {
    try st.db.run("UPDATE runs SET ended_ms = ?2, out_ids = ?3, outcome = ?4 WHERE id = ?1", .{ id, st.nowMs(), out_ids, outcome });
}
