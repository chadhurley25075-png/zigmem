//! A Python-`re`-compatible backtracking matcher over code points (str semantics), so the gate patterns are copied verbatim.
//! Supports: literals, `.`, classes (ranges, \d\w\s\D\W\S, negation), groups (capturing, `(?:`), `|`, `* + ? {m} {m,} {m,n}`
//! greedy and lazy, `^ $ \b \B \A \Z`, lookahead `(?= (?!`, fixed-width lookbehind `(?<= (?<!`, flags IGNORECASE and DOTALL.
//! Leftmost-first like sre; IGNORECASE uses sre's own equivalence classes (generated tables in unitab.zig).
const std = @import("std");
const tab = @import("unitab.zig");

pub const Flags = struct { i: bool = false, s: bool = false };

/// Text as code points plus the byte offset of each code point (len+1 entries) for slicing back into UTF-8.
pub const Text = struct {
    cps: []u21,
    off: []usize,
    bytes: []const u8,

    pub fn init(gpa: std.mem.Allocator, bytes: []const u8) !Text {
        var cps: std.ArrayList(u21) = .empty;
        errdefer cps.deinit(gpa);
        var off: std.ArrayList(usize) = .empty;
        errdefer off.deinit(gpa);
        var i: usize = 0;
        while (i < bytes.len) {
            const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
            const cp: u21 = if (i + n <= bytes.len) (std.unicode.utf8Decode(bytes[i .. i + n]) catch 0xFFFD) else 0xFFFD;
            try off.append(gpa, i);
            try cps.append(gpa, cp);
            i += if (i + n <= bytes.len) n else 1;
        }
        try off.append(gpa, bytes.len);
        return .{ .cps = try cps.toOwnedSlice(gpa), .off = try off.toOwnedSlice(gpa), .bytes = bytes };
    }

    pub fn deinit(t: Text, gpa: std.mem.Allocator) void {
        gpa.free(t.cps);
        gpa.free(t.off);
    }

    /// A view of code points [a, b) as its own string (anchors and \\b see a..b as the whole text, like a Python slice).
    pub fn sub(t: Text, a: usize, b: usize) Text {
        return .{ .cps = t.cps[a..b], .off = t.off[a .. b + 1], .bytes = t.bytes };
    }

    /// Bytes of code-point span [a, b).
    pub fn slice(t: Text, a: usize, b: usize) []const u8 {
        return t.bytes[t.off[a]..t.off[b]];
    }
};

fn inRanges(rs: []const tab.R, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = rs.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < rs[mid][0]) hi = mid else if (cp > rs[mid][1]) lo = mid + 1 else return true;
    }
    return false;
}

pub fn isWord(cp: u21) bool {
    if (cp < 128) return std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_';
    return inRanges(&tab.word, cp);
}
pub fn isDigit(cp: u21) bool {
    if (cp < 128) return cp >= '0' and cp <= '9';
    return inRanges(&tab.decimal, cp);
}
pub fn isSpace(cp: u21) bool {
    if (cp < 128) return cp == ' ' or (cp >= 9 and cp <= 13) or (cp >= 0x1c and cp <= 0x1f);
    return inRanges(&tab.space, cp);
}
/// Decimal value of a \d code point (sre/int() semantics).
pub fn digitValue(cp: u21) ?u8 {
    if (cp >= '0' and cp <= '9') return @intCast(cp - '0');
    var lo: usize = 0;
    var hi: usize = tab.digit.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < tab.digit[mid][0]) hi = mid else if (cp > tab.digit[mid][0]) lo = mid + 1 else return @intCast(tab.digit[mid][1]);
    }
    return null;
}

/// Canonical member of cp's IGNORECASE class (cp itself when the class has one member).
pub fn canon(cp: u21) u21 {
    var lo: usize = 0;
    var hi: usize = tab.fold.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < tab.fold[mid][0]) hi = mid else if (cp > tab.fold[mid][0]) lo = mid + 1 else return tab.fold[mid][1];
    }
    return cp;
}

fn members(cp: u21) []const u21 {
    const c = canon(cp);
    var lo: usize = 0;
    var hi: usize = tab.groups.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const g = tab.groups[mid][0];
        if (c < g) hi = mid else if (c > g) lo = mid + 1 else return tab.groups[mid];
    }
    return &.{};
}

/// Python str.lower() of one code point: up to two code points.
pub fn lowerFull(cp: u21) [2]u21 {
    if (cp < 128) return .{ if (cp >= 'A' and cp <= 'Z') cp + 32 else cp, 0 };
    var lo: usize = 0;
    var hi: usize = tab.lower.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < tab.lower[mid][0]) hi = mid else if (cp > tab.lower[mid][0]) lo = mid + 1 else return .{ tab.lower[mid][1], tab.lower[mid][2] };
    }
    return .{ cp, 0 };
}

const C = @import("re_compile.zig");
const Item = C.Item;
const Class = C.Class;
const AKind = C.AKind;
const Op = C.Op;
const Look = C.Look;
const Parser = C.Parser;
const Gen = C.Gen;

pub const Regex = struct {
    arena: std.heap.ArenaAllocator,
    prog: []Op,
    classes: []Class,
    looks: []Look,
    ngroups: u16,
    flags: Flags,
    /// Start-position prefilter (integration, performance only): the consuming ops a match must begin with, or null
    /// when the pattern can match the empty string (then every position is tried, as before).
    first: ?First = null,

    /// The ops any match starting at a position must consume first (zero-width ops — asserts, lookarounds, saves,
    /// splits, jumps — are passed through: an over-approximation, so skipping a position is always sound).
    pub const First = struct { chars: []const u21, classes: []const usize, any: bool };

    pub fn compile(gpa: std.mem.Allocator, pattern: []const u8, flags: Flags) !Regex {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var pat: std.ArrayList(u21) = .empty;
        var it = (try std.unicode.Utf8View.init(pattern)).iterator();
        while (it.nextCodepoint()) |cp| try pat.append(a, cp);
        var p: Parser = .{ .a = a, .s = pat.items };
        const root = try p.parseAlt();
        if (p.i != p.s.len) return error.BadPattern;
        var g: Gen = .{ .a = a, .p = &p };
        var main: std.ArrayList(Op) = .empty;
        try g.emit(&main, root);
        try main.append(a, .match);
        // computed before `arena` is copied into the result (allocations after the copy would not be tracked by it)
        const first = try firstSet(a, main.items);
        return .{ .arena = arena, .prog = main.items, .classes = p.classes.items, .looks = g.looks.items, .ngroups = p.ngroups, .flags = flags, .first = first };
    }

    /// Epsilon closure from pc 0. Null when `.match` is reachable without consuming (the empty match is possible).
    fn firstSet(a: std.mem.Allocator, prog: []const Op) !?First {
        const seen = try a.alloc(bool, prog.len);
        @memset(seen, false);
        var todo: std.ArrayList(usize) = .empty;
        var chars: std.ArrayList(u21) = .empty;
        var classes: std.ArrayList(usize) = .empty;
        var any = false;
        try todo.append(a, 0);
        while (todo.pop()) |pc| {
            if (pc >= prog.len or seen[pc]) continue;
            seen[pc] = true;
            switch (prog[pc]) {
                .char => |c| try chars.append(a, c),
                .class => |ci| try classes.append(a, ci),
                .any => any = true,
                .match => return null,
                .assert, .save, .look => try todo.append(a, pc + 1),
                .jmp => |j| try todo.append(a, j),
                .split => |sp| {
                    try todo.append(a, sp[0]);
                    try todo.append(a, sp[1]);
                },
            }
        }
        return .{ .chars = chars.items, .classes = classes.items, .any = any };
    }

    /// Can a match possibly start at `pos`? (Sound: false only when no first op accepts the code point there.)
    fn canStart(self: *const Regex, t: Text, pos: usize) bool {
        const f = self.first orelse return true;
        if (pos >= t.cps.len) return false;
        const c = t.cps[pos];
        if (f.any and (self.flags.s or c != '\n')) return true;
        for (f.chars) |x| if (self.charEq(x, c)) return true;
        for (f.classes) |ci| if (self.classHit(ci, c)) return true;
        return false;
    }

    pub fn deinit(self: *Regex) void {
        self.arena.deinit();
    }

    /// Group spans in code points; slot 2g = start, 2g+1 = end (null when the group did not take part).
    pub const Match = struct {
        caps: [2 * max_groups]?usize,
        pub fn start(m: Match) usize {
            return m.caps[0].?;
        }
        pub fn end(m: Match) usize {
            return m.caps[1].?;
        }
        pub fn group(m: Match, t: Text, g: usize) ?[]const u8 {
            const s = m.caps[2 * g] orelse return null;
            const e = m.caps[2 * g + 1] orelse return null;
            return t.slice(s, e);
        }
    };

    /// re.match at code point `pos` (anchored there).
    pub fn matchAt(self: *const Regex, t: Text, pos: usize) !?Match {
        var caps: [2 * max_groups]?usize = @splat(null);
        if (try self.run(self.prog, t, pos, null, &caps)) |e| {
            caps[0] = pos;
            caps[1] = e;
            return .{ .caps = caps };
        }
        return null;
    }

    /// re.search from code point `from`.
    pub fn search(self: *const Regex, t: Text, from: usize) !?Match {
        var p = from;
        while (p <= t.cps.len) : (p += 1) {
            if (!self.canStart(t, p)) continue;
            if (try self.matchAt(t, p)) |m| return m;
        }
        return null;
    }

    pub fn fullmatch(self: *const Regex, t: Text) !?Match {
        var caps: [2 * max_groups]?usize = @splat(null);
        if (try self.run(self.prog, t, 0, t.cps.len, &caps)) |e| {
            caps[0] = 0;
            caps[1] = e;
            return .{ .caps = caps };
        }
        return null;
    }

    /// Convenience: does the pattern occur anywhere in `bytes`?
    pub fn has(self: *const Regex, gpa: std.mem.Allocator, bytes: []const u8) !bool {
        const t = try Text.init(gpa, bytes);
        defer t.deinit(gpa);
        return (try self.search(t, 0)) != null;
    }

    pub fn matches(self: *const Regex, gpa: std.mem.Allocator, bytes: []const u8) !bool {
        const t = try Text.init(gpa, bytes);
        defer t.deinit(gpa);
        return (try self.matchAt(t, 0)) != null;
    }

    /// finditer: non-overlapping matches; after an EMPTY match the next one must advance (Python 3.7+ rule).
    pub fn findAll(self: *const Regex, gpa: std.mem.Allocator, t: Text) ![]Match {
        var out: std.ArrayList(Match) = .empty;
        errdefer out.deinit(gpa);
        var pos: usize = 0;
        var must_adv = false;
        while (pos <= t.cps.len) {
            var p = pos;
            var found: ?Match = null;
            while (p <= t.cps.len) : (p += 1) {
                if (!self.canStart(t, p)) continue;
                if (try self.matchAt(t, p)) |mm| {
                    if (must_adv and mm.start() == pos and mm.end() == pos) continue;
                    found = mm;
                    break;
                }
            }
            const m = found orelse break;
            try out.append(gpa, m);
            must_adv = m.end() == m.start();
            pos = m.end();
        }
        return out.toOwnedSlice(gpa);
    }

    fn charEq(self: *const Regex, pc: u21, c: u21) bool {
        if (pc == c) return true;
        if (!self.flags.i) return false;
        return canon(pc) == canon(c);
    }

    fn classRaw(cl: Class, c: u21) bool {
        for (cl.items) |it| switch (it) {
            .cp => |x| if (x == c) return true,
            .range => |r| if (c >= r[0] and c <= r[1]) return true,
            .cat => |k| if (switch (k) {
                'd' => isDigit(c),
                'D' => !isDigit(c),
                'w' => isWord(c),
                'W' => !isWord(c),
                's' => isSpace(c),
                'S' => !isSpace(c),
                else => false,
            }) return true,
        };
        return false;
    }

    fn classHit(self: *const Regex, ci: usize, c: u21) bool {
        const cl = self.classes[ci];
        var hit = classRaw(cl, c);
        if (!hit and self.flags.i) {
            for (members(c)) |m| if (m != c and classRaw(cl, m)) {
                hit = true;
                break;
            };
        }
        return hit != cl.neg;
    }

    fn assertOk(k: AKind, t: Text, pos: usize) bool {
        const n = t.cps.len;
        return switch (k) {
            .bol, .start => pos == 0,
            .eol => pos == n or (n > 0 and pos == n - 1 and t.cps[pos] == '\n'),
            .end => pos == n,
            .wordb, .nonwordb => blk: {
                const before = pos > 0 and isWord(t.cps[pos - 1]);
                const after = pos < n and isWord(t.cps[pos]);
                break :blk (before != after) == (k == .wordb);
            },
        };
    }

    const Frame = union(enum) { branch: struct { pc: usize, pos: usize }, restore: struct { slot: u16, old: ?usize } };

    /// LIFO of frames: a fixed native-stack buffer, then a heap spill (pops come from the spill first).
    const Frames = struct {
        a: std.mem.Allocator,
        buf: [128]Frame = undefined,
        n: usize = 0,
        spill: std.ArrayList(Frame) = .empty,

        fn push(f: *Frames, x: Frame) !void {
            if (f.n < f.buf.len and f.spill.items.len == 0) {
                f.buf[f.n] = x;
                f.n += 1;
            } else try f.spill.append(f.a, x);
        }
        fn pop(f: *Frames) ?Frame {
            if (f.spill.pop()) |x| return x;
            if (f.n == 0) return null;
            f.n -= 1;
            return f.buf[f.n];
        }
        fn deinit(f: *Frames) void {
            f.spill.deinit(f.a);
        }
    };

    /// Backtracking VM. `must_end` (lookbehind/fullmatch) requires the match to end exactly there.
    fn run(self: *const Regex, prog: []const Op, t: Text, start: usize, must_end: ?usize, caps: *[2 * max_groups]?usize) error{ OutOfMemory, TooComplex }!?usize {
        // backtrack frames live on the native stack first (no heap traffic per start position; spills when deep)
        var stack: Frames = .{ .a = self.arena.child_allocator };
        defer stack.deinit();
        var pc: usize = 0;
        var pos = start;
        var steps: usize = 0;
        while (true) {
            steps += 1;
            if (steps > 50_000_000) return error.TooComplex;
            const ok: bool = switch (prog[pc]) {
                .char => |c| blk: {
                    if (pos < t.cps.len and self.charEq(c, t.cps[pos])) {
                        pos += 1;
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .any => blk: {
                    if (pos < t.cps.len and (self.flags.s or t.cps[pos] != '\n')) {
                        pos += 1;
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .class => |ci| blk: {
                    if (pos < t.cps.len and self.classHit(ci, t.cps[pos])) {
                        pos += 1;
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .assert => |k| blk: {
                    if (assertOk(k, t, pos)) {
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .split => |s| blk: {
                    try stack.push(.{ .branch = .{ .pc = s[1], .pos = pos } });
                    pc = s[0];
                    break :blk true;
                },
                .jmp => |j| blk: {
                    pc = j;
                    break :blk true;
                },
                .save => |slot| blk: {
                    try stack.push(.{ .restore = .{ .slot = slot, .old = caps[slot] } });
                    caps[slot] = pos;
                    pc += 1;
                    break :blk true;
                },
                .look => |li| blk: {
                    const lk = self.looks[li];
                    var sub: [2 * max_groups]?usize = @splat(null);
                    const hit = if (lk.behind)
                        (pos >= lk.width and (try self.run(lk.prog, t, pos - lk.width, pos, &sub)) != null)
                    else
                        (try self.run(lk.prog, t, pos, null, &sub)) != null;
                    if (hit != lk.neg) {
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .match => blk: {
                    if (must_end == null or must_end.? == pos) return pos;
                    break :blk false;
                },
            };
            if (ok) continue;
            // backtrack
            while (true) {
                const f = stack.pop() orelse return null;
                switch (f) {
                    .restore => |r| caps[r.slot] = r.old,
                    .branch => |b| {
                        pc = b.pc;
                        pos = b.pos;
                        break;
                    },
                }
            }
        }
    }
};

pub const max_groups = 10;

test "basics" {
    const gpa = std.testing.allocator;
    var r = try Regex.compile(gpa, "a(b+?)c|x", .{});
    defer r.deinit();
    const t = try Text.init(gpa, "zzabbbc");
    defer t.deinit(gpa);
    const m = (try r.search(t, 0)).?;
    try std.testing.expectEqualStrings("bbb", m.group(t, 1).?);
}
