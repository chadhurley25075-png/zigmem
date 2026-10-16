//! zigmem store root: one SQLite file, scope-mandatory reads, `<private>` stripped at every text write. No network code.
const std = @import("std");
pub const sqlite = @import("sqlite.zig");
pub const schema = @import("schema.zig");
pub const private = @import("private.zig");
pub const l0 = @import("l0.zig");
pub const atoms = @import("atoms.zig");
pub const scenes = @import("scenes.zig");
pub const vec = @import("vec.zig");
pub const jobs = @import("jobs.zig");
pub const writer = @import("writer.zig");

pub const Error = error{ ScopeRequired, TooManyScopes, PrivateFilterFailed };

/// The set of scopes a caller may read/write. Required by every query; never derived from request bodies.
pub const Scope = struct {
    names: []const []const u8,

    /// 64 (was 16): a household's readable set is household + every person + every seat (integration).
    pub const max = 64;

    pub fn one(name: *const [1][]const u8) Scope {
        return .{ .names = name };
    }

    pub fn check(self: Scope) Error!void {
        if (self.names.len == 0) return error.ScopeRequired;
        if (self.names.len > max) return error.TooManyScopes;
        for (self.names) |n| if (n.len == 0) return error.ScopeRequired;
    }

    pub fn has(self: Scope, name: []const u8) bool {
        for (self.names) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }

    /// Appends `<col> IN (?a,?a+1,…)` using numbered parameters starting at `first`.
    pub fn sqlIn(self: Scope, gpa: std.mem.Allocator, sql: *std.ArrayList(u8), col: []const u8, first: usize) !void {
        try self.check();
        try sql.print(gpa, "{s} IN (", .{col});
        for (self.names, 0..) |_, i| try sql.print(gpa, "{s}?{d}", .{ if (i == 0) "" else ",", first + i });
        try sql.appendSlice(gpa, ")");
    }

    pub fn bind(self: Scope, st: sqlite.Stmt, first: usize) !void {
        for (self.names, 0..) |n, i| try st.bind(@intCast(first + i), n);
    }
};

pub const Options = struct {
    /// `<private>` stripping at write. Off only when the home deployment kill switch (ZIGMEM_PRIVATE_TAGS=0) says so.
    private_tags: bool = true,
    read_only: bool = false,
};

pub const Store = struct {
    db: sqlite.Db,
    gpa: std.mem.Allocator,
    io: std.Io,
    private_tags: bool,

    /// Open (create if missing) and migrate. A read-only store never migrates and refuses writes at the SQLite layer.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, path: [:0]const u8, opts: Options) !Store {
        const db = try sqlite.Db.open(path, opts.read_only);
        errdefer db.close();
        try schema.pragmas(db, !opts.read_only);
        if (!opts.read_only) try schema.migrate(db);
        return .{ .db = db, .gpa = gpa, .io = io, .private_tags = opts.private_tags };
    }

    pub fn close(self: *Store) void {
        self.db.close();
    }

    pub fn nowMs(self: *const Store) i64 {
        return std.Io.Timestamp.now(self.io, .real).toMilliseconds();
    }

    /// Strip `<private>` from text bound for the database. Any failure → error, and the caller writes nothing.
    pub fn clean(self: *Store, text: []const u8) Error!private.Stripped {
        return private.strip(self.gpa, text, self.private_tags) catch error.PrivateFilterFailed;
    }

    pub fn audit(self: *Store, seat: []const u8, action: []const u8, table: []const u8, row_id: ?i64, detail: ?[]const u8) !void {
        try self.db.run("INSERT INTO audit(ts_ms, seat, action, table_name, row_id, detail) VALUES (?1,?2,?3,?4,?5,?6)", .{ self.nowMs(), seat, action, table, row_id, detail });
    }

    pub fn setMeta(self: *Store, k: []const u8, v: []const u8) !void {
        try self.db.run("INSERT INTO meta(k, v) VALUES (?1, ?2) ON CONFLICT(k) DO UPDATE SET v = excluded.v", .{ k, v });
    }

    /// Caller owns the returned slice.
    pub fn getMeta(self: *Store, gpa: std.mem.Allocator, k: []const u8) !?[]u8 {
        var st = try self.db.prepare("SELECT v FROM meta WHERE k = ?1");
        defer st.deinit();
        try st.bind(1, k);
        return if (try st.step()) try gpa.dupe(u8, st.text(0)) else null;
    }

    /// Run `body` inside a savepoint (nests inside the writer's transaction; standalone it is its own transaction).
    pub fn savepoint(self: *Store, comptime body: anytype, args: anytype) !ReturnPayload(body) {
        try self.db.exec("SAVEPOINT zs");
        const r = @call(.auto, body, args) catch |e| {
            self.db.exec("ROLLBACK TO zs; RELEASE zs") catch {};
            return e;
        };
        try self.db.exec("RELEASE zs");
        return r;
    }

    /// PRAGMA integrity_check plus FTS5 integrity-check on both indexes. Returns true when everything is "ok".
    pub fn integrity(self: *Store) !bool {
        var st = try self.db.prepare("PRAGMA integrity_check");
        defer st.deinit();
        if (!try st.step()) return false;
        if (!std.mem.eql(u8, st.text(0), "ok")) return false;
        self.db.exec("INSERT INTO atoms_fts(atoms_fts, rank) VALUES ('integrity-check', 1)") catch return false;
        self.db.exec("INSERT INTO l0_fts(l0_fts, rank) VALUES ('integrity-check', 1)") catch return false;
        return true;
    }
};

pub fn ReturnPayload(comptime f: anytype) type {
    const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    return switch (@typeInfo(R)) {
        .error_union => |eu| eu.payload,
        else => R,
    };
}

pub fn sha256(parts: []const []const u8) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts) |p| {
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, p.len, .little);
        h.update(&len);
        h.update(p);
    }
    return h.finalResult();
}

pub const FtsPlan = struct {
    match: []u8,
    /// Every query term is very common: callers return the newest matches instead of a bm25 ranking.
    capped: bool,
};

/// Build an FTS5 MATCH expression from free text: alphanumeric (and non-ASCII) runs, quoted, OR-joined, ≤ 16
/// terms. Terms in more than max(1000, rows/20) documents are dropped (their IDF is ~0 and ranking them costs a
/// full doclist scan); the document frequency is counted through MATCH itself, so stemming stays consistent and
/// the count stops at the threshold. If every term is that common, all are kept and `capped` is set.
/// Null when the text has no searchable term. `fts`/`base` are trusted table names from this module.
pub fn ftsPlan(self: *Store, gpa: std.mem.Allocator, comptime fts: []const u8, comptime base: []const u8, text: []const u8) !?FtsPlan {
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(gpa);
    var kept: std.ArrayList(u8) = .empty;
    errdefer kept.deinit(gpa);
    const total = (try self.db.oneInt("SELECT coalesce(max(id), 0) FROM " ++ base, .{})) orelse 0;
    const thresh = @max(1000, @divTrunc(total, 20));
    var df = try self.db.prepare("SELECT count(*) FROM (SELECT 1 FROM " ++ fts ++ " WHERE " ++ fts ++ " MATCH ?1 LIMIT ?2)");
    defer df.deinit();
    var terms: usize = 0;
    var i: usize = 0;
    var qbuf: [258]u8 = undefined;
    while (i < text.len and terms < 16) {
        while (i < text.len and !isWord(text[i])) i += 1;
        const s = i;
        while (i < text.len and isWord(text[i])) i += 1;
        if (i == s) break;
        const quoted = try std.fmt.bufPrint(&qbuf, "\"{s}\"", .{text[s..@min(i, s + 256)]});
        if (std.mem.indexOf(u8, all.items, quoted) != null) continue;
        if (terms > 0) try all.appendSlice(gpa, " OR ");
        try all.appendSlice(gpa, quoted);
        terms += 1;
        df.reset();
        try df.bindAll(.{ quoted, thresh + 1 });
        if (!try df.step()) continue;
        if (df.int(0) > thresh) continue;
        if (kept.items.len > 0) try kept.appendSlice(gpa, " OR ");
        try kept.appendSlice(gpa, quoted);
    }
    if (terms == 0) {
        kept.deinit(gpa);
        return null;
    }
    if (kept.items.len == 0) {
        kept.deinit(gpa);
        return .{ .match = try gpa.dupe(u8, all.items), .capped = true };
    }
    return .{ .match = try kept.toOwnedSlice(gpa), .capped = false };
}

fn isWord(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b >= 0x80;
}
