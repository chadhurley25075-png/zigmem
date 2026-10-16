//! The medical person-scope gate: ports of named_family, medical_cross_person, medical_mixed_others, medical_subject_gate.
//! The one DROP exception to "annotate, never delete": another family member's medication never answers a question about
//! someone else. zigmem adds a column check on top (`subjectCross`): atoms carry their subject at write time.
const std = @import("std");
const g = @import("gates.zig");
const re = g.re;
const Text = re.Text;

pub const n_names = g.pat.family.len;
/// A set of family-name indexes (bit i = pat.family[i]).
pub const Names = struct {
    bits: u32 = 0,
    pub fn set(n: *Names, i: usize) void {
        n.bits |= @as(u32, 1) << @intCast(i);
    }
    pub fn isSet(n: Names, i: usize) bool {
        return n.bits & (@as(u32, 1) << @intCast(i)) != 0;
    }
    pub fn count(n: Names) usize {
        return @popCount(n.bits);
    }
    pub fn first(n: Names) ?usize {
        return if (n.bits == 0) null else @ctz(n.bits);
    }
};

pub fn nameOf(i: usize) []const u8 {
    return g.pat.family[i].name;
}

pub fn indexOf(name: []const u8) ?usize {
    for (g.pat.family, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return i;
    return null;
}

/// named_family(text). Never raises (a regex failure → empty set, like the Python).
pub fn named(gs: *g.Gates, t: Text) Names {
    var s: Names = .{};
    for (&gs.rx.family, 0..) |*rx, i| {
        const hit = (rx.search(t, 0) catch return .{}) != null;
        if (hit) s.set(i);
    }
    return s;
}

fn aliasFor(gs: *g.Gates, target: usize) ?*const re.Regex {
    for (g.pat.alias, 0..) |al, k| if (std.mem.eql(u8, al.name, nameOf(target))) return &gs.rx.alias[k];
    return null;
}

/// medical_cross_person(text, target)
pub fn crossPerson(gs: *g.Gates, t: Text, target: usize) !bool {
    if (t.cps.len == 0 or (try gs.rx.med_cue.search(t, 0)) == null) return false;
    const names = named(gs, t);
    if (names.count() == 0 or names.isSet(target)) return false;
    if (aliasFor(gs, target)) |al| if ((try al.search(t, 0)) != null) return false;
    return true;
}

/// medical_mixed_others(text, target): names (alphabetical per sentence, first-seen order across sentences). [] on error.
pub fn mixedOthers(gs: *g.Gates, a: std.mem.Allocator, t: Text, target: usize) ![]usize {
    return mixedInner(gs, a, t, target) catch |e| switch (e) {
        error.OutOfMemory => e,
        else => &.{},
    };
}

fn mixedInner(gs: *g.Gates, a: std.mem.Allocator, t: Text, target: usize) ![]usize {
    if (t.cps.len == 0 or (try gs.rx.med_cue.search(t, 0)) == null) return &.{};
    const al = aliasFor(gs, target);
    var others: std.ArrayList(usize) = .empty;
    const ms = try gs.rx.sent_split.findAll(a, t);
    var prev: usize = 0;
    for (0..ms.len + 1) |k| {
        const end = if (k < ms.len) ms[k].start() else t.cps.len;
        const sent = t.sub(prev, end);
        if (k < ms.len) prev = ms[k].end();
        if ((try gs.rx.med_cue.search(sent, 0)) == null) continue;
        const names = named(gs, sent);
        if (names.count() == 0 or names.isSet(target)) continue;
        if (al) |x| if ((try x.search(sent, 0)) != null) continue;
        // sorted(names): alphabetical by name
        var idx: [n_names]usize = undefined;
        var n: usize = 0;
        for (0..n_names) |i| if (names.isSet(i)) {
            idx[n] = i;
            n += 1;
        };
        std.mem.sort(usize, idx[0..n], {}, struct {
            fn lt(_: void, x: usize, y: usize) bool {
                return std.mem.order(u8, nameOf(x), nameOf(y)) == .lt;
            }
        }.lt);
        for (idx[0..n]) |i| if (std.mem.indexOfScalar(usize, others.items, i) == null) try others.append(a, i);
    }
    return others.items;
}

pub const Mode = g.MedMode;

pub const Row = struct {
    text: []const u8,
    /// zigmem extra: the atom's subject column (a family name) when known. Null = Python behaviour only.
    subject: ?[]const u8 = null,
};

pub const Out = struct {
    /// Kept rows in order; `text` is either the input slice or an owned stamped copy (see `owned`).
    rows: []Row,
    owned: []bool,
    dropped: usize,

    pub fn deinit(o: Out, gpa: std.mem.Allocator) void {
        for (o.rows, o.owned) |r, ow| if (ow) gpa.free(r.text);
        gpa.free(o.rows);
        gpa.free(o.owned);
    }
};

/// medical_subject_gate(rows, query). With `use_subject`, a row whose subject column names a different family member is
/// also dropped when it is medical (the Python cannot see that column; parity tests run with use_subject=false).
pub fn gate(gs: *g.Gates, gpa: std.mem.Allocator, rows: []const Row, query: []const u8, mode: Mode, use_subject: bool) !Out {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(Row) = .empty;
    errdefer out.deinit(gpa);
    var owned: std.ArrayList(bool) = .empty;
    errdefer owned.deinit(gpa);
    var dropped: usize = 0;
    var target: ?usize = null;
    if (mode != .off and rows.len > 0 and query.len > 0) {
        const qt = try Text.init(a, query);
        const subj = named(gs, qt);
        if (subj.count() == 1) target = subj.first();
    }
    for (rows) |r| {
        const tg = target orelse {
            try out.append(gpa, r);
            try owned.append(gpa, false);
            continue;
        };
        const t = try Text.init(a, r.text);
        var bad = crossPerson(gs, t, tg) catch false;
        if (!bad and use_subject) bad = try subjectCross(gs, t, r.subject, tg);
        var row = r;
        var own = false;
        if (!bad and mode == .enforce) {
            const others = try mixedOthers(gs, a, t, tg);
            if (others.len > 0) {
                var who: std.ArrayList(u8) = .empty;
                for (others, 0..) |o, k| {
                    if (k > 0) try who.append(a, '/');
                    const nm = nameOf(o);
                    try who.append(a, std.ascii.toUpper(nm[0]));
                    try who.appendSlice(a, nm[1..]);
                }
                const tn = nameOf(tg);
                row.text = try std.fmt.allocPrint(gpa, "⚠[SCOPE-CORRECTED: medication named here for {s} is NOT {c}{s}'s] {s}", .{ who.items, std.ascii.toUpper(tn[0]), tn[1..], r.text });
                own = true;
            }
        }
        if (bad) {
            dropped += 1;
            if (mode == .enforce) continue;
            row = r; // shadow: rows unchanged
        }
        if (mode != .enforce and own) {
            gpa.free(row.text);
            row = r;
            own = false;
        }
        try out.append(gpa, row);
        try owned.append(gpa, own);
    }
    return .{ .rows = try out.toOwnedSlice(gpa), .owned = try owned.toOwnedSlice(gpa), .dropped = dropped };
}

/// Column check: a medical row whose stored subject is another known family member, and whose text never names the target.
fn subjectCross(gs: *g.Gates, t: Text, subject: ?[]const u8, target: usize) !bool {
    const s = subject orelse return false;
    const si = indexOf(s) orelse return false;
    if (si == target) return false;
    if ((try gs.rx.med_cue.search(t, 0)) == null) return false;
    return !named(gs, t).isSet(target);
}
