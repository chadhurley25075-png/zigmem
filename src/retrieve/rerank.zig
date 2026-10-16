//! Optional reranker (Qwen3-Reranker-0.6B, `POST /rerank {"query","docs"}` → `{"scores":[..]}`): the LAN reranker first
//! (connect 0.5 s / read 3 s), the dev box :18098 second (read 8 s) — the same leash as rerank_lane.py. Both down → `.down`, and
//! recall switches to its lower-injection path (≤ 2 rows, both engines must agree).
const std = @import("std");
const http = @import("http.zig");
const jsonw = @import("jsonw.zig");

pub const Used = enum { primary, fallback, down, off };

pub const Reranker = struct {
    primary: ?[]const u8 = "http://192.0.2.10:18098/rerank",
    fallback: ?[]const u8 = "http://127.0.0.1:18098/rerank",
    primary_leash: http.Leash = .{ .connect_ms = 500, .read_ms = 3000 },
    fallback_leash: http.Leash = .{ .connect_ms = 500, .read_ms = 8000 },
    /// Offline tests only: a judge with no network.
    fake: ?*const fn (query: []const u8, doc: []const u8) f32 = null,

    pub const Result = struct { scores: ?[]f32, used: Used };

    pub fn score(r: Reranker, a: std.mem.Allocator, query: []const u8, docs: []const []const u8) !Result {
        if (docs.len == 0) return .{ .scores = &.{}, .used = .off };
        if (r.fake) |f| {
            const out = try a.alloc(f32, docs.len);
            for (docs, 0..) |d, i| out[i] = f(query, d);
            return .{ .scores = out, .used = .primary };
        }
        var body: std.ArrayList(u8) = .empty;
        try body.appendSlice(a, "{\"query\":");
        try jsonw.str(a, &body, query);
        try body.appendSlice(a, ",\"docs\":[");
        for (docs, 0..) |d, i| {
            if (i > 0) try body.append(a, ',');
            try jsonw.str(a, &body, d);
        }
        try body.appendSlice(a, "]}");
        if (r.primary) |u| if (one(a, u, body.items, docs.len, r.primary_leash)) |s| return .{ .scores = s, .used = .primary };
        if (r.fallback) |u| if (one(a, u, body.items, docs.len, r.fallback_leash)) |s| return .{ .scores = s, .used = .fallback };
        return .{ .scores = null, .used = if (r.primary == null and r.fallback == null) .off else .down };
    }

    fn one(a: std.mem.Allocator, url: []const u8, body: []const u8, n: usize, leash: http.Leash) ?[]f32 {
        const resp = http.postJson(a, url, body, leash, 16 << 20) catch return null;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, resp, .{}) catch return null;
        if (v != .object) return null;
        const sc = v.object.get("scores") orelse return null;
        if (sc != .array or sc.array.items.len != n) return null;
        const out = a.alloc(f32, n) catch return null;
        for (sc.array.items, 0..) |x, i| out[i] = @floatCast(jsonw.num(x) orelse return null);
        return out;
    }
};
