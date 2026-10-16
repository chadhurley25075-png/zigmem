//! L2 scenes and L3 persona rows: code writes them, hard length caps in code, prior text kept in the audit row.
const std = @import("std");
const root = @import("store.zig");
const Store = root.Store;
const Scope = root.Scope;

pub const summary_cap = 300;
pub const body_cap = 8000;
pub const persona_cap = 2000;
pub const scene_cap_per_scope = 15;

/// Cut to at most `n` codepoints on a UTF-8 lead-byte boundary.
pub fn capChars(s: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    var count: usize = 0;
    while (i < s.len) : (count += 1) {
        if (count == n) return s[0..i];
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += @min(l, s.len - i);
    }
    return s;
}

pub const SceneIn = struct { scope: []const u8, name: []const u8, summary: []const u8, body: []const u8, heat: f64 = 0, seat: []const u8 = "store" };

fn putSceneBody(st: *Store, s: SceneIn) !i64 {
    if (s.scope.len == 0 or s.name.len == 0) return error.ScopeRequired;
    const exists = (try st.db.oneInt("SELECT id FROM scenes WHERE scope = ?1 AND name = ?2", .{ s.scope, s.name })) != null;
    if (!exists) {
        const n = (try st.db.oneInt("SELECT count(*) FROM scenes WHERE scope = ?1 AND status = 'active'", .{s.scope})) orelse 0;
        if (n >= scene_cap_per_scope) return error.SceneCapReached;
    }
    const sm = try st.clean(s.summary);
    defer st.gpa.free(sm.text);
    const bd = try st.clean(s.body);
    defer st.gpa.free(bd.text);
    // the prior text rides in the audit row (summary + body), so a rewrite is never a loss
    var prev: ?[]u8 = null;
    defer if (prev) |p| st.gpa.free(p);
    {
        var q = try st.db.prepare("SELECT summary, body FROM scenes WHERE scope = ?1 AND name = ?2");
        defer q.deinit();
        try q.bindAll(.{ s.scope, s.name });
        if (try q.step()) prev = try std.fmt.allocPrint(st.gpa, "prev_summary={s}\nprev_body={s}", .{ q.text(0), q.text(1) });
    }
    try st.db.run(
        \\INSERT INTO scenes(scope, name, summary, body, heat, updated_ms) VALUES (?1,?2,?3,?4,?5,?6)
        \\ON CONFLICT(scope, name) DO UPDATE SET summary = excluded.summary, body = excluded.body,
        \\  heat = excluded.heat, updated_ms = excluded.updated_ms, status = 'active'
    , .{ s.scope, s.name, capChars(sm.text, summary_cap), capChars(bd.text, body_cap), s.heat, st.nowMs() });
    const id = (try st.db.oneInt("SELECT id FROM scenes WHERE scope = ?1 AND name = ?2", .{ s.scope, s.name })).?;
    try st.audit(s.seat, if (prev == null) "insert" else "rewrite", "scenes", id, prev);
    return id;
}

/// Insert or rewrite a scene (≤ 15 active per scope, enforced here, not in a prompt).
pub fn putScene(st: *Store, s: SceneIn) !i64 {
    return st.savepoint(putSceneBody, .{ st, s });
}

pub const Scene = struct {
    id: i64,
    name: []u8,
    summary: []u8,
    body: []u8,
    heat: f64,
    pub fn deinit(s: Scene, gpa: std.mem.Allocator) void {
        gpa.free(s.name);
        gpa.free(s.summary);
        gpa.free(s.body);
    }
};

/// Active scenes in `scope`, hottest first (name order breaks ties, so the list is deterministic).
pub fn listScenes(st: *Store, gpa: std.mem.Allocator, scope: Scope) ![]Scene {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(gpa);
    try sql.appendSlice(gpa, "SELECT id, name, summary, body, heat FROM scenes WHERE status = 'active' AND ");
    try scope.sqlIn(gpa, &sql, "scope", 1);
    try sql.appendSlice(gpa, " ORDER BY heat DESC, name");
    var s = try st.db.prepare(sql.items);
    defer s.deinit();
    try scope.bind(s, 1);
    var out: std.ArrayList(Scene) = .empty;
    errdefer {
        for (out.items) |x| x.deinit(gpa);
        out.deinit(gpa);
    }
    while (try s.step()) try out.append(gpa, .{
        .id = s.int(0),
        .name = try gpa.dupe(u8, s.text(1)),
        .summary = try gpa.dupe(u8, s.text(2)),
        .body = try gpa.dupe(u8, s.text(3)),
        .heat = s.float(4),
    });
    return out.toOwnedSlice(gpa);
}

fn putPersonaBody(st: *Store, subject: []const u8, scope: []const u8, text: []const u8, seat: []const u8) !i64 {
    if (scope.len == 0 or subject.len == 0) return error.ScopeRequired;
    const cl = try st.clean(text);
    defer st.gpa.free(cl.text);
    var prev: ?[]u8 = null;
    defer if (prev) |p| st.gpa.free(p);
    {
        var q = try st.db.prepare("SELECT text FROM persona WHERE subject = ?1 AND scope = ?2");
        defer q.deinit();
        try q.bindAll(.{ subject, scope });
        if (try q.step()) prev = try std.fmt.allocPrint(st.gpa, "prev={s}", .{q.text(0)});
    }
    try st.db.run(
        \\INSERT INTO persona(subject, scope, text, rev, built_ms) VALUES (?1,?2,?3,1,?4)
        \\ON CONFLICT(subject, scope) DO UPDATE SET text = excluded.text, rev = rev + 1, built_ms = excluded.built_ms
    , .{ subject, scope, capChars(cl.text, persona_cap), st.nowMs() });
    const rev = (try st.db.oneInt("SELECT rev FROM persona WHERE subject = ?1 AND scope = ?2", .{ subject, scope })).?;
    const detail = try std.fmt.allocPrint(st.gpa, "rev={d} {s}", .{ rev, prev orelse "" });
    defer st.gpa.free(detail);
    try st.audit(seat, "persona", "persona", null, detail);
    return rev;
}

/// One persona per subject per scope; returns the new revision. Text capped at 2000 characters in code; the prior text
/// is kept in the audit row.
pub fn putPersona(st: *Store, subject: []const u8, scope: []const u8, text: []const u8, seat: []const u8) !i64 {
    return st.savepoint(putPersonaBody, .{ st, subject, scope, text, seat });
}

/// Caller owns the text. Null when absent or outside `scope`.
pub fn getPersona(st: *Store, gpa: std.mem.Allocator, scope: Scope, subject: []const u8, in_scope: []const u8) !?[]u8 {
    if (!scope.has(in_scope)) return null;
    var s = try st.db.prepare("SELECT text FROM persona WHERE subject = ?1 AND scope = ?2");
    defer s.deinit();
    try s.bindAll(.{ subject, in_scope });
    return if (try s.step()) try gpa.dupe(u8, s.text(0)) else null;
}
