//! Offline pipeline tests: a scripted stub engine (no network) drives correction, private, repair and judge-safety paths.
const std = @import("std");
const allow = @import("allow.zig");
const llm = @import("llm.zig");
const pipeline = @import("pipeline.zig");
const people_mod = @import("people.zig");
const sink_mod = @import("sink.zig");

const Script = struct {
    replies: []const []const u8,
    i: usize = 0,
    bodies: std.ArrayList([]const u8) = .empty,
    a: std.mem.Allocator,

    fn f(ctx: *anyopaque, body: []const u8) []const u8 {
        const s: *Script = @ptrCast(@alignCast(ctx));
        s.bodies.append(s.a, s.a.dupe(u8, body) catch unreachable) catch unreachable;
        if (s.i >= s.replies.len) return "{\"memories\":[]}";
        s.i += 1;
        return s.replies[s.i - 1];
    }
};

const plist = [_]people_mod.Person{ .{ .id = "Alex" }, .{ .id = "Morgan" }, .{ .id = "Leo" } };

fn mk(sc: *Script, client: *llm.Client, ms: *sink_mod.MemSink) pipeline.Pipeline {
    client.* = .{ .stub = .{ .ctx = sc, .f = Script.f }, .canaries = &.{"CANARY"} };
    return pipeline.Pipeline.init(std.testing.allocator, .{ .extractor = allow.primary, .judge = allow.secondary, .scope = "syn", .people = .{ .list = &plist }, .today = "2026-10-12", .run_id = "t" }, client, ms.sink());
}

fn turn(id: i64, speaker: []const u8, text: []const u8) pipeline.Turn {
    return .{ .id = id, .session = "s", .speaker = speaker, .role = "user", .date = "2026-10-03", .text = text };
}

test "correction: 'it was Alex's truck, not Morgan's car' demotes the Morgan row, keeps it, inserts Alex" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sc: Script = .{ .a = a, .replies = &.{
        "{\"memories\":[{\"subject\":\"Morgan\",\"type\":\"fact\",\"text\":\"Morgan's car needs new tires.\",\"priority\":50,\"valid_from\":null,\"turns\":[1],\"corrects\":null}]}",
        "{\"memories\":[{\"subject\":\"Alex\",\"type\":\"fact\",\"text\":\"Alex's truck needs new tires.\",\"priority\":50,\"valid_from\":null,\"turns\":[2],\"corrects\":\"it was Morgan's car\"}]}",
        "{\"decisions\":[{\"new\":0,\"action\":\"correct\",\"target\":1}]}",
    } };
    var client: llm.Client = undefined;
    var ms = sink_mod.MemSink.init(std.testing.allocator);
    defer ms.deinit();
    var p = mk(&sc, &client, &ms);
    defer p.deinit();
    _ = try p.process(a, turn(1, "Alex", "Morgan's car needs new tires."));
    const lg = try p.process(a, turn(2, "Alex", "Actually it was my truck that needs the tires, not Morgan's car."));
    try std.testing.expectEqualStrings("correct", lg.applied.items[0].action);
    try std.testing.expectEqual(@as(usize, 2), ms.rows.items.len);
    try std.testing.expectEqual(sink_mod.Status.retired, ms.rows.items[0].status);
    try std.testing.expectEqual(@as(i64, 2), ms.rows.items[0].demoted_by.?);
    try std.testing.expectEqual(sink_mod.Status.active, ms.rows.items[1].status);
    try std.testing.expectEqualStrings("Alex", ms.rows.items[1].row.subject);
    try std.testing.expect(ms.rows.items[1].row.prov.turn_id == 2);
    try std.testing.expect(std.mem.indexOf(u8, sc.bodies.items[1], "BACKGROUND") != null); // turn 1 was context
}

test "private text never reaches the engine; an all-private turn makes no call" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sc: Script = .{ .a = a, .replies = &.{} };
    var client: llm.Client = undefined;
    var ms = sink_mod.MemSink.init(std.testing.allocator);
    defer ms.deinit();
    var p = mk(&sc, &client, &ms);
    defer p.deinit();
    _ = try p.process(a, turn(1, "Alex", "<private>CANARY-1 secret</private> Leo has a recital."));
    const l2 = try p.process(a, turn(2, "Alex", "< Private >CANARY-2 and no closing tag"));
    try std.testing.expectEqualStrings("nothing left after private strip", l2.skipped.?);
    _ = try p.process(a, turn(3, "Alex", "Leo likes trains.")); // turn 1 is now BACKGROUND: still stripped
    try std.testing.expectEqual(@as(usize, 2), sc.bodies.items.len);
    for (sc.bodies.items) |b| try std.testing.expect(std.mem.indexOf(u8, b, "CANARY") == null);
    try std.testing.expectEqual(@as(u32, 0), client.canary_hits);
}

test "invalid twice → no active rows; valid items of a failed reply land pending_review; assistant turns skipped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mixed = "{\"memories\":[{\"subject\":\"Leo\",\"type\":\"event\",\"text\":\"Leo has a recital Friday.\",\"priority\":50,\"turns\":[2]},{\"subject\":\"Leo\",\"type\":\"bogus\",\"text\":\"x\",\"priority\":5,\"turns\":[2]}]}";
    var sc: Script = .{ .a = a, .replies = &.{ "not json", "still not json", mixed, mixed } };
    var client: llm.Client = undefined;
    var ms = sink_mod.MemSink.init(std.testing.allocator);
    defer ms.deinit();
    var p = mk(&sc, &client, &ms);
    defer p.deinit();
    const l1 = try p.process(a, turn(1, "Alex", "Leo has a thing."));
    try std.testing.expect(!l1.valid_first.? and !l1.valid_final.?);
    try std.testing.expectEqual(@as(usize, 2), l1.calls.items.len);
    const l2 = try p.process(a, turn(2, "Alex", "Leo has a recital Friday."));
    try std.testing.expect(!l2.valid_final.?);
    try std.testing.expectEqual(@as(usize, 1), ms.rows.items.len);
    try std.testing.expectEqual(sink_mod.Status.pending_review, ms.rows.items[0].status);
    var t3 = turn(3, "Assistant", "I noted Alex likes aisle seats.");
    t3.role = "assistant";
    const l3 = try p.process(a, t3);
    try std.testing.expectEqualStrings("not a user turn", l3.skipped.?);
    try std.testing.expectEqual(@as(usize, 4), sc.bodies.items.len);
}

test "judge naming an id outside the candidate set (twice) cannot touch any row" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sc: Script = .{ .a = a, .replies = &.{
        "{\"memories\":[{\"subject\":\"Leo\",\"type\":\"event\",\"text\":\"Leo has soccer practice on Wednesdays.\",\"priority\":50,\"turns\":[1]}]}",
        "{\"memories\":[{\"subject\":\"Morgan\",\"type\":\"fact\",\"text\":\"Morgan likes green tea.\",\"priority\":50,\"turns\":[2]}]}",
        "{\"memories\":[{\"subject\":\"Leo\",\"type\":\"event\",\"text\":\"Leo has soccer practice on Tuesdays.\",\"priority\":50,\"turns\":[3]}]}",
        "{\"decisions\":[{\"new\":0,\"action\":\"supersede\",\"target\":2}]}",
        "{\"decisions\":[{\"new\":0,\"action\":\"correct\",\"target\":2}]}",
    } };
    var client: llm.Client = undefined;
    var ms = sink_mod.MemSink.init(std.testing.allocator);
    defer ms.deinit();
    var p = mk(&sc, &client, &ms);
    defer p.deinit();
    _ = try p.process(a, turn(1, "Alex", "Leo's soccer practice is Wednesdays."));
    _ = try p.process(a, turn(2, "Morgan", "I like green tea."));
    const l3 = try p.process(a, turn(3, "Alex", "Leo's soccer practice is Tuesdays now."));
    try std.testing.expect(!l3.judge_valid.?);
    try std.testing.expectEqual(sink_mod.Status.active, ms.rows.items[0].status);
    try std.testing.expectEqual(sink_mod.Status.active, ms.rows.items[1].status); // Morgan row (id 2) untouched
    try std.testing.expectEqual(sink_mod.Status.pending_review, ms.rows.items[2].status);
    try std.testing.expectEqual(@as(usize, 3), ms.rows.items.len);
}

test "exact duplicate is skipped in code with no judge call" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = "{\"memories\":[{\"subject\":\"Leo\",\"type\":\"event\",\"text\":\"Leo has soccer practice on Tuesdays.\",\"priority\":50,\"turns\":[ID]}]}";
    var sc: Script = .{ .a = a, .replies = &.{ try std.mem.replaceOwned(u8, a, m, "ID", "1"), try std.mem.replaceOwned(u8, a, m, "ID", "2") } };
    var client: llm.Client = undefined;
    var ms = sink_mod.MemSink.init(std.testing.allocator);
    defer ms.deinit();
    var p = mk(&sc, &client, &ms);
    defer p.deinit();
    _ = try p.process(a, turn(1, "Alex", "Leo's soccer is Tuesdays."));
    const l2 = try p.process(a, turn(2, "Alex", "Leo's soccer practice is on Tuesdays."));
    try std.testing.expectEqualStrings("skip", l2.applied.items[0].action);
    try std.testing.expectEqual(@as(usize, 1), l2.calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), ms.rows.items.len);
}

test "cross-scope: a principal's update about a child supersedes the child's own atom, in the child's scope" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sc: Script = .{ .a = a, .replies = &.{
        "{\"memories\":[{\"subject\":\"Leo\",\"type\":\"fact\",\"text\":\"Leo's piano teacher is Ms. Vale.\",\"priority\":50,\"valid_from\":null,\"turns\":[1],\"corrects\":null}]}",
        "{\"memories\":[{\"subject\":\"Leo\",\"type\":\"fact\",\"text\":\"Leo's piano teacher is now Mr. Okoro.\",\"priority\":50,\"valid_from\":\"2026-10-03\",\"turns\":[2],\"corrects\":null}]}",
        "{\"decisions\":[{\"new\":0,\"action\":\"supersede\",\"target\":1}]}",
    } };
    var client: llm.Client = undefined;
    var ms = sink_mod.MemSink.init(std.testing.allocator);
    defer ms.deinit();
    var p = mk(&sc, &client, &ms);
    defer p.deinit();
    p.cfg.scope = "person:leo"; // Leo's own seat
    _ = try p.process(a, turn(1, "Leo", "My piano teacher is Ms. Vale."));
    p.cfg.scope = "person:morgan"; // a parent's seat, later
    const lg = try p.process(a, turn(2, "Morgan", "Leo's piano teacher is now Mr. Okoro."));
    try std.testing.expectEqualStrings("supersede", lg.applied.items[0].action);
    try std.testing.expectEqual(@as(usize, 2), ms.rows.items.len);
    try std.testing.expectEqual(sink_mod.Status.superseded, ms.rows.items[0].status);
    try std.testing.expectEqual(@as(i64, 2), ms.rows.items[0].superseded_by.?);
    try std.testing.expectEqualStrings("person:leo", ms.rows.items[1].row.scope); // the new version lives where the old one did
    try std.testing.expectEqual(ms.rows.items[0].lineage, ms.rows.items[1].lineage);
    try std.testing.expect(std.mem.indexOf(u8, sc.bodies.items[2], "id=1") != null); // the child's atom was a candidate
}

test "reviewed memory: same candidates and judge as extraction; a supersede retires the stale row" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sc: Script = .{ .a = a, .replies = &.{
        "{\"memories\":[{\"subject\":\"Alex\",\"type\":\"fact\",\"text\":\"Alex's family dog is named Rex.\",\"priority\":50,\"valid_from\":null,\"turns\":[1],\"corrects\":null}]}",
        "{\"decisions\":[{\"new\":0,\"action\":\"supersede\",\"target\":1}]}",
    } };
    var client: llm.Client = undefined;
    var ms = sink_mod.MemSink.init(std.testing.allocator);
    defer ms.deinit();
    var p = mk(&sc, &client, &ms);
    defer p.deinit();
    _ = try p.process(a, turn(1, "Alex", "Our family dog is named Rex."));
    // the reviewer settled the subject of a pending row (no attribution step, no extraction call)
    const lg = try p.applyReviewed(a, turn(2, "Alex", "We renamed the family dog Rex to Pepper."), .{ .subject = "Alex", .type = "fact", .text = "Alex's family dog is now named Pepper.", .priority = 50, .valid_from = "2026-10-03", .turns = &.{2}, .corrects = null });
    try std.testing.expectEqualStrings("supersede", lg.applied.items[0].action);
    try std.testing.expectEqual(@as(usize, 1), lg.calls.items.len); // the judge only
    try std.testing.expectEqual(sink_mod.Status.superseded, ms.rows.items[0].status);
    try std.testing.expectEqual(sink_mod.Status.active, ms.rows.items[1].status);
    try std.testing.expectEqual(@as(usize, 2), sc.bodies.items.len);
}
