//! Hit shapes the hub renders. The phase-4 BM25 stub that used to live here is GONE (integration): every search now
//! goes through retrieval.zig (phase-3 hybrid recall + the phase-5 household row gate + the phase-3 privacy gates).
//! There is no fallback path back to plain BM25.
pub const Kind = enum { atoms, turns };

pub const Hit = struct {
    kind: Kind,
    id: i64,
    scope: []const u8,
    subject: []const u8 = "",
    type: []const u8 = "",
    role: []const u8 = "",
    session: []const u8 = "",
    text: []const u8,
    /// Higher = better (atoms: the normalised fused rank; turns: -bm25).
    score: f64,
    valid_from: ?[]const u8 = null,
    ts_ms: i64 = 0,
};
