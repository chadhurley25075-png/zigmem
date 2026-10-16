//! Minimal OpenAI-compatible chat client (non-stream) over raw Linux sockets. Connects only to allow.zig endpoints.
//! No DNS, no TLS, no proxy env, no other outbound path exists in src/extract/.
const std = @import("std");
const linux = std.os.linux;
const allow = @import("allow.zig");

pub const Msg = struct { role: []const u8, content: []const u8 };

pub const Reply = struct {
    content: []const u8,
    reasoning_bytes: usize,
    prompt_tokens: i64,
    completion_tokens: i64,
    finish: []const u8,
    ms: f64,
};

/// Per-process counters the gate reports. `canaries`: strings that must never appear in any request body.
pub const Client = struct {
    connects: u32 = 0,
    refused: u32 = 0,
    requests: u32 = 0,
    canaries: []const []const u8 = &.{},
    canary_hits: u32 = 0,
    /// Fixed seed for reproducibility (temperature is always 0).
    seed: i64 = 7,
    /// Unit tests only: answer from a function instead of the network (the allowlist is still checked first).
    stub: ?Stub = null,

    pub const Stub = struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, body: []const u8) []const u8 };

    /// One chat call. Everything allocated lives in `a` (use an arena per call).
    pub fn chat(c: *Client, a: std.mem.Allocator, ep: allow.Endpoint, msgs: []const Msg) !Reply {
        const body = try requestBody(a, ep, msgs, c.seed);
        for (c.canaries) |k| if (k.len > 0 and std.mem.indexOf(u8, body, k) != null) {
            c.canary_hits += 1;
        };
        if (c.stub) |st| {
            if (!allow.permitted(ep.ip, ep.port)) {
                c.refused += 1;
                return error.NotAllowed;
            }
            c.requests += 1;
            return .{ .content = st.f(st.ctx, body), .reasoning_bytes = 0, .prompt_tokens = 0, .completion_tokens = 0, .finish = "stop", .ms = 0 };
        }
        const t0 = nowNs();
        const raw = try c.post(a, ep, "/v1/chat/completions", body);
        const t1 = nowNs();
        var r = try parseReply(a, raw);
        r.ms = @as(f64, @floatFromInt(t1 - t0)) / 1e6;
        return r;
    }

    fn post(c: *Client, a: std.mem.Allocator, ep: allow.Endpoint, path: []const u8, body: []const u8) ![]const u8 {
        if (!allow.permitted(ep.ip, ep.port)) {
            c.refused += 1;
            return error.NotAllowed;
        }
        var hb: [32]u8 = undefined;
        const head = try std.fmt.allocPrint(a, "POST {s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\n" ++
            "Accept: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ path, ep.hostHeader(&hb), body.len });
        const src = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(src) != .SUCCESS) return error.SocketFailed;
        const fd: i32 = @intCast(src);
        defer _ = linux.close(fd);
        const tv: linux.timeval = .{ .sec = @intCast(ep.timeout_s), .usec = 0 };
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
        const one: c_int = 1;
        _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(c_int));
        var sa: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, ep.port), .addr = @bitCast(ep.ip) };
        c.connects += 1;
        if (linux.errno(linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.ConnectFailed;
        try sendAll(fd, head);
        try sendAll(fd, body);
        c.requests += 1;
        var resp: std.ArrayList(u8) = .empty;
        var buf: [16384]u8 = undefined;
        while (true) {
            const rc = linux.read(fd, &buf, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                .AGAIN => return error.Timeout,
                else => return error.ReadFailed,
            }
            if (rc == 0) break;
            if (resp.items.len + rc > 8 << 20) return error.ResponseTooLarge;
            try resp.appendSlice(a, buf[0..rc]);
        }
        return httpBody(a, resp.items);
    }
};

fn sendAll(fd: i32, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = linux.sendto(fd, data[off..].ptr, data.len - off, linux.MSG.NOSIGNAL, null, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => {},
            else => return error.WriteFailed,
        }
    }
}

pub fn nowNs() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Status line + headers → body (de-chunked if needed). Non-2xx → error.HttpStatus.
pub fn httpBody(a: std.mem.Allocator, resp: []const u8) ![]const u8 {
    const he = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.BadResponse;
    const head = resp[0..he];
    const body = resp[he + 4 ..];
    if (head.len < 12 or !std.mem.startsWith(u8, head, "HTTP/1.")) return error.BadResponse;
    const code = std.fmt.parseInt(u16, head[9..12], 10) catch return error.BadResponse;
    var chunked = false;
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |l| {
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, l[0..colon], " "), "transfer-encoding") and
            std.ascii.findIgnoreCase(l[colon + 1 ..], "chunked") != null) chunked = true;
    }
    if (code < 200 or code > 299) return error.HttpStatus;
    if (!chunked) return body;
    var out: std.ArrayList(u8) = .empty;
    var p: usize = 0;
    while (true) {
        const le = std.mem.indexOfPos(u8, body, p, "\r\n") orelse return error.BadChunk;
        const line = body[p..le];
        const size_s = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, ';') orelse line.len], " ");
        const size = std.fmt.parseInt(usize, size_s, 16) catch return error.BadChunk;
        p = le + 2;
        if (size == 0) break;
        if (p + size > body.len) return error.BadChunk;
        try out.appendSlice(a, body[p .. p + size]);
        p += size + 2;
    }
    return out.items;
}

/// JSON string escape (UTF-8 passes through; control bytes become \u00XX).
pub fn writeJsonString(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(a, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        0...8, 11, 12, 14...0x1f, 0x7f => try out.print(a, "\\u{x:0>4}", .{ch}),
        else => try out.append(a, ch),
    };
    try out.append(a, '"');
}

/// The request body. Never carries reasoning_effort (secondary law); thinking-off kwargs only for the primary engine.
pub fn requestBody(a: std.mem.Allocator, ep: allow.Endpoint, msgs: []const Msg, seed: i64) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "{\"model\":");
    try writeJsonString(a, &out, ep.model);
    try out.appendSlice(a, ",\"messages\":[");
    for (msgs, 0..) |m, i| {
        if (i > 0) try out.append(a, ',');
        try out.appendSlice(a, "{\"role\":");
        try writeJsonString(a, &out, m.role);
        try out.appendSlice(a, ",\"content\":");
        try writeJsonString(a, &out, m.content);
        try out.append(a, '}');
    }
    try out.print(a, "],\"temperature\":0,\"seed\":{d},\"max_tokens\":{d},\"stream\":false", .{ seed, ep.max_tokens });
    if (ep.thinking_off) try out.appendSlice(a, ",\"chat_template_kwargs\":{\"enable_thinking\":false}");
    try out.append(a, '}');
    return out.items;
}

fn getPath(v: std.json.Value, comptime keys: []const []const u8) ?std.json.Value {
    var cur = v;
    inline for (keys) |k| {
        if (cur != .object) return null;
        cur = cur.object.get(k) orelse return null;
    }
    return cur;
}

fn intOr0(v: ?std.json.Value) i64 {
    return if (v) |x| (if (x == .integer) x.integer else 0) else 0;
}

pub fn parseReply(a: std.mem.Allocator, raw: []const u8) !Reply {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return error.BadReplyJson;
    const choices = getPath(v, &.{"choices"}) orelse return error.NoChoices;
    if (choices != .array or choices.array.items.len == 0) return error.NoChoices;
    const ch = choices.array.items[0];
    const content = getPath(ch, &.{ "message", "content" });
    const reas = getPath(ch, &.{ "message", "reasoning" }) orelse getPath(ch, &.{ "message", "reasoning_content" });
    const fin = getPath(ch, &.{"finish_reason"});
    return .{
        .content = if (content) |c| (if (c == .string) c.string else "") else "",
        .reasoning_bytes = if (reas) |r| (if (r == .string) r.string.len else 0) else 0,
        .prompt_tokens = intOr0(getPath(v, &.{ "usage", "prompt_tokens" })),
        .completion_tokens = intOr0(getPath(v, &.{ "usage", "completion_tokens" })),
        .finish = if (fin) |f| (if (f == .string) f.string else "") else "",
        .ms = 0,
    };
}

test "request body: no reasoning_effort ever; thinking kwargs only on primary; escapes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Msg{ .{ .role = "system", .content = "x\"y\\z\n\x01" }, .{ .role = "user", .content = "café ☕" } };
    const b1 = try requestBody(a, allow.primary, &msgs, 7);
    const b2 = try requestBody(a, allow.secondary, &msgs, 7);
    for ([_][]const u8{ b1, b2 }) |b| {
        try std.testing.expect(std.mem.indexOf(u8, b, "reasoning_effort") == null);
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, b, .{});
        try std.testing.expectEqualStrings("x\"y\\z\n\x01", v.object.get("messages").?.array.items[0].object.get("content").?.string);
        try std.testing.expectEqualStrings("café ☕", v.object.get("messages").?.array.items[1].object.get("content").?.string);
    }
    try std.testing.expect(std.mem.indexOf(u8, b1, "enable_thinking") != null);
    try std.testing.expect(std.mem.indexOf(u8, b2, "chat_template_kwargs") == null);
}

test "client refuses a non-allowlisted endpoint before any socket" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var c: Client = .{};
    var evil = allow.primary;
    evil.ip = .{ 8, 8, 8, 8 };
    try std.testing.expectError(error.NotAllowed, c.chat(arena.allocator(), evil, &.{.{ .role = "user", .content = "hi" }}));
    evil = allow.secondary;
    evil.port = 18081;
    try std.testing.expectError(error.NotAllowed, c.chat(arena.allocator(), evil, &.{.{ .role = "user", .content = "hi" }}));
    try std.testing.expectEqual(@as(u32, 0), c.connects);
    try std.testing.expectEqual(@as(u32, 2), c.refused);
}

test "http body: content-length and chunked, non-2xx is an error" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("{}", try httpBody(a, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"));
    try std.testing.expectEqualStrings("hello world", try httpBody(a, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"));
    try std.testing.expectError(error.HttpStatus, httpBody(a, "HTTP/1.1 409 Conflict\r\n\r\nbusy"));
    const r = try parseReply(a, "{\"choices\":[{\"message\":{\"content\":\"{\\\"memories\\\":[]}\",\"reasoning\":\"abc\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":3}}");
    try std.testing.expectEqualStrings("{\"memories\":[]}", r.content);
    try std.testing.expectEqual(@as(usize, 3), r.reasoning_bytes);
}
