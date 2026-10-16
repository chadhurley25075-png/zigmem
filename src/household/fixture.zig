//! SYNTHETIC household fixture for tests and the phase-5 gate. Every fact is invented (made-up drug names, colours,
//! notes) under placeholder names, labelled "[SYNTHETIC]", and written only to a throwaway test database — never to a
//! live store. Each row carries its ground truth (who the fact is really about, whether it is medical, whether it is
//! clean) so the leak oracle never relies on the code it is judging.
const std = @import("std");
const store = @import("store");
const policy = @import("policy.zig");
const House = @import("house.zig").House;

pub const members = [_]House.MemberIn{
    .{ .id = "alex", .display = "Alex Harper", .role = .principal, .relation = "father" },
    .{ .id = "morgan", .display = "Morgan Harper", .aliases = &.{"Morgana"}, .role = .principal, .relation = "mother" },
    .{ .id = "taylor", .display = "Taylor Harper", .aliases = &.{"Tay"}, .role = .child },
    .{ .id = "jordan", .display = "Jordan Harper", .role = .child },
    .{ .id = "quinn", .display = "Quinn Harper", .role = .child },
    .{ .id = "rowan", .display = "Rowan Harper", .aliases = &.{"Ro"}, .role = .child },
    // the other Taylor: a guest member whose first name collides with the eldest daughter's
    .{ .id = "taylor-k", .display = "Taylor Kessler", .aliases = &.{ "Taylor", "Taylor K" }, .role = .guest },
};

pub const seats = [_]policy.Seat{
    .{ .name = "alex-term", .member = "alex" },
    .{ .name = "morgan-air", .member = "morgan" },
    .{ .name = "taylor-phone", .member = "taylor" },
    .{ .name = "jordan-phone", .member = "jordan" },
    .{ .name = "quinn-mac", .member = "quinn" },
    .{ .name = "rowan-phone", .member = "rowan" },
    .{ .name = "kitchen", .member = null },
    .{ .name = "guest-phone", .member = "taylor-k" },
    .{ .name = "quinn-ipad-old", .member = "quinn" },
};

pub const person_ids = [_][]const u8{ "alex", "morgan", "taylor", "jordan", "quinn", "rowan", "taylor-k" };
const firsts = [_][]const u8{ "Alex", "Morgan", "Taylor", "Jordan", "Quinn", "Rowan", "Taylor Kessler" };
const drugs = [_][3][]const u8{
    .{ "florvastatin", "kestrapril", "dunavexine" },
    .{ "zorvatraline", "bumelapril", "estravexine" },
    .{ "velmoprazole", "tamsucodone", "orvexine" },
    .{ "dunatolol", "mirexacillin", "pelvexine" },
    .{ "lomitriptan", "carvastatin", "quorvexine" },
    .{ "ravinoxetine", "selmazolam", "trivexine" },
    .{ "harvacillin", "pentaprazole", "olvexine" },
};
const colors = [_][]const u8{ "navy", "teal", "plum", "sage", "coral", "gold", "rust" };

pub const Truth = struct {
    id: i64 = 0,
    scope: []const u8,
    subject: []const u8,
    /// who the fact is really about (differs from `subject` on the deliberately mis-attributed rows)
    truth: []const u8,
    med: bool,
    /// subject column == truth, active, and the text names nobody else: a legitimate answer for `truth`
    clean: bool,
    active: bool = true,
    text: []const u8,
};

/// Rows written through House.write (the normal path) + rows forced into the store directly (an importer, a broken
/// extractor, legacy data): household medical rows, mis-attributions, an outsider Taylor, a "User has…" row,
/// an unknown scope, and inactive rows.
pub fn load(a: std.mem.Allocator, h: House) ![]Truth {
    try h.bootstrap(a, &members, &seats);
    var out: std.ArrayList(Truth) = .empty;
    for (person_ids, 0..) |p, i| {
        const ps = try std.fmt.allocPrint(a, "person:{s}", .{p});
        const seat = owner(p);
        const f = firsts[i];
        const rows = [_]struct { text: []const u8, med: bool, tag: ?bool }{
            .{ .text = try std.fmt.allocPrint(a, "[SYNTHETIC] {s} takes 20 mg of {s} each morning.", .{ f, drugs[i][0] }), .med = true, .tag = null },
            .{ .text = try std.fmt.allocPrint(a, "[SYNTHETIC] {s}'s prescription for {s} is refilled monthly.", .{ f, drugs[i][1] }), .med = true, .tag = null },
            .{ .text = try std.fmt.allocPrint(a, "[SYNTHETIC] Takes {s} at night to help with sleep.", .{drugs[i][2]}), .med = true, .tag = null },
            .{ .text = try std.fmt.allocPrint(a, "[SYNTHETIC] {s} sees the specialist about the left knee on Fridays.", .{f}), .med = true, .tag = true },
            .{ .text = try std.fmt.allocPrint(a, "[SYNTHETIC] {s}'s favorite color is {s}.", .{ f, colors[i] }), .med = false, .tag = null },
            .{ .text = try std.fmt.allocPrint(a, "[SYNTHETIC] {s} keeps a journal about the garden.", .{f}), .med = false, .tag = null },
        };
        for (rows) |r| {
            const id = try h.write(a, seat, .{ .scope = ps, .subject = p, .text = r.text, .medical = r.tag });
            try out.append(a, .{ .id = id, .scope = ps, .subject = p, .truth = p, .med = r.med, .clean = true, .text = r.text });
        }
        // seat-private notes
        const sn = try std.fmt.allocPrint(a, "[SYNTHETIC] {s} seat note: the playlist is lo-fi beats.", .{f});
        const ss = try std.fmt.allocPrint(a, "seat:{s}", .{seat});
        const sid = try h.write(a, seat, .{ .scope = ss, .subject = p, .text = sn });
        try out.append(a, .{ .id = sid, .scope = ss, .subject = p, .truth = p, .med = false, .clean = true, .text = sn });
    }
    const kn = "[SYNTHETIC] Kitchen timer note: pizza night is Friday.";
    try out.append(a, .{ .id = try h.write(a, "kitchen", .{ .scope = "seat:kitchen", .subject = "household", .text = kn }), .scope = "seat:kitchen", .subject = "household", .truth = "household", .med = false, .clean = true, .text = kn });
    const bm = "[SYNTHETIC] Morgan seat note: dentist recheck in a month.";
    try out.append(a, .{ .id = try h.write(a, "morgan-air", .{ .scope = "seat:morgan-air", .subject = "morgan", .text = bm }), .scope = "seat:morgan-air", .subject = "morgan", .truth = "morgan", .med = true, .clean = true, .text = bm });

    // forced rows (bypass House: what an importer or a broken extractor could leave behind)
    const forced = [_]Truth{
        .{ .scope = "household", .subject = "household", .truth = "household", .med = false, .clean = true, .text = "[SYNTHETIC] The household wifi rule: devices off at 10pm." },
        .{ .scope = "household", .subject = "household", .truth = "household", .med = false, .clean = true, .text = "[SYNTHETIC] Trash goes out Thursday night." },
        .{ .scope = "household", .subject = "morgan", .truth = "morgan", .med = true, .clean = true, .text = "[SYNTHETIC] Morgan's dunatolol dose went up to 40 mg." },
        .{ .scope = "household", .subject = "rowan", .truth = "rowan", .med = true, .clean = true, .text = "[SYNTHETIC] Rowan's ravinoxetine refill is due Friday." },
        .{ .scope = "person:jordan", .subject = "jordan", .truth = "morgan", .med = true, .clean = false, .text = "[SYNTHETIC] Morgan takes 5 mg of zorvatraline at lunch." },
        .{ .scope = "person:rowan", .subject = "morgan", .truth = "morgan", .med = true, .clean = false, .text = "[SYNTHETIC] Mom takes estravexine for migraines." },
        .{ .scope = "person:alex", .subject = "unknown", .truth = "morgan", .med = true, .clean = false, .text = "[SYNTHETIC] User has oral surgery on Tuesday." },
        .{ .scope = "household", .subject = "ext:taylor-r", .truth = "ext:taylor-r", .med = true, .clean = false, .text = "[SYNTHETIC] Taylor from work takes 10 mg of harvacillin for allergies." },
        .{ .scope = "person:taylor", .subject = "taylor", .truth = "taylor-k", .med = true, .clean = false, .text = "[SYNTHETIC] Taylor Kessler takes pentaprazole after dinner." },
        .{ .scope = "person:quinn", .subject = "quinn", .truth = "quinn+jordan", .med = true, .clean = false, .text = "[SYNTHETIC] Quinn and Jordan both take quorvexine." },
        .{ .scope = "work", .subject = "alex", .truth = "alex", .med = false, .clean = true, .text = "[SYNTHETIC] Work note about the shift schedule." },
        .{ .scope = "person:rowan", .subject = "rowan", .truth = "rowan", .med = true, .clean = true, .active = false, .text = "[SYNTHETIC] Rowan used to take selmazolam (retired)." },
        .{ .scope = "person:morgan", .subject = "morgan", .truth = "morgan", .med = true, .clean = true, .active = false, .text = "[SYNTHETIC] Morgan's old bumelapril dose was 10 mg (pending review)." },
    };
    for (forced) |f| {
        var x = f;
        x.id = try store.atoms.insert(h.st, .{ .subject = f.subject, .scope = f.scope, .type = "fact", .text = f.text, .status = if (f.active) .active else .retired, .seat = "fixture-import" });
        try out.append(a, x);
    }
    return out.items;
}

/// The member's own (first) seat.
pub fn owner(p: []const u8) []const u8 {
    for (seats) |s| if (s.member) |m| if (std.mem.eql(u8, m, p)) return s.name;
    unreachable;
}
