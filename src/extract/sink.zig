//! The narrow write interface extraction uses (insert / supersede / demote / find-similar), plus an in-memory sink.
//! There is no delete in the interface: an LLM decision can only add rows or flip an old row's status.
const std = @import("std");

pub const Status = enum { active, superseded, pending_review, retired };

/// Provenance stamped on every row (SPEC §1.1 provenance).
pub const Prov = struct {
    extractor: []const u8,
    model: []const u8,
    prompt_version: []const u8,
    prompt_sha: [32]u8,
    /// sha256 of the source turn AFTER `<private>` stripping (session, id, text).
    src_turn_sha: [32]u8,
    run_id: []const u8,
    turn_id: i64,
};

pub const NewRow = struct {
    subject: []const u8,
    scope: []const u8,
    type: []const u8,
    text: []const u8,
    priority: i64,
    valid_from: ?[]const u8,
    status: Status,
    note: ?[]const u8 = null,
    prov: Prov,
};

pub const Cand = struct { id: i64, subject: []const u8, text: []const u8, scope: []const u8 = "" };

pub const Sink = struct {
    ptr: *anyopaque,
    vt: *const VTable,

    pub const VTable = struct {
        insert: *const fn (ptr: *anyopaque, row: NewRow) anyerror!i64,
        /// New row joins `old`'s lineage; `old` becomes superseded with valid_to. Same subject + scope only (the
        /// pipeline moves a superseding row into the target's scope first, so a parent's update about a child replaces
        /// the child's atom where it lives).
        supersede: *const fn (ptr: *anyopaque, old: i64, row: NewRow) anyerror!i64,
        /// Demote a wrong row (status flip to retired, with an audit note naming the correcting row). Never removes it.
        demote: *const fn (ptr: *anyopaque, id: i64, by: i64, reason: []const u8) anyerror!void,
        /// Active rows similar to `text`, best first, at most `limit`: every row in `scope`, plus rows about `subject`
        /// in other scopes the writer may see (never a medical row from another scope). Memory owned by `a`.
        findSimilar: *const fn (ptr: *anyopaque, a: std.mem.Allocator, scope: []const u8, subject: []const u8, text: []const u8, limit: usize) anyerror![]Cand,
    };

    pub fn insert(s: Sink, row: NewRow) !i64 {
        return s.vt.insert(s.ptr, row);
    }
    pub fn supersede(s: Sink, old: i64, row: NewRow) !i64 {
        return s.vt.supersede(s.ptr, old, row);
    }
    pub fn demote(s: Sink, id: i64, by: i64, reason: []const u8) !void {
        return s.vt.demote(s.ptr, id, by, reason);
    }
    pub fn findSimilar(s: Sink, a: std.mem.Allocator, scope: []const u8, subject: []const u8, text: []const u8, limit: usize) ![]Cand {
        return s.vt.findSimilar(s.ptr, a, scope, subject, text, limit);
    }
};

const stop = [_][]const u8{ "the", "and", "for", "with", "that", "this", "has", "have", "his", "her", "their", "are", "was", "were", "now", "not", "from", "about", "will", "into", "on", "at", "is", "of", "to", "in", "a", "an", "be", "it", "by", "as", "she", "he", "they", "them", "who", "had", "its" };

/// Content words: lowercase ASCII alnum runs ≥3, possessive and plural 's' folded, stop words dropped.
pub fn contentWords(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n.,;:!?\"()[]{}/-");
    outer: while (it.next()) |w0| {
        var w = w0;
        if (std.mem.endsWith(u8, w, "'s")) w = w[0 .. w.len - 2];
        if (w.len < 3) continue;
        const low = try std.ascii.allocLowerString(a, w);
        var stem = low;
        if (stem.len > 4 and stem[stem.len - 1] == 's' and stem[stem.len - 2] != 's') stem = stem[0 .. stem.len - 1];
        for (stop) |s| if (std.mem.eql(u8, s, stem)) continue :outer;
        for (out.items) |x| if (std.mem.eql(u8, x, stem)) continue :outer;
        try out.append(a, stem);
    }
    return out.items;
}

pub fn shared(x: []const []const u8, y: []const []const u8) usize {
    var n: usize = 0;
    for (x) |p| for (y) |q| {
        if (std.mem.eql(u8, p, q)) n += 1;
    };
    return n;
}

/// In-memory sink for tests and the gate when no store is wired. Keeps every row forever.
pub const MemSink = struct {
    arena: std.heap.ArenaAllocator,
    rows: std.ArrayList(Row) = .empty,
    audit: std.ArrayList([]const u8) = .empty,
    clock: i64 = 0,

    pub const Row = struct {
        id: i64,
        lineage: i64,
        row: NewRow,
        status: Status,
        valid_to: ?[]const u8 = null,
        superseded_by: ?i64 = null,
        demoted_by: ?i64 = null,
        recorded_seq: i64,
    };

    pub fn init(gpa: std.mem.Allocator) MemSink {
        return .{ .arena = .init(gpa) };
    }
    pub fn deinit(m: *MemSink) void {
        m.arena.deinit();
    }

    pub fn sink(m: *MemSink) Sink {
        return .{ .ptr = m, .vt = &vt };
    }

    const vt: Sink.VTable = .{ .insert = insertFn, .supersede = supersedeFn, .demote = demoteFn, .findSimilar = findFn };

    fn dupeRow(m: *MemSink, r: NewRow) !NewRow {
        const a = m.arena.allocator();
        var x = r;
        x.subject = try a.dupe(u8, r.subject);
        x.scope = try a.dupe(u8, r.scope);
        x.type = try a.dupe(u8, r.type);
        x.text = try a.dupe(u8, r.text);
        x.valid_from = if (r.valid_from) |v| try a.dupe(u8, v) else null;
        x.note = if (r.note) |v| try a.dupe(u8, v) else null;
        x.prov.extractor = try a.dupe(u8, r.prov.extractor);
        x.prov.model = try a.dupe(u8, r.prov.model);
        x.prov.prompt_version = try a.dupe(u8, r.prov.prompt_version);
        x.prov.run_id = try a.dupe(u8, r.prov.run_id);
        return x;
    }

    fn add(m: *MemSink, r: NewRow, lineage: ?i64) !i64 {
        const id: i64 = @intCast(m.rows.items.len + 1);
        m.clock += 1;
        try m.rows.append(m.arena.allocator(), .{ .id = id, .lineage = lineage orelse id, .row = try m.dupeRow(r), .status = r.status, .recorded_seq = m.clock });
        try m.note("insert", id, null);
        return id;
    }

    fn note(m: *MemSink, what: []const u8, id: i64, detail: ?[]const u8) !void {
        try m.audit.append(m.arena.allocator(), try std.fmt.allocPrint(m.arena.allocator(), "{s} {d} {s}", .{ what, id, detail orelse "" }));
    }

    fn get(m: *MemSink, id: i64) ?*Row {
        if (id < 1 or id > m.rows.items.len) return null;
        return &m.rows.items[@intCast(id - 1)];
    }

    fn insertFn(ptr: *anyopaque, r: NewRow) anyerror!i64 {
        const m: *MemSink = @ptrCast(@alignCast(ptr));
        return m.add(r, null);
    }

    fn supersedeFn(ptr: *anyopaque, old: i64, r: NewRow) anyerror!i64 {
        const m: *MemSink = @ptrCast(@alignCast(ptr));
        const o = m.get(old) orelse return error.NoSuchAtom;
        if (o.status != .active) return error.NotActive;
        if (!std.mem.eql(u8, o.row.subject, r.subject) or !std.mem.eql(u8, o.row.scope, r.scope)) return error.CrossSubject;
        const lineage = o.lineage;
        const id = try m.add(r, lineage);
        const o2 = m.get(old).?; // rows may have moved on append
        o2.status = .superseded;
        o2.superseded_by = id;
        o2.valid_to = if (r.valid_from) |v| try m.arena.allocator().dupe(u8, v) else null;
        try m.note("supersede", old, null);
        return id;
    }

    fn demoteFn(ptr: *anyopaque, id: i64, by: i64, reason: []const u8) anyerror!void {
        const m: *MemSink = @ptrCast(@alignCast(ptr));
        const o = m.get(id) orelse return error.NoSuchAtom;
        if (o.status != .active) return error.NotActive;
        o.status = .retired;
        o.demoted_by = by;
        try m.note("demote", id, reason);
    }

    fn findFn(ptr: *anyopaque, a: std.mem.Allocator, scope: []const u8, subject: []const u8, text: []const u8, limit: usize) anyerror![]Cand {
        const m: *MemSink = @ptrCast(@alignCast(ptr));
        const q = try contentWords(a, text);
        const Hit = struct { c: Cand, s: usize };
        var hits: std.ArrayList(Hit) = .empty;
        for (m.rows.items) |r| {
            if (r.status != .active) continue;
            // the scope's rows, plus rows about the same subject elsewhere (the in-memory sink has no household policy)
            if (!std.mem.eql(u8, r.row.scope, scope) and !std.mem.eql(u8, r.row.subject, subject)) continue;
            const s = shared(q, try contentWords(a, r.row.text));
            if (s >= 2) try hits.append(a, .{ .c = .{ .id = r.id, .subject = r.row.subject, .text = r.row.text, .scope = r.row.scope }, .s = s });
        }
        std.mem.sort(Hit, hits.items, {}, struct {
            fn lt(_: void, x: Hit, y: Hit) bool {
                return x.s > y.s or (x.s == y.s and x.c.id > y.c.id);
            }
        }.lt);
        const n = @min(limit, hits.items.len);
        const out = try a.alloc(Cand, n);
        for (hits.items[0..n], 0..) |h, i| out[i] = h.c;
        return out;
    }
};

fn testRow(subject: []const u8, text: []const u8) NewRow {
    return .{ .subject = subject, .scope = "syn", .type = "fact", .text = text, .priority = 50, .valid_from = "2026-10-03", .status = .active, .prov = .{ .extractor = "t", .model = "m", .prompt_version = "v", .prompt_sha = @splat(0), .src_turn_sha = @splat(1), .run_id = "r", .turn_id = 1 } };
}

test "memsink: supersede keeps history; demote flips status; cross-subject supersede refused; nothing removed" {
    var m = MemSink.init(std.testing.allocator);
    defer m.deinit();
    const s = m.sink();
    const a = try s.insert(testRow("Leo", "Leo has soccer practice on Wednesdays."));
    const b = try s.supersede(a, testRow("Leo", "Leo has soccer practice on Tuesdays."));
    try std.testing.expectEqual(Status.superseded, m.rows.items[0].status);
    try std.testing.expectEqual(b, m.rows.items[0].superseded_by.?);
    try std.testing.expectEqual(m.rows.items[0].lineage, m.rows.items[1].lineage);
    try std.testing.expectEqual(@as(i64, 1), m.rows.items[0].recorded_seq); // creation time of the lineage is kept across a supersede
    const c = try s.insert(testRow("Morgan", "Morgan's car needs new tires."));
    try std.testing.expectError(error.CrossSubject, s.supersede(c, testRow("Alex", "Alex's truck needs new tires.")));
    const d = try s.insert(testRow("Alex", "Alex's truck needs new tires."));
    try s.demote(c, d, "corrected");
    try std.testing.expectEqual(Status.retired, m.rows.items[2].status);
    try std.testing.expectError(error.NotActive, s.demote(c, d, "again"));
    try std.testing.expectEqual(@as(usize, 4), m.rows.items.len);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cands = try s.findSimilar(arena.allocator(), "syn", "Leo", "Leo's soccer practice is on Tuesdays", 5);
    try std.testing.expectEqual(@as(usize, 1), cands.len); // superseded row is not a candidate
    try std.testing.expectEqual(b, cands[0].id);
    try std.testing.expectEqualStrings("syn", cands[0].scope);
    // a row about the same subject in another scope is a candidate; a row about someone else there is not
    var other = testRow("Leo", "Leo's soccer practice moved to Fridays.");
    other.scope = "person:leo";
    const e = try s.insert(other);
    var stranger = testRow("Morgan", "Morgan's soccer practice is on Tuesdays.");
    stranger.scope = "person:morgan";
    _ = try s.insert(stranger);
    const c2 = try s.findSimilar(arena.allocator(), "syn", "Leo", "Leo soccer practice", 5);
    try std.testing.expectEqual(@as(usize, 2), c2.len);
    try std.testing.expect((c2[0].id == e and c2[1].id == b) or (c2[0].id == b and c2[1].id == e));
}

test "no delete is reachable from src/extract (source scan)" {
    const files = .{ @embedFile("sink.zig"), @embedFile("pipeline.zig"), @embedFile("llm.zig"), @embedFile("parse.zig"), @embedFile("people.zig"), @embedFile("prompts.zig"), @embedFile("chunk.zig"), @embedFile("allow.zig"), @embedFile("store_sink.zig") };
    const banned = [_][]const u8{ "DELETE" ++ " FROM", "delete" ++ " from", "DROP" ++ " TABLE", "ordered" ++ "Remove(", "swap" ++ "Remove(", "shrink" ++ "RetainingCapacity(" };
    inline for (files) |src| for (banned) |b| try std.testing.expect(std.mem.indexOf(u8, src, b) == null);
}
