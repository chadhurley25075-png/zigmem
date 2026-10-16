//! HTTP embedder client: our local nomic-embed-text-v1.5 (768-d). Two wire formats — the fastembed proxy
//! (`POST /embed {"inputs":[..]}` → `[[..]]`, the dev box :8081, the query path) and Ollama (`POST /api/embed`, used for the
//! bulk import; same model, cosine 0.9999996 between them, probed 10/12). nomic task prefixes are the caller's job.
const std = @import("std");
const http = @import("http.zig");
const jsonw = @import("jsonw.zig");

pub const Format = enum { proxy, ollama };

pub const Embedder = struct {
    url: []const u8 = "http://127.0.0.1:8081/embed",
    fmt: Format = .proxy,
    model: []const u8 = "nomic-embed-text",
    leash: http.Leash = .{ .connect_ms = 500, .read_ms = 10_000 },

    /// Model identity, not the URL: both servers carry the same weights; a different model means a reindex.
    pub const fingerprint = "nomic-embed-text-v1.5|768";

    /// One vector per text (owned by `a`). Any transport/shape failure is an error; callers decide what "down" means.
    pub fn embed(e: Embedder, a: std.mem.Allocator, texts: []const []const u8) ![][]f32 {
        var body: std.ArrayList(u8) = .empty;
        switch (e.fmt) {
            .proxy => try body.appendSlice(a, "{\"inputs\":["),
            .ollama => {
                try body.appendSlice(a, "{\"model\":");
                try jsonw.str(a, &body, e.model);
                try body.appendSlice(a, ",\"keep_alive\":\"24h\",\"input\":[");
            },
        }
        for (texts, 0..) |t, i| {
            if (i > 0) try body.append(a, ',');
            try jsonw.str(a, &body, t);
        }
        try body.appendSlice(a, "]}");
        const resp = try http.postJson(a, e.url, body.items, e.leash, 256 << 20);
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, resp, .{});
        const rows = switch (e.fmt) {
            .proxy => v,
            .ollama => if (v == .object) (v.object.get("embeddings") orelse return error.BadEmbedResponse) else return error.BadEmbedResponse,
        };
        if (rows != .array or rows.array.items.len != texts.len) return error.BadEmbedResponse;
        const out = try a.alloc([]f32, texts.len);
        for (rows.array.items, 0..) |r, i| {
            if (r != .array or r.array.items.len == 0) return error.BadEmbedResponse;
            out[i] = try a.alloc(f32, r.array.items.len);
            for (r.array.items, 0..) |x, j| out[i][j] = @floatCast(jsonw.num(x) orelse return error.BadEmbedResponse);
        }
        return out;
    }
};
