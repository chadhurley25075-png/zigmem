//! Tokenizer-free chunking (byte budget, sentence snapping, UTF-8 safe, small overlap) and the warm-up scheduler.
const std = @import("std");

/// Conservative token estimate for budgeting without a tokenizer: ~3.2 bytes/token for English+UTF-8.
pub fn estTokens(bytes: usize) usize {
    return (bytes * 10 + 31) / 32;
}

fn isBoundary(s: []const u8, i: usize) bool {
    // i is the index just after a sentence end: ". ", "? ", "! ", "\n"
    if (i == 0 or i > s.len) return false;
    const p = s[i - 1];
    if (p == '\n') return true;
    if ((p == '.' or p == '?' or p == '!') and (i == s.len or s[i] == ' ' or s[i] == '\n')) return true;
    return false;
}

fn utf8Back(s: []const u8, i: usize) usize {
    var j = i;
    while (j > 0 and j < s.len and (s[j] & 0xC0) == 0x80) j -= 1;
    return j;
}

/// Split `s` into pieces of at most `max` bytes, cut at the last sentence boundary inside the budget when one exists
/// (else at a space, else at a UTF-8 boundary). Each later piece starts with up to `overlap` bytes of the previous
/// piece's tail (snapped forward to a word start) so a fact straddling a cut is seen whole once. Slices point into `s`.
pub fn split(a: std.mem.Allocator, s: []const u8, max: usize, overlap: usize) ![]const []const u8 {
    std.debug.assert(max > overlap * 2 and max >= 16);
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    while (start < s.len) {
        if (s.len - start <= max) {
            try out.append(a, s[start..]);
            break;
        }
        const lim = start + max;
        var cut: usize = 0;
        var i = lim;
        while (i > start + max / 2) : (i -= 1) if (isBoundary(s, i)) {
            cut = i;
            break;
        };
        if (cut == 0) {
            if (std.mem.lastIndexOfScalar(u8, s[start + max / 2 .. lim], ' ')) |sp| cut = start + max / 2 + sp + 1;
        }
        if (cut == 0) cut = utf8Back(s, lim);
        if (cut <= start) cut = lim; // pathological: a single huge code point run
        try out.append(a, s[start..cut]);
        var next = if (cut > overlap) cut - overlap else cut;
        if (next <= start) next = cut;
        next = utf8Back(s, next);
        while (next < cut and s[next] != ' ') next += 1;
        if (next < cut) next += 1;
        start = if (next < cut) next else cut;
    }
    return out.items;
}

/// Warm-up cadence (SPEC §1.2): extraction batches of 1, 2, 4, then every `n` turns; or on idle with anything pending.
pub const Sched = struct {
    n: u32 = 5,
    idle_ms: i64 = 600_000,
    runs: u32 = 0,
    pending: u32 = 0,
    last_turn_ms: i64 = 0,

    pub fn batch(s: Sched) u32 {
        if (s.runs >= 3) return s.n;
        return @min(s.n, @as(u32, 1) << @intCast(s.runs));
    }

    /// Record a captured turn; true = run extraction now over the pending turns.
    pub fn onTurn(s: *Sched, now_ms: i64) bool {
        s.pending += 1;
        s.last_turn_ms = now_ms;
        return s.pending >= s.batch();
    }

    pub fn onIdle(s: *Sched, now_ms: i64) bool {
        return s.pending > 0 and now_ms - s.last_turn_ms >= s.idle_ms;
    }

    pub fn ran(s: *Sched) void {
        s.pending = 0;
        s.runs += 1;
    }
};

test "split: covers all text, respects budget, UTF-8 safe, prefers sentence ends" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var txt: std.ArrayList(u8) = .empty;
    for (0..200) |i| try txt.print(a, "Sentence {d} talks about crème brûlée ☕ and nothing else. ", .{i});
    const s = txt.items;
    const parts = try split(a, s, 1000, 120);
    try std.testing.expect(parts.len > 5);
    var covered: usize = 0;
    for (parts) |p| {
        try std.testing.expect(p.len <= 1000);
        try std.testing.expect(std.unicode.utf8ValidateSlice(p));
        const off = @intFromPtr(p.ptr) - @intFromPtr(s.ptr);
        try std.testing.expect(off <= covered); // no gap
        covered = off + p.len;
    }
    try std.testing.expectEqual(s.len, covered);
    try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, parts[0], " "), "."));
    const one = try split(a, "short text.", 1000, 120);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    var cjk: std.ArrayList(u8) = .empty;
    for (0..700) |_| try cjk.appendSlice(a, "家");
    for (try split(a, cjk.items, 100, 20)) |p| try std.testing.expect(std.unicode.utf8ValidateSlice(p));
}

test "sched: warm-up 1, 2, 4, then N; idle flush" {
    var s: Sched = .{ .n = 5 };
    var fired: [8]u32 = undefined;
    var k: usize = 0;
    var turn: u32 = 0;
    while (k < fired.len) {
        turn += 1;
        if (s.onTurn(@as(i64, turn) * 1000)) {
            fired[k] = turn;
            k += 1;
            s.ran();
        }
    }
    try std.testing.expectEqualSlices(u32, &.{ 1, 3, 7, 12, 17, 22, 27, 32 }, &fired);
    _ = s.onTurn(100_000);
    try std.testing.expect(!s.onIdle(100_000 + 599_999));
    try std.testing.expect(s.onIdle(100_000 + 600_000));
}
