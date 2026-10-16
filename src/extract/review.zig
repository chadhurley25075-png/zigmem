//! The reviewer's reply: {"keep":bool,"subject":"…","text":"…"} → a checked verdict. The model proposes; code decides:
//! the subject must be a household member (by name or alias) or "household", and the text must name it. Anything else
//! is "retire" — the pending row stays in the store with an audit row, never served.
const std = @import("std");
const parse = @import("parse.zig");
const people_mod = @import("people.zig");

pub const Verdict = union(enum) {
    /// Re-file: a new active-candidate row with this subject and text (the household write rule still applies).
    resolve: struct { subject: []const u8, text: []const u8 },
    /// Keep the pending row as history only.
    retire: []const u8,
};

const max_text = 1000;

/// A valid reply, or error.BadReview when the JSON is missing or malformed (the caller may retry once).
pub fn decide(a: std.mem.Allocator, people: people_mod.People, raw: []const u8) !Verdict {
    const v = parse.findObject(a, raw, "keep") orelse return error.BadReview;
    const keep = v.object.get("keep") orelse return error.BadReview;
    if (keep != .bool) return error.BadReview;
    if (!keep.bool) return .{ .retire = "reviewer: nothing worth keeping" };
    const subj = v.object.get("subject") orelse return error.BadReview;
    const text = v.object.get("text") orelse return error.BadReview;
    if (subj != .string or text != .string) return error.BadReview;
    const t = std.mem.trim(u8, text.string, " \t\r\n");
    if (t.len == 0 or t.len > max_text) return .{ .retire = "reviewer: empty or oversized text" };
    const sraw = std.mem.trim(u8, subj.string, " \t.\"");
    if (std.ascii.eqlIgnoreCase(sraw, "household")) {
        if (people_mod.mentions(t, "household")) return .{ .resolve = .{ .subject = "household", .text = t } };
        return .{ .retire = "reviewer: household text does not name the household" };
    }
    const id = people.resolve(sraw) orelse return .{ .retire = "reviewer: subject not in the household list" };
    const att = people.attribute(id, t);
    if (att.status != .active) return .{ .retire = att.reason orelse "reviewer: text does not name the subject" };
    for ([_][]const u8{ "Someone", "the speaker", "User" }) |bad| if (people_mod.mentions(t, bad)) return .{ .retire = "reviewer: placeholder subject left in text" };
    return .{ .resolve = .{ .subject = id, .text = t } };
}

test "review verdicts: member, household, keep=false, outsider, placeholder, bad json" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const al = [_][]const u8{"Zee"};
    const list = [_]people_mod.Person{ .{ .id = "amara" }, .{ .id = "zara", .aliases = &al } };
    const p: people_mod.People = .{ .list = &list };
    const r1 = try decide(a, p, "{\"keep\":true,\"subject\":\"Zara\",\"text\":\"Zara's piano teacher is Mr. Okoro.\"}");
    try t.expectEqualStrings("zara", r1.resolve.subject);
    const r2 = try decide(a, p, "sure:\n{\"keep\":true,\"subject\":\"household\",\"text\":\"The household's dog is named Pepper.\"}");
    try t.expectEqualStrings("household", r2.resolve.subject);
    try t.expect((try decide(a, p, "{\"keep\":false}")) == .retire);
    try t.expect((try decide(a, p, "{\"keep\":true,\"subject\":\"Mr. Okoro\",\"text\":\"Mr. Okoro teaches piano.\"}")) == .retire);
    try t.expect((try decide(a, p, "{\"keep\":true,\"subject\":\"zara\",\"text\":\"Someone's teacher is nice.\"}")) == .retire);
    try t.expect((try decide(a, p, "{\"keep\":true,\"subject\":\"zara\",\"text\":\"The teacher is nice.\"}")) == .retire); // text does not name Zara
    try t.expectError(error.BadReview, decide(a, p, "no json here"));
    try t.expectError(error.BadReview, decide(a, p, "{\"keep\":\"yes\"}"));
}
