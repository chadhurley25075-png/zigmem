//! The gate's independent oracle: who may read / write which scope, spelled out per seat as literal lists, and the
//! adversarial question generator with its ground-truth target written per template. Shares no logic with
//! policy.zig / resolve.zig (a bug there must not be able to hide itself here).
const std = @import("std");

pub const Rule = struct { seat: []const u8, member: ?[]const u8, role: []const u8, read: []const u8, write: []const u8 };

/// "*" = household + every person:/seat: scope of this fixture (never an unknown scope like `work`).
/// "*w" = every person:/seat: scope (never household: shared memory only by promotion).
pub const rules = [_]Rule{
    .{ .seat = "alex-term", .member = "alex", .role = "principal", .read = "*", .write = "*w" },
    .{ .seat = "morgan-air", .member = "morgan", .role = "principal", .read = "*", .write = "*w" },
    .{ .seat = "taylor-phone", .member = "taylor", .role = "child", .read = "household person:taylor seat:taylor-phone", .write = "person:taylor seat:taylor-phone" },
    .{ .seat = "jordan-phone", .member = "jordan", .role = "child", .read = "household person:jordan seat:jordan-phone", .write = "person:jordan seat:jordan-phone" },
    .{ .seat = "quinn-mac", .member = "quinn", .role = "child", .read = "household person:quinn seat:quinn-mac", .write = "person:quinn seat:quinn-mac" },
    .{ .seat = "rowan-phone", .member = "rowan", .role = "child", .read = "household person:rowan seat:rowan-phone", .write = "person:rowan seat:rowan-phone" },
    .{ .seat = "kitchen", .member = null, .role = "shared", .read = "household seat:kitchen", .write = "seat:kitchen" },
    .{ .seat = "guest-phone", .member = "taylor-k", .role = "guest", .read = "person:taylor-k seat:guest-phone", .write = "person:taylor-k seat:guest-phone" },
    .{ .seat = "quinn-ipad-old", .member = "quinn", .role = "child", .read = "household person:quinn seat:quinn-ipad-old", .write = "person:quinn seat:quinn-ipad-old" },
};

pub const all_scopes = [_][]const u8{
    "household",         "person:alex",       "person:morgan",      "person:taylor",  "person:jordan",   "person:quinn",
    "person:rowan",       "person:taylor-k",   "seat:alex-term",   "seat:morgan-air",  "seat:taylor-phone", "seat:jordan-phone",
    "seat:quinn-mac",     "seat:rowan-phone",   "seat:kitchen",     "seat:guest-phone", "seat:quinn-ipad-old", "work",
};

pub fn rule(seat: []const u8) *const Rule {
    for (&rules) |*r| if (std.mem.eql(u8, r.seat, seat)) return r;
    unreachable;
}

fn listHas(list: []const u8, scope: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ' ');
    while (it.next()) |x| if (std.mem.eql(u8, x, scope)) return true;
    return false;
}

fn known(scope: []const u8) bool {
    for (all_scopes) |s| if (std.mem.eql(u8, s, scope) and !std.mem.eql(u8, s, "work")) return true;
    return false;
}

pub fn canRead(seat: []const u8, scope: []const u8) bool {
    const r = rule(seat);
    if (std.mem.eql(u8, r.read, "*")) return known(scope);
    return listHas(r.read, scope);
}

pub fn canWrite(seat: []const u8, scope: []const u8) bool {
    const r = rule(seat);
    if (std.mem.eql(u8, r.write, "*w")) return known(scope) and !std.mem.eql(u8, scope, "household");
    return listHas(r.write, scope);
}

pub fn principal(seat: []const u8) bool {
    return std.mem.eql(u8, rule(seat).role, "principal");
}

/// Own scopes (household, own person, own seat) are not cross-scope; everything else is.
pub fn cross(seat: []const u8, scope: []const u8) bool {
    const r = rule(seat);
    if (std.mem.eql(u8, scope, "household")) return false;
    if (std.mem.startsWith(u8, scope, "seat:") and std.mem.eql(u8, scope[5..], r.seat)) return false;
    if (r.member) |m| if (std.mem.startsWith(u8, scope, "person:") and std.mem.eql(u8, scope[7..], m)) return false;
    return true;
}

pub const Q = struct {
    text: []const u8,
    /// ground truth: the one person this question is unambiguously about, or null (pronoun, ambiguous, group…)
    gt: ?[]const u8,
    medical: bool,
    requested: ?[]const []const u8 = null,
    expect_forbidden: bool = false,
    tag: []const u8,
};

const NameForm = struct { form: []const u8, gt: ?[]const u8 };
const names = [_]NameForm{
    .{ .form = "Alex", .gt = "alex" },          .{ .form = "Morgan", .gt = "morgan" },       .{ .form = "Morgana", .gt = "morgan" },
    .{ .form = "Taylor Harper", .gt = "taylor" }, .{ .form = "Tay", .gt = "taylor" },    .{ .form = "Taylor", .gt = null },
    .{ .form = "Taylor Kessler", .gt = "taylor-k" }, .{ .form = "Jordan", .gt = "jordan" }, .{ .form = "Quinn", .gt = "quinn" },
    .{ .form = "Rowan", .gt = "rowan" },          .{ .form = "Ro", .gt = "rowan" },
};

pub fn questions(a: std.mem.Allocator, seat: []const u8) ![]Q {
    const r = rule(seat);
    const child = std.mem.eql(u8, r.role, "child");
    const me = r.member;
    var out: std.ArrayList(Q) = .empty;
    for (names) |n| {
        for ([_][]const u8{ "what meds does {s} take", "{s}'s prescription", "is {s} on any medication" }) |tpl| {
            const text = try std.mem.replaceOwned(u8, a, tpl, "{s}", n.form);
            try out.append(a, .{ .text = text, .gt = n.gt, .medical = true, .tag = "named" });
        }
    }
    const rel = [_]Q{
        .{ .text = "what does my mom take for migraines", .gt = if (child) "morgan" else null, .medical = true, .tag = "relative" },
        .{ .text = "dad's pills", .gt = if (child) "alex" else null, .medical = true, .tag = "relative" },
        .{ .text = "my wife's dose", .gt = if (std.mem.eql(u8, seat, "alex-term")) "morgan" else null, .medical = true, .tag = "relative" },
        .{ .text = "my husband's prescription", .gt = if (std.mem.eql(u8, seat, "morgan-air")) "alex" else null, .medical = true, .tag = "relative" },
        .{ .text = "my sister's meds", .gt = null, .medical = true, .tag = "relative" },
        .{ .text = "grandma's medication", .gt = null, .medical = true, .tag = "relative" },
        .{ .text = "what does she take", .gt = null, .medical = true, .tag = "pronoun" },
        .{ .text = "is he on anything for anxiety", .gt = null, .medical = true, .tag = "pronoun" },
        .{ .text = "what are they prescribed", .gt = null, .medical = true, .tag = "pronoun" },
        .{ .text = "her prescription refill", .gt = null, .medical = true, .tag = "pronoun" },
        .{ .text = "his meds", .gt = null, .medical = true, .tag = "pronoun" },
        .{ .text = "what meds do I take", .gt = me, .medical = true, .tag = "self" },
        .{ .text = "my prescription", .gt = me, .medical = true, .tag = "self" },
        .{ .text = "what is my dose", .gt = me, .medical = true, .tag = "self" },
        .{ .text = "who takes zorvatraline", .gt = null, .medical = true, .tag = "group" },
        .{ .text = "does anyone in the family take meds", .gt = null, .medical = true, .tag = "group" },
        .{ .text = "everyone's prescriptions", .gt = null, .medical = true, .tag = "group" },
        .{ .text = "whose refill is due", .gt = null, .medical = true, .tag = "group" },
        .{ .text = "list the medications", .gt = me, .medical = true, .tag = "no-person" },
        .{ .text = "pill schedule for tonight", .gt = me, .medical = true, .tag = "no-person" },
        .{ .text = "dose", .gt = me, .medical = true, .tag = "no-person" },
        .{ .text = "does Morgan take more pills than Rowan", .gt = null, .medical = true, .tag = "two-people" },
        .{ .text = "Rowan and Quinn's meds", .gt = null, .medical = true, .tag = "two-people" },
        .{ .text = "is Alex's dose higher than mine", .gt = if (std.mem.eql(u8, seat, "alex-term")) "alex" else null, .medical = true, .tag = "two-people" },
        .{ .text = "the household wifi rule", .gt = me, .medical = false, .tag = "plain" },
        .{ .text = "kitchen timer note", .gt = me, .medical = false, .tag = "plain" },
        .{ .text = "seat note playlist", .gt = me, .medical = false, .tag = "plain" },
        .{ .text = "journal about the garden", .gt = me, .medical = false, .tag = "plain" },
        .{ .text = "Morgan's favorite color", .gt = "morgan", .medical = false, .tag = "plain" },
        .{ .text = "Rowan's favorite color", .gt = "rowan", .medical = false, .tag = "plain" },
    };
    try out.appendSlice(a, &rel);
    // forged scope requests: every scope this seat may NOT read must be refused outright
    for (all_scopes) |s| if (!canRead(seat, s)) {
        const req = try a.alloc([]const u8, 1);
        req[0] = s;
        try out.append(a, .{ .text = "what meds does Morgan take", .gt = "morgan", .medical = true, .requested = req, .expect_forbidden = true, .tag = "forged-scope" });
    };
    // a narrowed request inside the seat's own grant is honoured
    for (all_scopes) |s| if (canRead(seat, s) and !std.mem.eql(u8, s, "work")) {
        const req = try a.alloc([]const u8, 1);
        req[0] = s;
        try out.append(a, .{ .text = "prescription meds dose", .gt = me, .medical = true, .requested = req, .tag = "narrowed" });
        break;
    };
    return out.items;
}
