//! Thin wrapper over the vendored SQLite amalgamation (bound with translate-c): open, exec, prepare, bind, step, read.
const std = @import("std");
pub const c = @import("c");

pub const Error = error{ Sqlite, Busy, Constraint, Abort, NoMem, Corrupt };

fn mapRc(rc: c_int) Error {
    return switch (rc & 0xff) {
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.Busy,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_ABORT => error.Abort,
        c.SQLITE_NOMEM => error.NoMem,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => error.Corrupt,
        else => error.Sqlite,
    };
}

/// A BLOB parameter (plain `[]const u8` binds as TEXT).
pub const Blob = struct { bytes: []const u8 };
/// SQL NULL parameter.
pub const Null = struct {};

pub const Db = struct {
    h: *c.sqlite3,

    pub fn open(path: [:0]const u8, read_only: bool) Error!Db {
        var h: ?*c.sqlite3 = null;
        const mode: c_int = if (read_only) c.SQLITE_OPEN_READONLY else c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
        const rc = c.sqlite3_open_v2(path.ptr, &h, mode | c.SQLITE_OPEN_NOMUTEX, null);
        if (rc != c.SQLITE_OK) {
            if (h) |p| _ = c.sqlite3_close_v2(p);
            return mapRc(rc);
        }
        _ = c.sqlite3_extended_result_codes(h, 1);
        _ = c.sqlite3_busy_timeout(h, 5000);
        return .{ .h = h.? };
    }

    pub fn close(self: Db) void {
        _ = c.sqlite3_close_v2(self.h);
    }

    pub fn errmsg(self: Db) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.h));
    }

    /// Run one or more statements with no parameters and no rows wanted.
    pub fn exec(self: Db, sql: [:0]const u8) Error!void {
        const rc = c.sqlite3_exec(self.h, sql.ptr, null, null, null);
        if (rc != c.SQLITE_OK) return mapRc(rc);
    }

    pub fn prepare(self: Db, sql: []const u8) Error!Stmt {
        var s: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.h, sql.ptr, @intCast(sql.len), &s, null);
        if (rc != c.SQLITE_OK) {
            std.log.warn("sqlite prepare: {s}", .{self.errmsg()});
            return mapRc(rc);
        }
        return .{ .s = s orelse return error.Sqlite };
    }

    /// Prepare, bind `args`, step to completion, finalize.
    pub fn run(self: Db, sql: []const u8, args: anytype) Error!void {
        var st = try self.prepare(sql);
        defer st.deinit();
        try st.bindAll(args);
        while (try st.step()) {}
    }

    /// Single integer result (first column of first row), or null when no row.
    pub fn oneInt(self: Db, sql: []const u8, args: anytype) Error!?i64 {
        var st = try self.prepare(sql);
        defer st.deinit();
        try st.bindAll(args);
        return if (try st.step()) st.int(0) else null;
    }

    pub fn changes(self: Db) i64 {
        return c.sqlite3_changes64(self.h);
    }

    pub fn lastId(self: Db) i64 {
        return c.sqlite3_last_insert_rowid(self.h);
    }
};

pub const Stmt = struct {
    s: *c.sqlite3_stmt,

    pub fn deinit(self: Stmt) void {
        _ = c.sqlite3_finalize(self.s);
    }

    pub fn reset(self: Stmt) void {
        _ = c.sqlite3_reset(self.s);
        _ = c.sqlite3_clear_bindings(self.s);
    }

    /// Bind one parameter (1-based). Text/blob use SQLITE_STATIC: the slice must outlive the step (callers reset first).
    pub fn bind(self: Stmt, i: c_int, v: anytype) Error!void {
        const T = @TypeOf(v);
        const rc: c_int = switch (@typeInfo(T)) {
            .int, .comptime_int => c.sqlite3_bind_int64(self.s, i, @intCast(v)),
            .float, .comptime_float => c.sqlite3_bind_double(self.s, i, v),
            .bool => c.sqlite3_bind_int64(self.s, i, @intFromBool(v)),
            .null => c.sqlite3_bind_null(self.s, i),
            .optional => if (v) |x| return self.bind(i, x) else c.sqlite3_bind_null(self.s, i),
            else => if (T == Blob)
                c.sqlite3_bind_blob64(self.s, i, v.bytes.ptr, v.bytes.len, null)
            else if (T == Null)
                c.sqlite3_bind_null(self.s, i)
            else blk: {
                const sl: []const u8 = v;
                break :blk c.sqlite3_bind_text64(self.s, i, sl.ptr, sl.len, null, c.SQLITE_UTF8);
            },
        };
        if (rc != c.SQLITE_OK) return mapRc(rc);
    }

    pub fn bindAll(self: Stmt, args: anytype) Error!void {
        inline for (args, 1..) |a, i| try self.bind(@intCast(i), a);
    }

    /// true = a row is ready, false = done.
    pub fn step(self: Stmt) Error!bool {
        const rc = c.sqlite3_step(self.s);
        return switch (rc) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => mapRc(rc),
        };
    }

    pub fn int(self: Stmt, col: c_int) i64 {
        return c.sqlite3_column_int64(self.s, col);
    }

    pub fn float(self: Stmt, col: c_int) f64 {
        return c.sqlite3_column_double(self.s, col);
    }

    pub fn isNull(self: Stmt, col: c_int) bool {
        return c.sqlite3_column_type(self.s, col) == c.SQLITE_NULL;
    }

    /// Borrowed until the next step/reset/finalize.
    pub fn text(self: Stmt, col: c_int) []const u8 {
        const p = c.sqlite3_column_text(self.s, col) orelse return "";
        const n: usize = @intCast(c.sqlite3_column_bytes(self.s, col));
        return p[0..n];
    }

    pub fn blob(self: Stmt, col: c_int) []const u8 {
        const p = c.sqlite3_column_blob(self.s, col) orelse return "";
        const n: usize = @intCast(c.sqlite3_column_bytes(self.s, col));
        return @as([*]const u8, @ptrCast(p))[0..n];
    }
};
