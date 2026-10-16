//! JSON for the hub: a small output builder (valid UTF-8 out, always) and typed readers over std.json.Value.
//! Readers only look up the keys a route names; every other key in a request body is ignored (dropped).
const std = @import("std");
pub const Value = std.json.Value;

pub const Error = error{ BadJson, BadType, OutOfMemory };

/// Parse a request body into a Value tree that lives in `a` (an arena). std.json's Value parser is iterative,
/// so deep nesting costs heap (bounded by the body limit), never stack.
pub fn parse(a: std.mem.Allocator, body: []const u8) Error!Value {
    return std.json.parseFromSliceLeaky(Value, a, body, .{ .duplicate_field_behavior = .use_last }) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadJson,
    };
}

fn field(v: Value, k: []const u8) ?Value {
    if (v != .object) return null;
    const x = v.object.get(k) orelse return null;
    return if (x == .null) null else x;
}

pub fn str(v: Value, k: []const u8) Error!?[]const u8 {
    const x = field(v, k) orelse return null;
    return if (x == .string) x.string else error.BadType;
}

pub fn int(v: Value, k: []const u8) Error!?i64 {
    const x = field(v, k) orelse return null;
    return switch (x) {
        .integer => |n| n,
        .float => |f| if (@floor(f) == f and @abs(f) < 9.0e15) @intFromFloat(f) else error.BadType,
        else => error.BadType,
    };
}

pub fn boolean(v: Value, k: []const u8) Error!?bool {
    const x = field(v, k) orelse return null;
    return if (x == .bool) x.bool else error.BadType;
}

pub fn array(v: Value, k: []const u8) Error!?[]Value {
    const x = field(v, k) orelse return null;
    return if (x == .array) x.array.items else error.BadType;
}

pub fn object(v: Value, k: []const u8) Error!?Value {
    const x = field(v, k) orelse return null;
    return if (x == .object) x else error.BadType;
}

/// JSON string literal. Invalid UTF-8 becomes U+FFFD, so the output is always valid JSON.
pub fn writeString(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(a, '"');
    var i: usize = 0;
    while (i < s.len) {
        const ch = s[i];
        if (ch < 0x80) {
            switch (ch) {
                '"' => try out.appendSlice(a, "\\\""),
                '\\' => try out.appendSlice(a, "\\\\"),
                '\n' => try out.appendSlice(a, "\\n"),
                '\r' => try out.appendSlice(a, "\\r"),
                '\t' => try out.appendSlice(a, "\\t"),
                0...8, 11, 12, 14...0x1f, 0x7f => try out.print(a, "\\u{x:0>4}", .{ch}),
                else => try out.append(a, ch),
            }
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(ch) catch 0;
        if (n == 0 or i + n > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + n])) {
            try out.appendSlice(a, "\\ufffd");
            i += 1;
            continue;
        }
        try out.appendSlice(a, s[i .. i + n]);
        i += n;
    }
    try out.append(a, '"');
}

/// `{"k":v,...}` builder writing into one buffer.
pub const Obj = struct {
    a: std.mem.Allocator,
    b: *std.ArrayList(u8),
    first: bool = true,

    pub fn begin(a: std.mem.Allocator, b: *std.ArrayList(u8)) !Obj {
        try b.append(a, '{');
        return .{ .a = a, .b = b };
    }
    fn key(o: *Obj, k: []const u8) !void {
        if (!o.first) try o.b.append(o.a, ',');
        o.first = false;
        try writeString(o.a, o.b, k);
        try o.b.append(o.a, ':');
    }
    pub fn s(o: *Obj, k: []const u8, v: ?[]const u8) !void {
        try o.key(k);
        if (v) |x| try writeString(o.a, o.b, x) else try o.b.appendSlice(o.a, "null");
    }
    pub fn n(o: *Obj, k: []const u8, v: ?i64) !void {
        try o.key(k);
        if (v) |x| try o.b.print(o.a, "{d}", .{x}) else try o.b.appendSlice(o.a, "null");
    }
    pub fn f(o: *Obj, k: []const u8, v: f64) !void {
        try o.key(k);
        if (std.math.isFinite(v)) try o.b.print(o.a, "{d:.4}", .{v}) else try o.b.appendSlice(o.a, "null");
    }
    pub fn b_(o: *Obj, k: []const u8, v: bool) !void {
        try o.key(k);
        try o.b.appendSlice(o.a, if (v) "true" else "false");
    }
    /// `v` must already be valid JSON.
    pub fn raw(o: *Obj, k: []const u8, v: []const u8) !void {
        try o.key(k);
        try o.b.appendSlice(o.a, v);
    }
    pub fn end(o: *Obj) !void {
        try o.b.append(o.a, '}');
    }
};

/// A one-field error body: {"error": msg}.
pub fn errBody(a: std.mem.Allocator, msg: []const u8) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    var o = try Obj.begin(a, &b);
    try o.s("error", msg);
    try o.end();
    return b.items;
}

test "writeString escapes controls and replaces invalid UTF-8" {
    const a = std.testing.allocator;
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(a);
    try writeString(a, &b, "a\"\\\n\x01\xff\xc3\xa9");
    try std.testing.expectEqualStrings("\"a\\\"\\\\\\n\\u0001\\ufffd\xc3\xa9\"", b.items);
}

test "typed readers: wrong type is an error, null and missing are absent, unknown keys ignored" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "{\"q\":\"x\",\"n\":3,\"z\":null,\"w\":[1],\"evil\":{\"seat\":\"other\"}}");
    try std.testing.expectEqualStrings("x", (try str(v, "q")).?);
    try std.testing.expectEqual(@as(?i64, 3), try int(v, "n"));
    try std.testing.expectEqual(@as(?[]const u8, null), try str(v, "z"));
    try std.testing.expectError(error.BadType, str(v, "n"));
    try std.testing.expectError(error.BadType, int(v, "q"));
    try std.testing.expectError(error.BadJson, parse(arena.allocator(), "{\"a\":"));
    const deep = try arena.allocator().alloc(u8, 200_000);
    @memset(deep, '[');
    try std.testing.expectError(error.BadJson, parse(arena.allocator(), deep));
}
