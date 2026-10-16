//! Reciprocal-rank fusion (k = 60, once, here) with a NORMALISED fused score in (0, 1]: 1.0 = rank 1 in both engines,
//! 0.5 = rank 1 in one engine only. The floor in recall.zig is applied to this value in every path.
const std = @import("std");

pub const k_rrf: f64 = 60;

pub const Cand = struct {
    id: i64,
    fts_rank: ?u32 = null, // 1-based
    vec_rank: ?u32 = null,
    bm25n: f64 = 0, // r/(1+r) of the positive bm25 magnitude
    cos: f32 = -1,
    fused: f64 = 0,
    priority: i64 = 50,
};

pub fn fusedOf(c: Cand) f64 {
    var s: f64 = 0;
    if (c.fts_rank) |r| s += 1.0 / (k_rrf + @as(f64, @floatFromInt(r)));
    if (c.vec_rank) |r| s += 1.0 / (k_rrf + @as(f64, @floatFromInt(r)));
    return s / (2.0 / (k_rrf + 1.0));
}

/// Priority nudges rank without swamping relevance: ±10 % at the 0/100 extremes.
pub fn withPriority(fused: f64, priority: i64) f64 {
    return fused * (1.0 + @as(f64, @floatFromInt(std.math.clamp(priority, 0, 100) - 50)) / 500.0);
}

pub fn byFusedDesc(_: void, x: Cand, y: Cand) bool {
    if (x.fused != y.fused) return x.fused > y.fused;
    return x.id > y.id; // newer first on ties: deterministic
}

test "rrf normalisation" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), fusedOf(.{ .id = 1, .fts_rank = 1, .vec_rank = 1 }), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), fusedOf(.{ .id = 1, .vec_rank = 1 }), 1e-12);
}
