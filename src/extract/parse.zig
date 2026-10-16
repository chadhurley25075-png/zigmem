//! Bounded JSON recovery + strict schema validation for model output. Rejects on mismatch; never "store everything".
const std = @import("std");

pub const types = [_][]const u8{ "fact", "preference", "event", "instruction", "person" };
pub const max_mems = 12;

pub const Mem = struct {
    subject: []const u8,
    type: []const u8,
    text: []const u8,
    priority: i64,
    valid_from: ?[]const u8,
    turns: []const i64,
    corrects: ?[]const u8,
};

pub const Result = struct {
    mems: []Mem = &.{},
    /// Human-readable problems, fed back verbatim in the one repair retry. Empty = valid.
    errors: []const []const u8 = &.{},
    found_json: bool = false,
    pub fn ok(r: Result) bool {
        return r.found_json and r.errors.len == 0;
    }
};

/// End index (exclusive) of the balanced `{…}` starting at `start`, string/escape aware. Null if unbalanced.
fn balancedEnd(s: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var in_str = false;
    var esc = false;
    var i = start;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_str) {
            if (esc) esc = false else if (c == '\\') esc = true else if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}

/// The first balanced JSON object in `raw` (after any `</think>`) that parses and has top-level `key`.
/// Tries at most 32 opening braces and 256 KB of text: bounded work on hostile output.
pub fn findObject(a: std.mem.Allocator, raw: []const u8, key: []const u8) ?std.json.Value {
    var s = raw;
    if (std.mem.lastIndexOf(u8, s, "</think>")) |p| s = s[p + 8 ..];
    if (s.len > 256 << 10) s = s[0 .. 256 << 10];
    var from: usize = 0;
    var tries: usize = 0;
    while (tries < 32) : (tries += 1) {
        const st = std.mem.indexOfScalarPos(u8, s, from, '{') orelse return null;
        from = st + 1;
        const end = balancedEnd(s, st) orelse continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, s[st..end], .{}) catch continue;
        if (v == .object and v.object.get(key) != null) return v;
    }
    return null;
}

fn isDate(s: []const u8) bool {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return false;
    for (s, 0..) |c, i| if (i != 4 and i != 7 and !std.ascii.isDigit(c)) return false;
    const m = std.fmt.parseInt(u8, s[5..7], 10) catch return false;
    const d = std.fmt.parseInt(u8, s[8..10], 10) catch return false;
    return m >= 1 and m <= 12 and d >= 1 and d <= 31;
}

fn validType(t: []const u8) bool {
    for (types) |k| if (std.mem.eql(u8, k, t)) return true;
    return false;
}

/// Text must be third person and name its subject (the "User has…" mis-attribution class is refused here).
fn textProblem(subject: []const u8, text: []const u8) ?[]const u8 {
    if (text.len < 8) return "text is too short";
    if (text.len > 300) return "text is longer than 300 bytes";
    const lower_bad = [_][]const u8{ "i ", "i'm ", "i've ", "my ", "user ", "the user", "the speaker", "speaker " };
    for (lower_bad) |b| if (text.len >= b.len and std.ascii.eqlIgnoreCase(text[0..b.len], b))
        return "text must be third person and start with or name the subject, never I/my/User/the speaker";
    if (std.ascii.findIgnoreCase(text, "<private") != null or std.ascii.findIgnoreCase(text, "[private") != null)
        return "text must not mention private parts";
    if (std.ascii.eqlIgnoreCase(subject, "unknown")) return null;
    var words = std.mem.tokenizeAny(u8, subject, " .-'");
    while (words.next()) |w| {
        if (w.len >= 3 and std.ascii.findIgnoreCase(text, w) != null) return null;
    }
    return "text must contain the subject's name";
}

const allowed_keys = [_][]const u8{ "subject", "type", "text", "priority", "valid_from", "turns", "corrects" };

/// Parse + validate an extraction reply. `new_ids`: the turn ids marked NEW in the prompt.
pub fn memories(a: std.mem.Allocator, raw: []const u8, new_ids: []const i64) !Result {
    const v = findObject(a, raw, "memories") orelse
        return .{ .found_json = false, .errors = try a.dupe([]const u8, &.{"no JSON object with a \"memories\" key was found"}) };
    var errs: std.ArrayList([]const u8) = .empty;
    var out: std.ArrayList(Mem) = .empty;
    if (v.object.count() != 1) try errs.append(a, "the top-level object must have exactly one key: \"memories\"");
    const arr = v.object.get("memories").?;
    if (arr != .array) {
        try errs.append(a, "\"memories\" must be an array");
        return .{ .found_json = true, .errors = errs.items };
    }
    if (arr.array.items.len > max_mems) try errs.append(a, try std.fmt.allocPrint(a, "at most {d} memories", .{max_mems}));
    for (arr.array.items, 0..) |item, i| {
        if (item != .object) {
            try errs.append(a, try std.fmt.allocPrint(a, "memories[{d}] must be an object", .{i}));
            continue;
        }
        var it = item.object.iterator();
        while (it.next()) |kv| {
            var known = false;
            for (allowed_keys) |k| known = known or std.mem.eql(u8, k, kv.key_ptr.*);
            if (!known) try errs.append(a, try std.fmt.allocPrint(a, "memories[{d}] has unknown key \"{s}\"", .{ i, kv.key_ptr.* }));
        }
        const o = item.object;
        const subj = o.get("subject");
        const typ = o.get("type");
        const txt = o.get("text");
        const pri = o.get("priority");
        const vf = o.get("valid_from");
        const trn = o.get("turns");
        const cor = o.get("corrects");
        var bad = false;
        if (subj == null or subj.? != .string or subj.?.string.len == 0 or subj.?.string.len > 48) {
            try errs.append(a, try std.fmt.allocPrint(a, "memories[{d}].subject must be a name string (1-48 bytes) or \"unknown\"", .{i}));
            bad = true;
        }
        if (typ == null or typ.? != .string or !validType(typ.?.string)) {
            try errs.append(a, try std.fmt.allocPrint(a, "memories[{d}].type must be one of fact, preference, event, instruction, person", .{i}));
            bad = true;
        }
        if (txt == null or txt.? != .string) {
            try errs.append(a, try std.fmt.allocPrint(a, "memories[{d}].text must be a string", .{i}));
            bad = true;
        } else if (!bad) {
            if (textProblem(subj.?.string, txt.?.string)) |p| {
                try errs.append(a, try std.fmt.allocPrint(a, "memories[{d}].{s}", .{ i, p }));
                bad = true;
            }
        }
        if (pri == null or pri.? != .integer or pri.?.integer < 0 or pri.?.integer > 100) {
            try errs.append(a, try std.fmt.allocPrint(a, "memories[{d}].priority must be an integer 0-100", .{i}));
            bad = true;
        }
        if (vf != null and !(vf.? == .null or (vf.? == .string and isDate(vf.?.string)))) {
            try errs.append(a, try std.fmt.allocPrint(a, "memories[{d}].valid_from must be null or YYYY-MM-DD", .{i}));
            bad = true;
        }
        if (cor != null and !(cor.? == .null or (cor.? == .string and cor.?.string.len <= 300))) {
            try errs.append(a, try std.fmt.allocPrint(a, "memories[{d}].corrects must be null or a short string", .{i}));
            bad = true;
        }
        var turns: std.ArrayList(i64) = .empty;
        if (trn == null or trn.? != .array or trn.?.array.items.len == 0) {
            try errs.append(a, try std.fmt.allocPrint(a, "memories[{d}].turns must be a non-empty array of NEW turn ids", .{i}));
            bad = true;
        } else for (trn.?.array.items) |x| {
            const ok_id = x == .integer and std.mem.indexOfScalar(i64, new_ids, x.integer) != null;
            if (!ok_id) {
                try errs.append(a, try std.fmt.allocPrint(a, "memories[{d}].turns may only list NEW turn ids", .{i}));
                bad = true;
                break;
            }
            try turns.append(a, x.integer);
        }
        if (bad) continue;
        try out.append(a, .{
            .subject = subj.?.string,
            .type = typ.?.string,
            .text = std.mem.trim(u8, txt.?.string, " \t\r\n"),
            .priority = pri.?.integer,
            .valid_from = if (vf != null and vf.? == .string) vf.?.string else null,
            .turns = turns.items,
            .corrects = if (cor != null and cor.? == .string and cor.?.string.len > 0) cor.?.string else null,
        });
    }
    return .{ .found_json = true, .mems = out.items, .errors = errs.items };
}

pub const Action = enum { store, skip, supersede, correct };
pub const Decision = struct { action: Action, target: ?i64 };

pub const DResult = struct {
    decisions: []Decision = &.{},
    errors: []const []const u8 = &.{},
    pub fn ok(r: DResult) bool {
        return r.errors.len == 0;
    }
};

/// Dedup decisions: exactly one per new memory, targets only from THAT memory's own candidate ids (SPEC §1.3).
pub fn decisions(a: std.mem.Allocator, raw: []const u8, cand_ids: []const []const i64) !DResult {
    const v = findObject(a, raw, "decisions") orelse
        return .{ .errors = try a.dupe([]const u8, &.{"no JSON object with a \"decisions\" key was found"}) };
    var errs: std.ArrayList([]const u8) = .empty;
    const arr = v.object.get("decisions").?;
    if (arr != .array) return .{ .errors = try a.dupe([]const u8, &.{"\"decisions\" must be an array"}) };
    const out = try a.alloc(Decision, cand_ids.len);
    const seen = try a.alloc(bool, cand_ids.len);
    @memset(seen, false);
    for (arr.array.items, 0..) |item, i| {
        if (item != .object) {
            try errs.append(a, try std.fmt.allocPrint(a, "decisions[{d}] must be an object", .{i}));
            continue;
        }
        const n = item.object.get("new");
        const act = item.object.get("action");
        const tgt = item.object.get("target");
        if (n == null or n.? != .integer or n.?.integer < 0 or n.?.integer >= cand_ids.len) {
            try errs.append(a, try std.fmt.allocPrint(a, "decisions[{d}].new must be the index of a NEW memory", .{i}));
            continue;
        }
        const k: usize = @intCast(n.?.integer);
        if (seen[k]) {
            try errs.append(a, try std.fmt.allocPrint(a, "decisions has two entries for new={d}", .{k}));
            continue;
        }
        const action = if (act != null and act.? == .string) std.meta.stringToEnum(Action, act.?.string) else null;
        if (action == null) {
            try errs.append(a, try std.fmt.allocPrint(a, "decisions[{d}].action must be store, skip, supersede or correct", .{i}));
            continue;
        }
        var target: ?i64 = null;
        if (action.? == .supersede or action.? == .correct or action.? == .skip) {
            if (tgt == null or tgt.? != .integer or std.mem.indexOfScalar(i64, cand_ids[k], tgt.?.integer) == null) {
                try errs.append(a, try std.fmt.allocPrint(a, "decisions[{d}].target must be one of the candidate ids listed for new={d}", .{ i, k }));
                continue;
            }
            target = tgt.?.integer;
        }
        seen[k] = true;
        out[k] = .{ .action = action.?, .target = target };
    }
    for (seen, 0..) |s, k| if (!s) try errs.append(a, try std.fmt.allocPrint(a, "missing decision for new={d}", .{k}));
    return .{ .decisions = out, .errors = errs.items };
}

test "findObject: think tags, junk around, fences, reasoning leaked into content" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const u8{
        "{\"memories\":[]}",
        "<think>maybe {\"memories\":[1]</think>\n```json\n{\"memories\":[]}\n```",
        "{\"ok\":1} We need answer JSON only. {\"memories\":[]} trailing {",
        "Sure! Here: {\"memories\": [], } oops {\"memories\":[]}",
        "{\"a\":\"}{\\\"\"} {\"memories\":[]}",
    };
    for (cases) |c| try std.testing.expect(findObject(a, c, "memories") != null);
    try std.testing.expect(findObject(a, "no json here", "memories") == null);
    try std.testing.expect(findObject(a, "{\"memories\":[}", "memories") == null);
    var deep: std.ArrayList(u8) = .empty;
    for (0..5000) |_| try deep.append(a, '{');
    try std.testing.expect(findObject(a, deep.items, "memories") == null);
}

test "memories: strict schema, third-person, turn ids, repair messages" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ids = [_]i64{ 13, 14 };
    const good = "{\"memories\":[{\"subject\":\"Leo\",\"type\":\"event\",\"text\":\"Leo has soccer on Tuesdays.\",\"priority\":40,\"valid_from\":\"2026-10-03\",\"turns\":[14],\"corrects\":\"was Wednesdays\"}]}";
    const r = try memories(a, good, &ids);
    try std.testing.expect(r.ok());
    try std.testing.expectEqualStrings("was Wednesdays", r.mems[0].corrects.?);
    const bads = [_][]const u8{
        "{\"memories\":[{\"subject\":\"Leo\",\"type\":\"event\",\"text\":\"Leo has soccer.\",\"priority\":40,\"turns\":[99]}]}", // id not shown
        "{\"memories\":[{\"subject\":\"Leo\",\"type\":\"vibe\",\"text\":\"Leo has soccer.\",\"priority\":40,\"turns\":[14]}]}",
        "{\"memories\":[{\"subject\":\"Morgan\",\"type\":\"fact\",\"text\":\"User has oral surgery.\",\"priority\":80,\"turns\":[14]}]}",
        "{\"memories\":[{\"subject\":\"Morgan\",\"type\":\"fact\",\"text\":\"I like tea a lot.\",\"priority\":20,\"turns\":[14]}]}",
        "{\"memories\":[{\"subject\":\"Morgan\",\"type\":\"fact\",\"text\":\"Alex likes tea a lot.\",\"priority\":20,\"turns\":[14]}]}", // names someone else
        "{\"memories\":[{\"subject\":\"Leo\",\"type\":\"event\",\"text\":\"Leo has soccer.\",\"priority\":\"high\",\"turns\":[14]}]}",
        "{\"memories\":[{\"subject\":\"Leo\",\"type\":\"event\",\"text\":\"Leo has soccer.\",\"priority\":40,\"turns\":[14],\"delete\":[3]}]}",
        "{\"memories\":[{\"subject\":\"Leo\",\"type\":\"event\",\"text\":\"Leo has soccer.\",\"priority\":40,\"turns\":[14],\"valid_from\":\"next week\"}]}",
        "{\"memories\":[],\"delete_ids\":[1,2]}",
        "{\"memories\":{}}",
        "nothing",
    };
    for (bads) |b| {
        const x = try memories(a, b, &ids);
        try std.testing.expect(!x.ok());
        try std.testing.expect(x.errors.len > 0);
    }
    const unk = try memories(a, "{\"memories\":[{\"subject\":\"unknown\",\"type\":\"fact\",\"text\":\"Someone is allergic to shellfish.\",\"priority\":80,\"turns\":[13]}]}", &ids);
    try std.testing.expect(unk.ok());
}

test "decisions: targets must come from that memory's own candidates" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c0 = [_]i64{ 4, 9 };
    const c1 = [_]i64{7};
    const cands = [_][]const i64{ &c0, &c1 };
    const ok = try decisions(a, "{\"decisions\":[{\"new\":0,\"action\":\"supersede\",\"target\":9},{\"new\":1,\"action\":\"store\",\"target\":null}]}", &cands);
    try std.testing.expect(ok.ok());
    try std.testing.expectEqual(@as(i64, 9), ok.decisions[0].target.?);
    const out_of_set = try decisions(a, "{\"decisions\":[{\"new\":0,\"action\":\"correct\",\"target\":7},{\"new\":1,\"action\":\"store\"}]}", &cands);
    try std.testing.expect(!out_of_set.ok()); // 7 belongs to new=1, not new=0
    const missing = try decisions(a, "{\"decisions\":[{\"new\":0,\"action\":\"store\"}]}", &cands);
    try std.testing.expect(!missing.ok());
    const del = try decisions(a, "{\"decisions\":[{\"new\":0,\"action\":\"delete\",\"target\":4},{\"new\":1,\"action\":\"store\"}]}", &cands);
    try std.testing.expect(!del.ok());
}
