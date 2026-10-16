//! L0 raw turns: append-only, sha-idempotent capture, session cursor, scope-filtered FTS5 search.
const std = @import("std");
const root = @import("store.zig");
const Store = root.Store;
const Scope = root.Scope;
const Blob = root.sqlite.Blob;

pub const Turn = struct {
    session_id: []const u8,
    seat: []const u8,
    scope: []const u8,
    role: []const u8,
    text: []const u8,
    ts_ms: i64,
};

/// Append one turn after `<private>` stripping. Returns the row id, or null when the same turn (session, role, ts,
/// cleaned text) was already captured. A turn whose text is entirely private still lands as the mark.
pub fn append(st: *Store, t: Turn) !?i64 {
    if (t.scope.len == 0) return error.ScopeRequired;
    const cl = try st.clean(t.text);
    defer st.gpa.free(cl.text);
    var tsb: [8]u8 = undefined;
    std.mem.writeInt(i64, &tsb, t.ts_ms, .little);
    const h = root.sha256(&.{ t.session_id, t.role, &tsb, cl.text });
    const now = st.nowMs();
    try st.db.run(
        \\INSERT INTO l0(session_id, seat, scope, role, text, ts_ms, recorded_ms, sha256, private_dropped)
        \\VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9) ON CONFLICT(sha256) DO NOTHING
    , .{ t.session_id, t.seat, t.scope, t.role, cl.text, t.ts_ms, now, Blob{ .bytes = &h }, cl.changed });
    if (st.db.changes() == 0) return null;
    const id = st.db.lastId();
    try st.db.run(
        \\INSERT INTO sessions(id, seat, started_ms, last_ms, turns) VALUES (?1,?2,?3,?3,1)
        \\ON CONFLICT(id) DO UPDATE SET last_ms = max(last_ms, excluded.last_ms), turns = turns + 1
    , .{ t.session_id, t.seat, t.ts_ms });
    return id;
}

/// Turns captured for a session so far (the capture cursor).
pub fn sessionTurns(st: *Store, session_id: []const u8) !i64 {
    return (try st.db.oneInt("SELECT turns FROM sessions WHERE id = ?1", .{session_id})) orelse 0;
}

pub const Hit = struct { id: i64, session_id: []u8, role: []u8, text: []u8, ts_ms: i64, score: f64 };

pub const SearchOpts = struct { limit: u32 = 10, since_ms: ?i64 = null, until_ms: ?i64 = null };

fn freeHit(gpa: std.mem.Allocator, h: Hit) void {
    gpa.free(h.session_id);
    gpa.free(h.role);
    gpa.free(h.text);
}

pub fn freeHits(gpa: std.mem.Allocator, hits: []Hit) void {
    for (hits) |h| freeHit(gpa, h);
    gpa.free(hits);
}

/// BM25 search over L0 inside `scope`, optional [since, until) on ts_ms. Lower score = better (bm25 convention).
pub fn search(st: *Store, gpa: std.mem.Allocator, scope: Scope, query: []const u8, o: SearchOpts) ![]Hit {
    try scope.check();
    const plan = (try root.ftsPlan(st, gpa, "l0_fts", "l0", query)) orelse return gpa.alloc(Hit, 0);
    defer gpa.free(plan.match);
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(gpa);
    try sql.appendSlice(gpa,
        \\SELECT l.id, l.session_id, l.role, l.text, l.ts_ms, bm25(l0_fts) AS r
        \\FROM l0_fts JOIN l0 l ON l.id = l0_fts.rowid
        \\WHERE l0_fts MATCH ?1 AND l.ts_ms >= ?2 AND l.ts_ms < ?3
    );
    try sql.appendSlice(gpa, " AND ");
    try scope.sqlIn(gpa, &sql, "l.scope", 5);
    try sql.appendSlice(gpa, if (plan.capped) " ORDER BY l0_fts.rowid DESC LIMIT ?4" else " ORDER BY r LIMIT ?4");
    var s = try st.db.prepare(sql.items);
    defer s.deinit();
    try s.bindAll(.{ plan.match, o.since_ms orelse std.math.minInt(i64), o.until_ms orelse std.math.maxInt(i64), o.limit });
    try scope.bind(s, 5);
    var out: std.ArrayList(Hit) = .empty;
    errdefer {
        for (out.items) |h| freeHit(gpa, h);
        out.deinit(gpa);
    }
    while (try s.step()) {
        try out.append(gpa, .{
            .id = s.int(0),
            .session_id = try gpa.dupe(u8, s.text(1)),
            .role = try gpa.dupe(u8, s.text(2)),
            .text = try gpa.dupe(u8, s.text(3)),
            .ts_ms = s.int(4),
            .score = s.float(5),
        });
    }
    return out.toOwnedSlice(gpa);
}
