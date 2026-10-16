//! Flat vector store: unit-normalised f32 blobs in SQLite, an in-memory copy, SIMD dot-product top-k with a scope mask.
const std = @import("std");
const root = @import("store.zig");
const Store = root.Store;
const Scope = root.Scope;
const Blob = root.sqlite.Blob;

pub const Kind = enum { l0, atom, scene };
pub const max_dims = 4096;
const lanes = 16;
const V = @Vector(lanes, f32);

pub fn normalize(dst: []f32, src: []const f32) void {
    var ss: f32 = 0;
    for (src) |x| ss += x * x;
    const inv: f32 = if (ss > 0) 1.0 / @sqrt(ss) else 0;
    for (dst, src) |*d, x| d.* = x * inv;
}

/// Store an embedding for a row (replaces a previous one for the same row). Dims are pinned by the first write
/// (meta `embed_dims`); a different size is refused — a new embedder means a reindex, not a mix.
pub fn put(st: *Store, kind: Kind, row_id: i64, emb: []const f32) !void {
    if (emb.len == 0 or emb.len > max_dims) return error.BadDims;
    const pinned = try st.getMeta(st.gpa, "embed_dims");
    defer if (pinned) |p| st.gpa.free(p);
    if (pinned) |p| {
        if ((std.fmt.parseInt(usize, p, 10) catch 0) != emb.len) return error.DimsMismatch;
    } else {
        var b: [16]u8 = undefined;
        try st.setMeta("embed_dims", try std.fmt.bufPrint(&b, "{d}", .{emb.len}));
    }
    const buf = try st.gpa.alloc(f32, emb.len);
    defer st.gpa.free(buf);
    normalize(buf, emb);
    try st.db.run("INSERT OR REPLACE INTO vec(kind, row_id, dims, emb) VALUES (?1,?2,?3,?4)", .{
        @tagName(kind), row_id, emb.len, Blob{ .bytes = std.mem.sliceAsBytes(buf) },
    });
}

pub const Hit = struct { row_id: i64, score: f32 };

/// In-memory copy of one kind's vectors with each row's scope interned. Build with `load`, keep current with `add`.
pub const Index = struct {
    kind: Kind,
    dims: usize = 0,
    ids: std.ArrayList(i64) = .empty,
    scope_of: std.ArrayList(u16) = .empty,
    data: std.ArrayList(f32) = .empty,
    scope_names: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Index, gpa: std.mem.Allocator) void {
        for (self.scope_names.items) |n| gpa.free(n);
        self.scope_names.deinit(gpa);
        self.ids.deinit(gpa);
        self.scope_of.deinit(gpa);
        self.data.deinit(gpa);
    }

    fn intern(self: *Index, gpa: std.mem.Allocator, scope: []const u8) !u16 {
        for (self.scope_names.items, 0..) |n, i| if (std.mem.eql(u8, n, scope)) return @intCast(i);
        if (self.scope_names.items.len >= std.math.maxInt(u16)) return error.TooManyScopes;
        try self.scope_names.append(gpa, try gpa.dupe(u8, scope));
        return @intCast(self.scope_names.items.len - 1);
    }

    /// Add an already-normalised vector.
    pub fn add(self: *Index, gpa: std.mem.Allocator, row_id: i64, scope: []const u8, unit: []const f32) !void {
        if (self.dims == 0) self.dims = unit.len;
        if (unit.len != self.dims) return error.DimsMismatch;
        try self.data.appendSlice(gpa, unit);
        try self.ids.append(gpa, row_id);
        try self.scope_of.append(gpa, try self.intern(gpa, scope));
    }

    pub fn load(st: *Store, gpa: std.mem.Allocator, kind: Kind) !Index {
        var ix: Index = .{ .kind = kind };
        errdefer ix.deinit(gpa);
        const sql = switch (kind) {
            .l0 => "SELECT v.row_id, v.emb, t.scope FROM vec v JOIN l0 t ON t.id = v.row_id WHERE v.kind = 'l0' ORDER BY v.row_id",
            .atom => "SELECT v.row_id, v.emb, t.scope FROM vec v JOIN atoms t ON t.id = v.row_id WHERE v.kind = 'atom' ORDER BY v.row_id",
            .scene => "SELECT v.row_id, v.emb, t.scope FROM vec v JOIN scenes t ON t.id = v.row_id WHERE v.kind = 'scene' ORDER BY v.row_id",
        };
        var s = try st.db.prepare(sql);
        defer s.deinit();
        var tmp: std.ArrayList(f32) = .empty;
        defer tmp.deinit(gpa);
        while (try s.step()) {
            const raw = s.blob(1);
            if (raw.len % 4 != 0) return error.CorruptVector;
            try tmp.resize(gpa, raw.len / 4);
            @memcpy(std.mem.sliceAsBytes(tmp.items), raw);
            try ix.add(gpa, s.int(0), s.text(2), tmp.items);
        }
        return ix;
    }

    /// Top-k by cosine (dot of unit vectors) among rows whose scope is in `scope`. Best first.
    pub fn topK(self: *const Index, gpa: std.mem.Allocator, scope: Scope, query: []const f32, k: usize) ![]Hit {
        try scope.check();
        if (self.dims == 0 or k == 0) return gpa.alloc(Hit, 0);
        if (query.len != self.dims) return error.DimsMismatch;
        const mask = try gpa.alloc(bool, self.scope_names.items.len);
        defer gpa.free(mask);
        for (self.scope_names.items, mask) |n, *m| m.* = scope.has(n);
        const q = try gpa.alloc(f32, self.dims);
        defer gpa.free(q);
        normalize(q, query);
        var best = try gpa.alloc(Hit, k);
        defer gpa.free(best);
        var n: usize = 0;
        for (self.ids.items, self.scope_of.items, 0..) |id, sc, row| {
            if (!mask[sc]) continue;
            const d = dot(q, self.data.items[row * self.dims ..][0..self.dims]);
            if (n == k and d <= best[k - 1].score) continue;
            var j = if (n < k) n else k - 1;
            if (n < k) n += 1;
            while (j > 0 and best[j - 1].score < d) : (j -= 1) best[j] = best[j - 1];
            best[j] = .{ .row_id = id, .score = d };
        }
        return gpa.dupe(Hit, best[0..n]);
    }
};

fn dot(a: []const f32, b: []const f32) f32 {
    var acc0: V = @splat(0);
    var acc1: V = @splat(0);
    var i: usize = 0;
    while (i + 2 * lanes <= a.len) : (i += 2 * lanes) {
        acc0 += @as(V, a[i..][0..lanes].*) * @as(V, b[i..][0..lanes].*);
        acc1 += @as(V, a[i + lanes ..][0..lanes].*) * @as(V, b[i + lanes ..][0..lanes].*);
    }
    var sum = @reduce(.Add, acc0 + acc1);
    while (i < a.len) : (i += 1) sum += a[i] * b[i];
    return sum;
}
