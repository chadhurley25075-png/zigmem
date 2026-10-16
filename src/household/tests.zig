//! Phase-5 unit tests (offline, SYNTHETIC data only, throwaway databases under .zig-cache/tmp).
const std = @import("std");
const t = std.testing;
const store = @import("store");
const policy = @import("policy.zig");
const resolve = @import("resolve.zig");
const House = @import("house.zig").House;
const fixture = @import("fixture.zig");

fn reg() policy.Registry {
    const ms = comptime blk: {
        var out: [fixture.members.len]policy.Member = undefined;
        for (fixture.members, 0..) |m, i| out[i] = .{ .id = m.id, .display = m.display, .aliases = m.aliases, .role = m.role };
        break :blk out;
    };
    return .{ .members = &ms, .seats = &fixture.seats };
}
const rel: resolve.Relations = .{ .mother = "morgan", .father = "alex" };

fn act(seat: []const u8) policy.Actor {
    return policy.actorFor(reg(), seat) catch unreachable;
}

fn expectTarget(seat: []const u8, q: []const u8, want: ?[]const u8) !void {
    const got = resolve.target(reg(), rel, act(seat), q);
    if (want) |w| {
        if (got != .person) std.debug.print("q=\"{s}\" seat={s} got {s} want {s}\n", .{ q, seat, @tagName(got), w });
        try t.expect(got == .person);
        try t.expectEqualStrings(w, got.person);
    } else {
        if (got != .none) std.debug.print("q=\"{s}\" seat={s} got {s} want none\n", .{ q, seat, @tagName(got) });
        try t.expect(got == .none);
    }
}

/// A set answer: `all` = every member the seat may see; otherwise exactly the ids listed (and nobody else).
fn expectMany(seat: []const u8, q: []const u8, all: bool, ids: []const []const u8) !void {
    const got = resolve.target(reg(), rel, act(seat), q);
    if (got != .many) std.debug.print("q=\"{s}\" seat={s} got {s} want many\n", .{ q, seat, @tagName(got) });
    try t.expect(got == .many);
    try t.expectEqual(all, got.many.all);
    if (all) return;
    for (fixture.person_ids) |id| {
        var want = false;
        for (ids) |x| if (std.mem.eql(u8, x, id)) {
            want = true;
        };
        try t.expectEqual(want, got.many.has(reg(), id));
    }
}

test "policy: principals full authority, children their own scopes, household never written directly" {
    const morgan = act("morgan-air");
    const rowan = act("rowan-phone");
    const kitchen = act("kitchen");
    const guest = act("guest-phone");
    for ([_][]const u8{ "household", "person:rowan", "person:alex", "seat:rowan-phone", "seat:kitchen" }) |s| try t.expect(policy.mayRead(morgan, s));
    try t.expect(!policy.mayRead(morgan, "work"));
    try t.expect(policy.mayRead(rowan, "person:rowan") and policy.mayRead(rowan, "household") and policy.mayRead(rowan, "seat:rowan-phone"));
    for ([_][]const u8{ "person:quinn", "person:morgan", "seat:quinn-mac", "seat:kitchen", "work" }) |s| try t.expect(!policy.mayRead(rowan, s));
    try t.expect(policy.mayRead(kitchen, "household") and !policy.mayRead(kitchen, "person:rowan"));
    try t.expect(!policy.mayRead(guest, "household") and policy.mayRead(guest, "person:taylor-k"));
    for ([_]policy.Actor{ morgan, rowan, kitchen, guest }) |x| try t.expect(!policy.mayWrite(x, "household"));
    try t.expect(policy.mayWrite(morgan, "person:rowan") and !policy.mayWrite(rowan, "person:quinn"));
    try t.expect(policy.isCross(morgan, "person:rowan") and !policy.isCross(rowan, "person:rowan") and !policy.isCross(rowan, "household"));
}

test "resolve: names, the two Taylors, pronouns, relatives by asker, self, groups" {
    try expectTarget("rowan-phone", "what meds does Morgan take", "morgan");
    try expectTarget("rowan-phone", "Morgana's prescription", "morgan");
    try expectTarget("alex-term", "what meds does Taylor take", null); // the daughter or the guest?
    try expectTarget("alex-term", "Taylor Harper's meds", "taylor");
    try expectTarget("alex-term", "Tay's meds", "taylor");
    try expectTarget("alex-term", "Taylor Kessler's meds", "taylor-k");
    try expectTarget("alex-term", "Taylor K meds", "taylor-k");
    try expectTarget("rowan-phone", "what does she take", null);
    try expectTarget("rowan-phone", "is he on anything", null);
    // integration: a principal's pronoun resolves to the one member named; a child's never does
    try expectTarget("morgan-air", "Rowan takes her meds with breakfast?", "rowan");
    try expectTarget("taylor-phone", "Rowan takes her meds with breakfast?", null);
    try expectTarget("morgan-air", "Rowan and Quinn: does she take them?", null);
    try expectTarget("morgan-air", "does she take my meds, Rowan?", null);
    try expectTarget("rowan-phone", "what does my mom take", "morgan");
    try expectTarget("rowan-phone", "dad's pills", "alex");
    try expectMany("alex-term", "what does my mom take", true, &.{}); // Alex's mother is not in the household: a set, so text search, never a medical row
    try expectTarget("alex-term", "my wife's dose", "morgan");
    try expectTarget("morgan-air", "my husband's dose", "alex");
    try expectMany("morgan-air", "my wife's dose", true, &.{});
    try expectMany("rowan-phone", "my sister's meds", true, &.{});
    try expectTarget("rowan-phone", "what meds do I take", "rowan");
    try expectTarget("kitchen", "what meds do I take", null);
    try expectTarget("kitchen", "list the medications", null);
    try expectTarget("quinn-mac", "list the medications", "quinn");
    try expectMany("morgan-air", "who takes zorvatraline", true, &.{});
    try expectMany("morgan-air", "does Morgan take more than Rowan", false, &.{ "morgan", "rowan" });
    try expectMany("rowan-phone", "is Morgan's dose higher than mine", false, &.{ "morgan", "rowan" });
    try expectTarget("rowan-phone", "Alexis's meds", "rowan"); // not a name match → the asker
    // one named member wins over a group or relative word in the same question (clean-slate fix 4)
    try expectTarget("morgan-air", "Who is Rowan's teacher at school?", "rowan");
    try expectTarget("morgan-air", "What is Quinn's mother's name?", "quinn");
    try expectMany("rowan-phone", "who is my coach", true, &.{}); // "my coach" qualifies an outsider word: a set, not the asker
    try expectMany("morgan-air", "When is Alex and Morgan's anniversary?", false, &.{ "alex", "morgan" });
    try expectMany("morgan-air", "where does the family shop", true, &.{});
    try expectTarget("morgan-air", "what does the dog eat", "morgan"); // nobody named: about the asker (a row whose subject is not a member passes the gate anyway)
    try expectTarget("alex-term", "what meds does Taylor take", null); // still fail-closed: the daughter or the guest?
}

test "gate: a set target serves personal rows about its members, never a medical row, never a line naming an outsider" {
    const d = try Db.init();
    defer d.deinit();
    const a = d.arena.allocator();
    const h = try House.init(&d.st);
    _ = try fixture.load(a, h);
    const rows = [_]@import("house.zig").Row{
        .{ .id = -1, .scope = "person:rowan", .subject = "rowan", .text = "[SYNTHETIC] Rowan's piano teacher is Ms. Vale." },
        .{ .id = -2, .scope = "person:quinn", .subject = "quinn", .text = "[SYNTHETIC] Quinn's favorite color is sage." },
        .{ .id = -3, .scope = "person:rowan", .subject = "rowan", .text = "[SYNTHETIC] Rowan takes 10 mg of ravinoxetine." },
        .{ .id = -4, .scope = "person:rowan", .subject = "rowan", .text = "[SYNTHETIC] Rowan and Jordan share a room." },
        .{ .id = -5, .scope = "person:morgan", .subject = "morgan", .text = "[SYNTHETIC] Morgan and Rowan went to the harbor on June 5th." },
    };
    // a group word from a principal: every non-medical row whose subject the seat may see; the medical row is dropped
    const g1 = try h.gateFor(a, "morgan-air", "who has a piano teacher", &rows);
    try t.expect(g1.target == .many and g1.target.many.all);
    try t.expectEqual(@as(usize, 4), g1.rows.len);
    try t.expectEqual(@as(usize, 1), g1.drops.medical_no_target);
    for (g1.rows) |r| try t.expect(r.id != -3);
    // two names: rows about either, but a line naming a member outside the pair (Jordan) is withheld
    const g2 = try h.gateFor(a, "morgan-air", "Morgan and Rowan", &rows);
    try t.expect(g2.target == .many and !g2.target.many.all);
    try t.expectEqual(@as(usize, 2), g2.rows.len);
    for (g2.rows) |r| try t.expect(r.id == -1 or r.id == -5);
    // one named member beside a relative word: that member only (a principal may see Rowan's medical row for a
    // one-person target; the line naming Jordan is withheld)
    const g3 = try h.gateFor(a, "morgan-air", "who is Rowan's teacher", &rows);
    try t.expect(g3.target == .person);
    try t.expectEqual(@as(usize, 2), g3.rows.len);
    for (g3.rows) |r| try t.expect(r.id == -1 or r.id == -3);
    // a child's seat with a group word still sees only its own scopes
    const g4 = try h.gateFor(a, "rowan-phone", "who has a piano teacher", &rows);
    for (g4.rows) |r| try t.expect(std.mem.eql(u8, r.scope, "person:rowan"));
    try t.expectEqual(@as(usize, 2), g4.rows.len); // -1 and -4 (names Jordan, but all members are in the set); -3 medical
}

test "row names: an ambiguous span counts for whoever the subject column says, never for an outsider" {
    const r = reg();
    const n = resolve.named(r, "Taylor takes 20 mg of velmoprazole");
    try t.expect(n.ambiguous and !n.other(r, "taylor") and !n.other(r, "taylor-k") and n.other(r, "rowan"));
    const k = resolve.named(r, "Taylor Kessler takes pentaprazole");
    try t.expect(!k.ambiguous and k.other(r, "taylor") and !k.other(r, "taylor-k"));
    const two = resolve.named(r, "Quinn and Jordan both take quorvexine");
    try t.expect(two.other(r, "quinn") and two.other(r, "jordan"));
}

const Db = struct {
    tmp: t.TmpDir,
    path: [:0]u8,
    st: store.Store,
    arena: std.heap.ArenaAllocator,

    fn init() !*Db {
        const d = try t.allocator.create(Db);
        d.tmp = t.tmpDir(.{});
        d.path = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/hh.db", .{d.tmp.sub_path}, 0);
        d.arena = .init(t.allocator);
        d.st = try store.Store.open(d.arena.allocator(), t.io, d.path, .{});
        return d;
    }
    fn deinit(d: *Db) void {
        d.st.close();
        d.arena.deinit();
        t.allocator.free(d.path);
        d.tmp.cleanup();
        t.allocator.destroy(d);
    }
};

fn medRows(rows: []const @import("house.zig").Row) usize {
    var n: usize = 0;
    for (rows) |r| if (@import("medical.zig").isMedical(r.text)) {
        n += 1;
    };
    return n;
}

test "store-backed: a kid seat never gets Morgan's meds; Morgan does; revocation is live; cross reads audited" {
    const d = try Db.init();
    defer d.deinit();
    const a = d.arena.allocator();
    const h = try House.init(&d.st);
    _ = try fixture.load(a, h);
    const kid = try h.recall(a, "rowan-phone", "what meds does Morgan take", .{});
    try t.expectEqual(@as(usize, 0), medRows(kid.rows));
    try t.expectError(error.Forbidden, h.recall(a, "rowan-phone", "what meds does Morgan take", .{ .requested = &.{"person:morgan"} }));
    const mom = try h.recall(a, "morgan-air", "what meds does Morgan take", .{});
    try t.expect(medRows(mom.rows) >= 2);
    for (mom.rows) |r| try t.expect(!std.mem.eql(u8, r.subject, "jordan") and !std.mem.eql(u8, r.subject, "unknown"));
    const before = (try d.st.db.oneInt("SELECT count(*) FROM audit WHERE action = 'xread'", .{})).?;
    _ = try h.recall(a, "morgan-air", "Rowan favorite color", .{ .requested = &.{"person:rowan"} });
    try t.expectEqual(before + 1, (try d.st.db.oneInt("SELECT count(*) FROM audit WHERE action = 'xread'", .{})).?);
    _ = try h.recall(a, "rowan-phone", "Rowan favorite color", .{ .requested = &.{"person:rowan"} });
    try t.expectEqual(before + 1, (try d.st.db.oneInt("SELECT count(*) FROM audit WHERE action = 'xread'", .{})).?);
    _ = try h.recall(a, "guest-phone", "favorite color", .{});
    try h.revokeMember(a, "morgan-air", "taylor-k");
    try t.expectError(error.MemberRevoked, h.recall(a, "guest-phone", "favorite color", .{}));
    try t.expectError(error.PrincipalNotRevocable, h.revokeMember(a, "alex-term", "morgan"));
    try t.expectError(error.Forbidden, h.write(a, "morgan-air", .{ .scope = "household", .subject = "household", .text = "[SYNTHETIC] x" }));
}

test "no hard delete reachable from household code" {
    for ([_][]const u8{ @embedFile("house.zig"), @embedFile("policy.zig"), @embedFile("schema.zig"), @embedFile("resolve.zig") }) |src|
        try t.expect(std.mem.indexOf(u8, src, "DELETE " ++ "FROM") == null);
}
