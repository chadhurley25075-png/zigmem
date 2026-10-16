//! Per-seat bearer tokens. The token file (0600, owner only, refused otherwise) holds sha256(token), never the token;
//! the seat name, scopes and flags are bound to that hash, so a caller can never name its own seat or scopes.
//! Line format (tab-separated): seat, sha256 hex, scopes (comma), flags (w=writes t=trusted a=admin, or -),
//! person (or -), created_ms, revoked_ms (or -). The server re-reads the file when it changes (revocation is live).
const std = @import("std");
const linux = std.os.linux;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Seat = struct {
    name: []const u8,
    hash: [32]u8,
    scopes: []const []const u8,
    writes: bool,
    trusted: bool,
    admin: bool,
    person: ?[]const u8,
    created_ms: i64,
    revoked_ms: ?i64,
};

pub const Verdict = union(enum) { ok: *const Seat, unknown, revoked };

pub const max_seats = 256;
pub const token_prefix = "zm_";

pub fn validName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    return true;
}

pub fn validScope(s: []const u8) bool {
    // `*` alone = no narrowing: household policy alone decides what the seat reads (integration)
    if (s.len == 1 and s[0] == '*') return true;
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == ':' or c == '_' or c == '-')) return false;
    return true;
}

pub fn hashToken(tok: []const u8) [32]u8 {
    var d: [32]u8 = undefined;
    Sha256.hash(tok, &d, .{});
    return d;
}

/// Parsed file contents; everything lives in `arena`.
pub const Table = struct {
    arena: std.heap.ArenaAllocator,
    seats: []Seat,

    pub fn deinit(t: *Table) void {
        t.arena.deinit();
    }

    pub fn find(t: *const Table, name: []const u8) ?*const Seat {
        for (t.seats) |*s| if (std.mem.eql(u8, s.name, name)) {
            if (s.revoked_ms == null) return s;
        };
        return null;
    }

    /// Constant-time over every row (no early exit on a match).
    pub fn verify(t: *const Table, tok: []const u8) Verdict {
        const h = hashToken(tok);
        var hit: ?*const Seat = null;
        for (t.seats) |*s| {
            if (std.crypto.timing_safe.eql([32]u8, s.hash, h)) hit = s;
        }
        const s = hit orelse return .unknown;
        return if (s.revoked_ms != null) .revoked else .{ .ok = s };
    }
};

pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Table {
    var t: Table = .{ .arena = .init(gpa), .seats = &.{} };
    errdefer t.arena.deinit();
    const a = t.arena.allocator();
    var list: std.ArrayList(Seat) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const name = f.next() orelse return error.BadTokenFile;
        const hex = f.next() orelse return error.BadTokenFile;
        const scopes_s = f.next() orelse return error.BadTokenFile;
        const flags = f.next() orelse return error.BadTokenFile;
        const person = f.next() orelse return error.BadTokenFile;
        const created = f.next() orelse return error.BadTokenFile;
        const revoked = f.next() orelse return error.BadTokenFile;
        if (!validName(name) or hex.len != 64) return error.BadTokenFile;
        var h: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&h, hex) catch return error.BadTokenFile;
        var sc: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, scopes_s, ',');
        while (it.next()) |x| {
            if (!validScope(x)) return error.BadTokenFile;
            try sc.append(a, try a.dupe(u8, x));
        }
        if (sc.items.len == 0 or sc.items.len > 16) return error.BadTokenFile;
        try list.append(a, .{
            .name = try a.dupe(u8, name),
            .hash = h,
            .scopes = sc.items,
            .writes = std.mem.indexOfScalar(u8, flags, 'w') != null,
            .trusted = std.mem.indexOfScalar(u8, flags, 't') != null,
            .admin = std.mem.indexOfScalar(u8, flags, 'a') != null,
            .person = if (std.mem.eql(u8, person, "-")) null else try a.dupe(u8, person),
            .created_ms = std.fmt.parseInt(i64, created, 10) catch return error.BadTokenFile,
            .revoked_ms = if (std.mem.eql(u8, revoked, "-")) null else std.fmt.parseInt(i64, revoked, 10) catch return error.BadTokenFile,
        });
        if (list.items.len > max_seats) return error.BadTokenFile;
    }
    t.seats = list.items;
    return t;
}

pub fn render(a: std.mem.Allocator, seats: []const Seat) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "# zigmem seat tokens: seat, sha256(token), scopes, flags, person, created_ms, revoked_ms. Tokens are never stored.\n");
    for (seats) |s| {
        try out.print(a, "{s}\t{x}\t", .{ s.name, &s.hash });
        for (s.scopes, 0..) |x, i| try out.print(a, "{s}{s}", .{ if (i == 0) "" else ",", x });
        var fl: [3]u8 = undefined;
        var n: usize = 0;
        if (s.writes) fl[n] = 'w';
        if (s.writes) n += 1;
        if (s.trusted) fl[n] = 't';
        if (s.trusted) n += 1;
        if (s.admin) fl[n] = 'a';
        if (s.admin) n += 1;
        try out.print(a, "\t{s}\t{s}\t{d}\t", .{ if (n == 0) "-" else fl[0..n], s.person orelse "-", s.created_ms });
        if (s.revoked_ms) |r| try out.print(a, "{d}\n", .{r}) else try out.appendSlice(a, "-\n");
    }
    return out.items;
}

// ---- file I/O (raw syscalls: owner-only mode is checked, writes are atomic via rename) ----

pub const FileId = struct { ino: u64 = 0, size: u64 = 0, mtime_s: i64 = 0, mtime_ns: u32 = 0 };

fn statPath(path: [:0]const u8) !linux.Statx {
    var sx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path.ptr, 0, .{ .TYPE = true, .MODE = true, .UID = true, .MTIME = true, .INO = true, .SIZE = true }, &sx);
    switch (linux.errno(rc)) {
        .SUCCESS => return sx,
        .NOENT => return error.FileNotFound,
        else => return error.StatFailed,
    }
}

/// Refuses a token file readable or writable by anyone but its owner, or owned by someone else.
pub fn checkMode(path: [:0]const u8) !FileId {
    const sx = try statPath(path);
    if (sx.mode & 0o077 != 0) return error.TokenFileTooOpen;
    if (sx.uid != linux.getuid()) return error.TokenFileNotOurs;
    return .{ .ino = sx.ino, .size = sx.size, .mtime_s = sx.mtime.sec, .mtime_ns = sx.mtime.nsec };
}

pub fn readAll(a: std.mem.Allocator, path: [:0]const u8, limit: usize) ![]u8 {
    const rc = linux.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.FileNotFound;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        if (out.items.len + n > limit) return error.FileTooLarge;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.items;
}

/// Write `data` to `path` atomically with mode 0600 (tmp file + fsync + rename).
pub fn writeAtomic(a: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const tmp = try std.fmt.allocPrintSentinel(a, "{s}.tmp", .{path}, 0);
    const dst = try a.dupeSentinel(u8, path, 0);
    const rc = linux.open(tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true, .NOFOLLOW = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: i32 = @intCast(rc);
    var off: usize = 0;
    while (off < data.len) {
        const n = linux.write(fd, data[off..].ptr, data.len - off);
        if (linux.errno(n) != .SUCCESS) {
            _ = linux.close(fd);
            return error.WriteFailed;
        }
        off += n;
    }
    _ = linux.fchmod(fd, 0o600);
    if (linux.errno(linux.fsync(fd)) != .SUCCESS) {
        _ = linux.close(fd);
        return error.WriteFailed;
    }
    _ = linux.close(fd);
    if (linux.errno(linux.renameat(linux.AT.FDCWD, tmp.ptr, linux.AT.FDCWD, dst.ptr)) != .SUCCESS) return error.RenameFailed;
}

/// The live table used by the server: reloaded when the file's (inode, size, mtime) changes.
pub const Live = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: [:0]const u8,
    mu: std.Io.Mutex = .init,
    table: *Table,
    id: FileId,
    /// Old tables are kept until shutdown (a request may still hold a *Seat); bounded by `max_reloads`.
    old: std.ArrayList(*Table) = .empty,

    pub const max_reloads = 1024;

    pub fn open(gpa: std.mem.Allocator, io: std.Io, path: [:0]const u8) !Live {
        const id = try checkMode(path);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const text = try readAll(arena.allocator(), path, 1 << 20);
        const t = try gpa.create(Table);
        errdefer gpa.destroy(t);
        t.* = try parse(gpa, text);
        return .{ .gpa = gpa, .io = io, .path = path, .table = t, .id = id };
    }

    /// Current table (reloading first if the file changed). A file that became unsafe or unparseable
    /// fails CLOSED: every token is refused until it is fixed.
    pub fn current(l: *Live) ?*const Table {
        l.mu.lockUncancelable(l.io);
        defer l.mu.unlock(l.io);
        const id = checkMode(l.path) catch return null;
        if (!std.meta.eql(id, l.id)) {
            if (l.old.items.len >= max_reloads) return null;
            var arena: std.heap.ArenaAllocator = .init(l.gpa);
            defer arena.deinit();
            const text = readAll(arena.allocator(), l.path, 1 << 20) catch return null;
            const t = l.gpa.create(Table) catch return null;
            t.* = parse(l.gpa, text) catch {
                l.gpa.destroy(t);
                return null;
            };
            l.old.append(l.gpa, l.table) catch {};
            l.table = t;
            l.id = id;
        }
        return l.table;
    }

    pub fn deinit(l: *Live) void {
        for (l.old.items) |t| {
            t.deinit();
            l.gpa.destroy(t);
        }
        l.old.deinit(l.gpa);
        l.table.deinit();
        l.gpa.destroy(l.table);
    }
};

/// A new token: "zm_" + 64 hex chars from the OS CSPRNG.
pub fn newToken(io: std.Io, buf: *[67]u8) ![]const u8 {
    var r: [32]u8 = undefined;
    try io.randomSecure(&r);
    _ = try std.fmt.bufPrint(buf, token_prefix ++ "{x}", .{&r});
    return buf;
}

test "token file round trip, constant-time verify, revocation" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const seats = [_]Seat{
        .{ .name = "seat-a", .hash = hashToken("zm_a"), .scopes = &.{ "syn-a", "household" }, .writes = true, .trusted = false, .admin = false, .person = "ana", .created_ms = 1, .revoked_ms = null },
        .{ .name = "seat-b", .hash = hashToken("zm_b"), .scopes = &.{"syn-b"}, .writes = false, .trusted = true, .admin = true, .person = null, .created_ms = 2, .revoked_ms = 9 },
    };
    const text = try render(aa, &seats);
    try std.testing.expect(std.mem.indexOf(u8, text, "zm_a") == null);
    var t = try parse(a, text);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 2), t.seats.len);
    const v = t.verify("zm_a");
    try std.testing.expect(v == .ok);
    try std.testing.expectEqualStrings("seat-a", v.ok.name);
    try std.testing.expect(v.ok.writes and !v.ok.trusted and !v.ok.admin);
    try std.testing.expectEqualStrings("household", v.ok.scopes[1]);
    try std.testing.expect(t.verify("zm_b") == .revoked);
    try std.testing.expect(t.verify("zm_c") == .unknown);
    try std.testing.expect(t.verify("") == .unknown);
    try std.testing.expectError(error.BadTokenFile, parse(a, "x\tzz\tsyn\t-\t-\t1\t-\n"));
    try std.testing.expectError(error.BadTokenFile, parse(a, "x\t" ++ "0000000000000000000000000000000000000000000000000000000000000000" ++ "\tSYN\t-\t-\t1\t-\n"));
}
