//! Subject attribution: map the model's subject to a household person, never defaulting to anyone (Morgan calls too).
const std = @import("std");
const Status = @import("sink.zig").Status;

pub const Person = struct { id: []const u8, aliases: []const []const u8 = &.{} };

pub const Verdict = struct { subject: []const u8, status: Status, reason: ?[]const u8 };

const unresolved_words = [_][]const u8{ "unknown", "user", "the user", "speaker", "the speaker", "i", "me", "someone", "somebody", "", "none", "null", "n/a" };

fn eqlFold(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn wordAt(text: []const u8, i: usize, n: usize) bool {
    const before_ok = i == 0 or !std.ascii.isAlphanumeric(text[i - 1]);
    const after_ok = i + n >= text.len or !std.ascii.isAlphanumeric(text[i + n]);
    return before_ok and after_ok;
}

/// Case-insensitive whole-word occurrence.
pub fn mentions(text: []const u8, name: []const u8) bool {
    if (name.len == 0 or name.len > text.len) return false;
    var i: usize = 0;
    while (i + name.len <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i .. i + name.len], name) and wordAt(text, i, name.len)) return true;
    }
    return false;
}

pub const People = struct {
    list: []const Person,

    /// Household id for a name or alias (case-insensitive, trailing "'s" dropped), else null.
    pub fn resolve(p: People, raw: []const u8) ?[]const u8 {
        var name = std.mem.trim(u8, raw, " \t.\"");
        if (std.mem.endsWith(u8, name, "'s")) name = name[0 .. name.len - 2];
        for (p.list) |x| {
            if (eqlFold(x.id, name)) return x.id;
            for (x.aliases) |al| if (eqlFold(al, name)) return x.id;
        }
        return null;
    }

    fn named(x: Person, text: []const u8) bool {
        if (mentions(text, x.id)) return true;
        for (x.aliases) |al| if (mentions(text, al)) return true;
        return false;
    }

    /// The rule: an unresolved or out-of-household subject never becomes active. A resolved subject whose text does not
    /// name them (but names someone else) goes to review instead of being trusted.
    pub fn attribute(p: People, model_subject: []const u8, text: []const u8) Verdict {
        const trimmed = std.mem.trim(u8, model_subject, " \t.\"");
        for (unresolved_words) |w| if (eqlFold(trimmed, w))
            return .{ .subject = "unknown", .status = .pending_review, .reason = "subject unresolved" };
        const id = p.resolve(trimmed) orelse
            return .{ .subject = trimmed, .status = .pending_review, .reason = "subject not in household list" };
        for (p.list) |x| if (std.mem.eql(u8, x.id, id)) {
            if (named(x, text)) return .{ .subject = id, .status = .active, .reason = null };
        };
        return .{ .subject = id, .status = .pending_review, .reason = "text does not name the subject" };
    }

    /// "Morgan (also: Mom, Morgana)" lines for the prompt. Deterministic order = list order.
    pub fn render(p: People, a: std.mem.Allocator) ![]const []const u8 {
        const out = try a.alloc([]const u8, p.list.len);
        for (p.list, 0..) |x, i| {
            if (x.aliases.len == 0) {
                out[i] = x.id;
                continue;
            }
            var b: std.ArrayList(u8) = .empty;
            try b.print(a, "{s} (also: ", .{x.id});
            for (x.aliases, 0..) |al, j| try b.print(a, "{s}{s}", .{ if (j == 0) "" else ", ", al });
            try b.append(a, ')');
            out[i] = b.items;
        }
        return out;
    }
};

test "attribution: never defaults to Alex; unknown and outsiders go to review" {
    const al_b = [_][]const u8{ "Mom", "Morgana" };
    const al_j = [_][]const u8{ "Grandma June", "Junie" };
    const list = [_]Person{ .{ .id = "Alex" }, .{ .id = "Morgan", .aliases = &al_b }, .{ .id = "June", .aliases = &al_j } };
    const p: People = .{ .list = &list };
    const v1 = p.attribute("Morgan", "Morgan signed up for the 5K.");
    try std.testing.expectEqual(Status.active, v1.status);
    try std.testing.expectEqualStrings("Morgan", v1.subject);
    try std.testing.expectEqual(Status.pending_review, p.attribute("User", "User has oral surgery.").status);
    try std.testing.expectEqualStrings("unknown", p.attribute("the speaker", "Someone likes green.").subject);
    const out = p.attribute("Carla", "Carla is visiting for Thanksgiving.");
    try std.testing.expectEqual(Status.pending_review, out.status);
    try std.testing.expectEqualStrings("Carla", out.subject);
    try std.testing.expectEqualStrings("June", p.attribute("Grandma June", "Grandma June's book club meets Tuesday.").subject);
    try std.testing.expectEqual(Status.active, p.attribute("june's", "Junie prefers tea.").status);
    try std.testing.expectEqual(Status.pending_review, p.attribute("Alex", "Morgana likes pecan pie.").status);
    try std.testing.expect(!mentions("Alexis ran", "Alex"));
    try std.testing.expect(mentions("it was Alex's truck", "Alex"));
}
