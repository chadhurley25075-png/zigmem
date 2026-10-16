//! L1 atoms: insert, bitemporal supersession (never delete), status flips with audit, lineage, scoped FTS5 search.
const std = @import("std");
const root = @import("store.zig");
const Store = root.Store;
const Scope = root.Scope;
const Blob = root.sqlite.Blob;

pub const Status = enum { active, superseded, pending_review, retired };

pub const types = [_][]const u8{ "fact", "preference", "event", "instruction", "person" };

/// Household types, plus any `work_*` type.
pub fn validType(t: []const u8) bool {
    for (types) |k| if (std.mem.eql(u8, k, t)) return true;
    return std.mem.startsWith(u8, t, "work_") and t.len > 5;
}

pub const New = struct {
    subject: []const u8,
    scope: []const u8,
    type: []const u8,
    text: []const u8,
    priority: i64 = 50,
    valid_from: ?[]const u8 = null,
    status: Status = .active,
    src_l0: ?[]const u8 = null,
    extractor: ?[]const u8 = null,
    prompt_sha: ?[32]u8 = null,
    run_id: ?[]const u8 = null,
    seat: []const u8 = "store",
};

const cols = "id, lineage, subject, scope, type, priority, text, valid_from, valid_to, recorded_ms, " ++
    "superseded_by, status, run_id";

pub const Atom = struct {
    id: i64,
    lineage: []u8,
    subject: []u8,
    scope: []u8,
    type: []u8,
    priority: i64,
    text: []u8,
    valid_from: ?[]u8,
    valid_to: ?[]u8,
    recorded_ms: i64,
    superseded_by: ?i64,
    status: Status,
    run_id: ?[]u8,
    score: f64 = 0,

    pub fn deinit(a: Atom, gpa: std.mem.Allocator) void {
        inline for (.{ a.lineage, a.subject, a.scope, a.type, a.text }) |s| gpa.free(s);
        inline for (.{ a.valid_from, a.valid_to, a.run_id }) |s| if (s) |x| gpa.free(x);
    }
};

pub fn freeAll(gpa: std.mem.Allocator, list: []Atom) void {
    for (list) |a| a.deinit(gpa);
    gpa.free(list);
}

fn optDupe(gpa: std.mem.Allocator, s: root.sqlite.Stmt, col: c_int) !?[]u8 {
    return if (s.isNull(col)) null else try gpa.dupe(u8, s.text(col));
}

fn readRow(gpa: std.mem.Allocator, s: root.sqlite.Stmt) !Atom {
    return .{
        .id = s.int(0),
        .lineage = try gpa.dupe(u8, s.text(1)),
        .subject = try gpa.dupe(u8, s.text(2)),
        .scope = try gpa.dupe(u8, s.text(3)),
        .type = try gpa.dupe(u8, s.text(4)),
        .priority = s.int(5),
        .text = try gpa.dupe(u8, s.text(6)),
        .valid_from = try optDupe(gpa, s, 7),
        .valid_to = try optDupe(gpa, s, 8),
        .recorded_ms = s.int(9),
        .superseded_by = if (s.isNull(10)) null else s.int(10),
        .status = std.meta.stringToEnum(Status, s.text(11)) orelse .pending_review,
        .run_id = try optDupe(gpa, s, 12),
    };
}

fn collect(gpa: std.mem.Allocator, s: root.sqlite.Stmt, with_score: bool) ![]Atom {
    var out: std.ArrayList(Atom) = .empty;
    errdefer {
        for (out.items) |a| a.deinit(gpa);
        out.deinit(gpa);
    }
    while (try s.step()) {
        var a = try readRow(gpa, s);
        if (with_score) a.score = s.float(13);
        out.append(gpa, a) catch |e| {
            a.deinit(gpa);
            return e;
        };
    }
    return out.toOwnedSlice(gpa);
}

fn insertRow(st: *Store, n: New, lineage: ?[]const u8) !i64 {
    if (n.scope.len == 0 or n.subject.len == 0) return error.ScopeRequired;
    if (!validType(n.type)) return error.BadAtomType;
    if (n.priority < -1 or n.priority > 100) return error.BadPriority;
    const cl = try st.clean(n.text);
    defer st.gpa.free(cl.text);
    const h = root.sha256(&.{ n.scope, n.subject, n.type, cl.text });
    var lin_buf: [17]u8 = undefined;
    const lin = lineage orelse blk: {
        var r: [8]u8 = undefined;
        st.io.random(&r);
        break :blk std.fmt.bufPrint(&lin_buf, "L{x}", .{&r}) catch unreachable;
    };
    try st.db.run("INSERT INTO atoms(lineage, subject, scope, type, priority, text, valid_from, recorded_ms, status, " ++
        "src_l0, extractor, prompt_sha, run_id, sha256) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)", .{
        lin,      n.subject,   n.scope,                                             n.type,   n.priority,          cl.text, n.valid_from, st.nowMs(), @tagName(n.status),
        n.src_l0, n.extractor, if (n.prompt_sha) |*p| Blob{ .bytes = p } else null, n.run_id, Blob{ .bytes = &h },
    });
    const id = st.db.lastId();
    try st.audit(n.seat, "insert", "atoms", id, if (cl.changed) "private-stripped" else null);
    return id;
}

/// Insert a new atom with a fresh lineage.
pub fn insert(st: *Store, n: New) !i64 {
    return st.savepoint(insertRow, .{ st, n, null });
}

fn supersedeBody(st: *Store, old_id: i64, n: New, valid_to: ?[]const u8) !i64 {
    var s = try st.db.prepare("SELECT lineage, subject, scope, status FROM atoms WHERE id = ?1");
    defer s.deinit();
    try s.bind(1, old_id);
    if (!try s.step()) return error.NoSuchAtom;
    if (!std.mem.eql(u8, s.text(3), "active")) return error.NotActive;
    // No cross-person or cross-scope merges (SPEC §1.3).
    if (!std.mem.eql(u8, s.text(1), n.subject) or !std.mem.eql(u8, s.text(2), n.scope)) return error.CrossSubject;
    const lineage = try st.gpa.dupe(u8, s.text(0));
    defer st.gpa.free(lineage);
    const new_id = try insertRow(st, n, lineage);
    try st.db.run("UPDATE atoms SET status = 'superseded', superseded_by = ?2, valid_to = coalesce(?3, ?4) " ++
        "WHERE id = ?1 AND status = 'active'", .{ old_id, new_id, valid_to, n.valid_from });
    if (st.db.changes() != 1) return error.NotActive;
    try st.audit(n.seat, "supersede", "atoms", old_id, null);
    return new_id;
}

/// Write `n` as the new version of `old_id`'s lineage; the old row becomes `superseded` (valid_to set), never removed.
pub fn supersede(st: *Store, old_id: i64, n: New, valid_to: ?[]const u8) !i64 {
    return st.savepoint(supersedeBody, .{ st, old_id, n, valid_to });
}

fn allowed(from: Status, to: Status) bool {
    return switch (from) {
        .pending_review => to == .active or to == .retired,
        .active => to == .retired or to == .pending_review,
        .superseded, .retired => false,
    };
}

fn setStatusBody(st: *Store, id: i64, to: Status, seat: []const u8) !void {
    var s = try st.db.prepare("SELECT status FROM atoms WHERE id = ?1");
    defer s.deinit();
    try s.bind(1, id);
    if (!try s.step()) return error.NoSuchAtom;
    const from = std.meta.stringToEnum(Status, s.text(0)) orelse return error.NoSuchAtom;
    if (!allowed(from, to)) return error.BadTransition;
    try st.db.run("UPDATE atoms SET status = ?2 WHERE id = ?1", .{ id, @tagName(to) });
    var buf: [64]u8 = undefined;
    try st.audit(seat, "status", "atoms", id, try std.fmt.bufPrint(&buf, "{s}->{s}", .{ @tagName(from), @tagName(to) }));
}

/// Retire / review / re-activate. A status flip with an audit row; there is no delete.
pub fn setStatus(st: *Store, id: i64, to: Status, seat: []const u8) !void {
    return st.savepoint(setStatusBody, .{ st, id, to, seat });
}

/// One atom, only if it lives in `scope`.
pub fn get(st: *Store, gpa: std.mem.Allocator, scope: Scope, id: i64) !?Atom {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(gpa);
    try sql.appendSlice(gpa, "SELECT " ++ cols ++ " FROM atoms WHERE id = ?1 AND ");
    try scope.sqlIn(gpa, &sql, "scope", 2);
    var s = try st.db.prepare(sql.items);
    defer s.deinit();
    try s.bind(1, id);
    try scope.bind(s, 2);
    return if (try s.step()) try readRow(gpa, s) else null;
}

/// Every version of a lineage inside `scope`, oldest first.
pub fn history(st: *Store, gpa: std.mem.Allocator, scope: Scope, lineage: []const u8) ![]Atom {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(gpa);
    try sql.appendSlice(gpa, "SELECT " ++ cols ++ " FROM atoms WHERE lineage = ?1 AND ");
    try scope.sqlIn(gpa, &sql, "scope", 2);
    try sql.appendSlice(gpa, " ORDER BY id");
    var s = try st.db.prepare(sql.items);
    defer s.deinit();
    try s.bind(1, lineage);
    try scope.bind(s, 2);
    return collect(gpa, s, false);
}

pub const SearchOpts = struct { limit: u32 = 10, include_inactive: bool = false, type: ?[]const u8 = null };

/// BM25 over active atoms inside `scope` (score: lower = better).
pub fn search(st: *Store, gpa: std.mem.Allocator, scope: Scope, query: []const u8, o: SearchOpts) ![]Atom {
    try scope.check();
    const plan = (try root.ftsPlan(st, gpa, "atoms_fts", "atoms", query)) orelse return gpa.alloc(Atom, 0);
    defer gpa.free(plan.match);
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(gpa);
    try sql.appendSlice(gpa, "SELECT a.id, a.lineage, a.subject, a.scope, a.type, a.priority, a.text, a.valid_from, " ++
        "a.valid_to, a.recorded_ms, a.superseded_by, a.status, a.run_id, bm25(atoms_fts) AS r " ++
        "FROM atoms_fts JOIN atoms a ON a.id = atoms_fts.rowid WHERE atoms_fts MATCH ?1 " ++
        "AND (?3 OR a.status = 'active') AND (?4 IS NULL OR a.type = ?4) AND ");
    try scope.sqlIn(gpa, &sql, "a.scope", 5);
    // All-common query: no term has signal, so take the newest matches (FTS5 walks rowids backwards and stops).
    try sql.appendSlice(gpa, if (plan.capped) " ORDER BY atoms_fts.rowid DESC LIMIT ?2" else " ORDER BY r LIMIT ?2");
    var s = try st.db.prepare(sql.items);
    defer s.deinit();
    try s.bindAll(.{ plan.match, o.limit, o.include_inactive, o.type });
    try scope.bind(s, 5);
    return collect(gpa, s, true);
}

/// Status of a set of ids inside `scope`, as a filter for vector hits (true = active and in scope).
pub fn activeIn(st: *Store, scope: Scope, id: i64) !bool {
    var buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var sql: std.ArrayList(u8) = .empty;
    try sql.appendSlice(fba.allocator(), "SELECT 1 FROM atoms WHERE id = ?1 AND status = 'active' AND ");
    try scope.sqlIn(fba.allocator(), &sql, "scope", 2);
    var s = try st.db.prepare(sql.items);
    defer s.deinit();
    try s.bind(1, id);
    try scope.bind(s, 2);
    return try s.step();
}
