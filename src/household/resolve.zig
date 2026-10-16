//! Who is a question about? Names, aliases, asker-relative words ("mom", "my wife"), pronouns and group words.
//! One named member wins over any group or relative word in the same question ("who is Rowan's teacher" is about
//! Rowan). Several named members, a group word ("who", "family") or an unresolvable relative word ("teacher",
//! "mother" from a seat it cannot resolve) give a SET of members (`many`): personal rows about any member in the set
//! are served, medical rows never are (they need one person). Fails closed (`none`): an ambiguous name (two Taylors)
//! or an unresolvable third-person pronoun → no target, and then no medical row is served for anyone.
const std = @import("std");
const policy = @import("policy.zig");
const Registry = policy.Registry;
const Actor = policy.Actor;

pub const Reason = enum { ambiguous_name, pronoun, group_word, unresolved_relative, several_people, no_person };

/// A set of members: every member the seat may see (`all`), or the named ones (bit i = registry member i).
pub const Many = struct {
    all: bool = false,
    mask: u64 = 0,

    pub fn has(m: Many, r: Registry, id: []const u8) bool {
        if (m.all) return true;
        const i = memberIndex(r, id) orelse return false;
        return m.mask & (@as(u64, 1) << @intCast(i)) != 0;
    }
};

pub const Target = union(enum) { person: []const u8, many: Many, none: Reason };

/// Registry position of a member id (bit position in `Many.mask` / `Named.amb`). Null past 64 members or unknown.
pub fn memberIndex(r: Registry, id: []const u8) ?usize {
    for (r.members, 0..) |m, i| if (i < 64 and std.mem.eql(u8, m.id, id)) return i;
    return null;
}

const max_words = 128;

const Words = struct {
    buf: [max_words][32]u8 = undefined,
    w: [max_words][]const u8 = undefined,
    n: usize = 0,

    /// Lowercase alphanumeric runs; apostrophes split ("morgan's" → "morgan", "s"). Long words are truncated.
    fn init(ws: *Words, text: []const u8) void {
        ws.n = 0;
        var i: usize = 0;
        while (i < text.len and ws.n < max_words) {
            while (i < text.len and !std.ascii.isAlphanumeric(text[i])) i += 1;
            const s = i;
            while (i < text.len and std.ascii.isAlphanumeric(text[i])) i += 1;
            if (i == s) break;
            const len = @min(i - s, 32);
            ws.w[ws.n] = std.ascii.lowerString(&ws.buf[ws.n], text[s .. s + len]);
            ws.n += 1;
        }
    }
};

const pronouns = [_][]const u8{ "he", "she", "him", "her", "his", "hers", "they", "them", "their", "theirs", "himself", "herself", "themselves", "themself" };
const groups = [_][]const u8{ "everyone", "everybody", "anyone", "anybody", "someone", "somebody", "family", "people", "who", "whose", "whom", "nobody" };
const self_words = [_][]const u8{ "i", "me", "my", "mine", "myself" };
const unresolved = [_][]const u8{
    "sister",  "sisters", "brother",  "brothers", "daughter", "daughters", "son",     "sons",      "kid",     "kids",
    "child",   "children", "girl",    "girls",    "grandma",  "grandmother", "grandpa", "grandfather", "granny", "aunt",
    "uncle",   "cousin",  "friend",   "friends",  "boyfriend", "girlfriend", "teacher", "coach",   "neighbor", "sibling",
    "siblings", "parent", "parents",  "spouse",   "partner",  "stepmom",   "stepdad", "baby",
};
const mom_words = [_][]const u8{ "mom", "mother", "mama", "mommy", "momma", "mum" };
const dad_words = [_][]const u8{ "dad", "father", "daddy", "papa", "pop" };

fn in(w: []const u8, comptime list: anytype) bool {
    for (list) |x| if (std.mem.eql(u8, w, x)) return true;
    return false;
}

/// Asker-relative words resolve only from a seat that belongs to the right member. House-specific ids are data
/// (the registry's principals), not code: "mom" → the principal flagged as mother in `Relations`.
pub const Relations = struct {
    mother: ?[]const u8 = null,
    father: ?[]const u8 = null,

    fn resolve(rel: Relations, r: Registry, a: Actor, w: []const u8) ?[]const u8 {
        const me = a.member orelse return null;
        const m = r.member(me) orelse return null;
        if (in(w, mom_words)) return if (m.role == .child) rel.mother else null;
        if (in(w, dad_words)) return if (m.role == .child) rel.father else null;
        if (std.mem.eql(u8, w, "wife")) return if (rel.father != null and std.mem.eql(u8, me, rel.father.?)) rel.mother else null;
        if (std.mem.eql(u8, w, "husband")) return if (rel.mother != null and std.mem.eql(u8, me, rel.mother.?)) rel.father else null;
        return null;
    }

    fn isRelative(w: []const u8) bool {
        return in(w, mom_words) or in(w, dad_words) or std.mem.eql(u8, w, "wife") or std.mem.eql(u8, w, "husband");
    }
};

const Match = struct { start: usize, end: usize, member: usize };

fn phraseAt(ws: *const Words, at: usize, phrase: []const u8) ?usize {
    var pw: Words = .{};
    pw.init(phrase);
    if (pw.n == 0 or at + pw.n > ws.n) return null;
    for (0..pw.n) |k| if (!std.mem.eql(u8, ws.w[at + k], pw.w[k])) return null;
    return at + pw.n;
}

/// Every household person named in `text` (id, display name, aliases). Matches inside a longer match are dropped
/// ("Taylor" inside "Taylor Kessler"). A span whose longest phrase fits two members is ambiguous: it is kept as the set
/// of members it could be (the subject column, not the text, decides between them).
pub const Named = struct {
    /// members named by an unambiguous span
    set: [64]bool = @splat(false),
    count: usize = 0,
    ambiguous: bool = false,
    /// candidate sets of the ambiguous spans (bit i = registry member i)
    amb: [8]u64 = @splat(0),
    namb: usize = 0,

    fn index(r: Registry, id: []const u8) ?usize {
        return memberIndex(r, id);
    }

    /// Every member this text names (unambiguous spans and every candidate of an ambiguous span) is inside `m`.
    pub fn allIn(n: Named, r: Registry, m: Many) bool {
        if (m.all) return true;
        for (r.members, 0..) |_, i| if (i < 64 and n.set[i] and m.mask & (@as(u64, 1) << @intCast(i)) == 0) return false;
        for (n.amb[0..n.namb]) |mask| if (mask & ~m.mask != 0) return false;
        return true;
    }

    /// Names someone other than `id`: an unambiguous other member, or an ambiguous span that cannot be `id`.
    pub fn other(n: Named, r: Registry, id: []const u8) bool {
        const me = index(r, id);
        for (r.members, 0..) |_, i| if (i < 64 and n.set[i] and (me == null or i != me.?)) return true;
        for (n.amb[0..n.namb]) |mask| if (me == null or mask & (@as(u64, 1) << @intCast(me.?)) == 0) return true;
        return false;
    }

    pub fn has(n: Named, r: Registry, id: []const u8) bool {
        const me = index(r, id) orelse return false;
        if (n.set[me]) return true;
        for (n.amb[0..n.namb]) |mask| if (mask & (@as(u64, 1) << @intCast(me)) != 0) return true;
        return false;
    }
};

pub fn named(r: Registry, text: []const u8) Named {
    var ws: Words = .{};
    ws.init(text);
    return namedWords(r, &ws);
}

fn namedWords(r: Registry, ws: *const Words) Named {
    var ms: [256]Match = undefined;
    var n: usize = 0;
    for (0..ws.n) |at| for (r.members, 0..) |m, mi| {
        if (mi >= 64) break;
        var best: ?usize = phraseAt(ws, at, m.id);
        if (phraseAt(ws, at, m.display)) |e| best = @max(best orelse 0, e);
        for (m.aliases) |al| if (phraseAt(ws, at, al)) |e| {
            best = @max(best orelse 0, e);
        };
        if (best) |e| if (n < ms.len) {
            ms[n] = .{ .start = at, .end = e, .member = mi };
            n += 1;
        };
    };
    var out: Named = .{};
    var done: [256]bool = @splat(false);
    for (ms[0..n], 0..) |x, i| {
        if (done[i]) continue;
        var inside = false;
        for (ms[0..n], 0..) |y, j| if (i != j and y.start <= x.start and x.end <= y.end and (y.end - y.start) > (x.end - x.start)) {
            inside = true;
        };
        if (inside) continue;
        var mask: u64 = @as(u64, 1) << @intCast(x.member);
        for (ms[0..n], 0..) |y, j| if (j > i and y.start == x.start and y.end == x.end) {
            mask |= @as(u64, 1) << @intCast(y.member);
            done[j] = true;
        };
        if (@popCount(mask) > 1) {
            out.ambiguous = true;
            if (out.namb < out.amb.len) {
                out.amb[out.namb] = mask;
                out.namb += 1;
            } else out.amb[out.amb.len - 1] = 0; // overflow: an empty set can be nobody → counts as "other" (fail closed)
        } else if (!out.set[x.member]) {
            out.set[x.member] = true;
            out.count += 1;
        }
    }
    return out;
}

/// The one person a question is about, or why there is none. A question that names nobody is about the asker.
pub fn target(r: Registry, rel: Relations, a: Actor, query: []const u8) Target {
    return targetOr(r, rel, a, query, a.member);
}

/// Like `target`, but a question that names nobody (no name, relative, pronoun, group or self word) is about
/// `default` (the asker, or the one person scope the request narrowed to).
pub fn targetOr(r: Registry, rel: Relations, a: Actor, query: []const u8, default: ?[]const u8) Target {
    var ws: Words = .{};
    ws.init(query);
    const nm = namedWords(r, &ws);
    if (nm.ambiguous) return .{ .none = .ambiguous_name };
    var refs: [8][]const u8 = undefined;
    var nr: usize = 0;
    for (r.members, 0..) |m, i| if (i < 64 and nm.set[i] and nr < refs.len) {
        refs[nr] = m.id;
        nr += 1;
    };
    var self = false;
    var pronoun = false;
    var group = false;
    var unres = false;
    for (0..ws.n) |k| {
        const w = ws.w[k];
        if (in(w, pronouns)) {
            pronoun = true; // decided below: it can only refer to the one member the question names
            continue;
        }
        if (in(w, groups)) {
            group = true;
            continue;
        }
        if (in(w, unresolved)) {
            unres = true;
            continue;
        }
        if (Relations.isRelative(w)) {
            const who = rel.resolve(r, a, w) orelse {
                unres = true;
                continue;
            };
            var dup = false;
            for (refs[0..nr]) |x| if (std.mem.eql(u8, x, who)) {
                dup = true;
            };
            if (!dup and nr < refs.len) {
                refs[nr] = who;
                nr += 1;
            }
            continue;
        }
        if (in(w, self_words)) {
            // "my" directly before a relative word only qualifies it ("my mom", "my sister"); it is not a self reference.
            const qualifies = std.mem.eql(u8, w, "my") and k + 1 < ws.n and (Relations.isRelative(ws.w[k + 1]) or in(ws.w[k + 1], unresolved));
            if (!qualifies) self = true;
        }
    }
    // integration (supervisor 10/13): for a PRINCIPAL's question, a pronoun resolves to the one member the question
    // names (by name, no relative word, no self word: "did Morgan go to the dentist — what did she hear?"). Everyone
    // else, and every other pronoun, still fails closed as in phase 5.
    if (pronoun and !(a.principal() and nr == 1 and !self and nm.count == 1)) return .{ .none = .pronoun };
    if (nr >= 2) return .{ .many = maskOf(r, refs[0..nr]) };
    if (nr == 1) {
        if (self and (a.member == null or !std.mem.eql(u8, a.member.?, refs[0]))) {
            // "is Morgan's dose higher than mine": the named member and the asker — a set, so never a medical row
            const me = a.member orelse return .{ .none = .several_people };
            const both = [2][]const u8{ refs[0], me };
            return .{ .many = maskOf(r, &both) };
        }
        return .{ .person = refs[0] };
    }
    if (self) return if (a.member) |me| .{ .person = me } else .{ .none = .no_person };
    // a group word or a relative word nobody resolves, with no member named: every member the seat may see
    if (group or unres) return .{ .many = .{ .all = true } };
    if (default) |d| return .{ .person = d };
    return .{ .none = .no_person };
}

fn maskOf(r: Registry, ids: []const []const u8) Many {
    var m: Many = .{};
    for (ids) |id| if (memberIndex(r, id)) |i| {
        m.mask |= @as(u64, 1) << @intCast(i);
    };
    return m;
}
