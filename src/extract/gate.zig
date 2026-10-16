//! zigmem-extractgate: run the fixed synthetic turn set through the pipeline and print JSON lines (turn logs, rows,
//! summary) for tests/extract/grade.py. Talks only to allowlisted engines; writes only to its own scratch DB.
const std = @import("std");
const store = @import("store");
const allow = @import("allow.zig");
const llm = @import("llm.zig");
const people_mod = @import("people.zig");
const sink_mod = @import("sink.zig");
const pipeline = @import("pipeline.zig");
const StoreSink = @import("store_sink.zig").StoreSink;

const usage = "usage: zigmem-extractgate --set FILE --extract primary|secondary --judge primary|secondary|none --run-id ID " ++
    "[--store DB] [--from N] [--limit N] [--max-chunk BYTES]\n";

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("extractgate: " ++ fmt, args);
    std.process.exit(2);
}

fn emit(s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const n = std.c.write(1, s[off..].ptr, s.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn str(v: std.json.Value, k: []const u8) []const u8 {
    const x = v.object.get(k) orelse fail("set: missing {s}\n", .{k});
    if (x != .string) fail("set: {s} must be a string\n", .{k});
    return x.string;
}

const J = struct {
    a: std.mem.Allocator,
    b: std.ArrayList(u8) = .empty,
    first: bool = true,
    fn sep(j: *J) !void {
        if (!j.first) try j.b.append(j.a, ',');
        j.first = false;
    }
    fn s(j: *J, k: []const u8, v: ?[]const u8) !void {
        try j.sep();
        try j.b.print(j.a, "\"{s}\":", .{k});
        if (v) |x| try llm.writeJsonString(j.a, &j.b, x) else try j.b.appendSlice(j.a, "null");
    }
    fn n(j: *J, k: []const u8, v: anytype) !void {
        try j.sep();
        try j.b.print(j.a, "\"{s}\":{d}", .{ k, v });
    }
    fn o(j: *J, k: []const u8, v: ?i64) !void {
        try j.sep();
        if (v) |x| try j.b.print(j.a, "\"{s}\":{d}", .{ k, x }) else try j.b.print(j.a, "\"{s}\":null", .{k});
    }
    fn bo(j: *J, k: []const u8, v: ?bool) !void {
        try j.sep();
        try j.b.print(j.a, "\"{s}\":{s}", .{ k, if (v) |x| (if (x) "true" else "false") else "null" });
    }
    fn raw(j: *J, k: []const u8, v: []const u8) !void {
        try j.sep();
        try j.b.print(j.a, "\"{s}\":{s}", .{ k, v });
    }
    fn done(j: *J) ![]const u8 {
        try j.b.appendSlice(j.a, "}\n");
        return j.b.items;
    }
    fn begin(a: std.mem.Allocator) !J {
        var j: J = .{ .a = a };
        try j.b.append(a, '{');
        return j;
    }
};

fn turnLine(a: std.mem.Allocator, lg: pipeline.TurnLog, err: ?[]const u8) ![]const u8 {
    var j = try J.begin(a);
    try j.s("kind", "turn");
    try j.n("turn_id", lg.turn_id);
    try j.s("error", err);
    try j.s("skipped", lg.skipped);
    try j.bo("private_changed", lg.private_changed);
    try j.n("chunks", lg.chunks);
    try j.bo("valid_first", lg.valid_first);
    try j.bo("valid_final", lg.valid_final);
    try j.bo("judge_valid", lg.judge_valid);
    try j.n("total_ms", lg.total_ms);
    var e: std.ArrayList(u8) = .empty;
    try e.append(a, '[');
    for (lg.first_errors, 0..) |x, i| {
        if (i > 0) try e.append(a, ',');
        try llm.writeJsonString(a, &e, x);
    }
    try e.append(a, ']');
    try j.raw("first_errors", e.items);
    var c: std.ArrayList(u8) = .empty;
    try c.append(a, '[');
    for (lg.calls.items, 0..) |x, i| {
        if (i > 0) try c.append(a, ',');
        try c.print(a, "{{\"kind\":\"{s}\",\"engine\":\"{s}\",\"ms\":{d:.1},\"valid\":{},\"prompt_tokens\":{d},\"completion_tokens\":{d},\"reasoning_bytes\":{d}}}", .{ x.kind, @tagName(x.engine), x.ms, x.valid, x.prompt_tokens, x.completion_tokens, x.reasoning_bytes });
    }
    try c.append(a, ']');
    try j.raw("calls", c.items);
    var ap: std.ArrayList(u8) = .empty;
    try ap.append(a, '[');
    for (lg.applied.items, 0..) |x, i| {
        if (i > 0) try ap.append(a, ',');
        var k = try J.begin(a);
        try k.s("action", x.action);
        try k.o("id", x.id);
        try k.o("target", x.target);
        try k.s("subject", x.subject);
        try k.s("status", @tagName(x.status));
        try k.s("text", x.text);
        try k.s("reason", x.reason);
        try k.b.append(a, '}');
        try ap.appendSlice(a, k.b.items);
    }
    try ap.append(a, ']');
    try j.raw("applied", ap.items);
    return j.done();
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(arena);
    var set_path: ?[]const u8 = null;
    var ex: ?allow.Endpoint = null;
    var judge: ?allow.Endpoint = null;
    var judge_set = false;
    var run_id: []const u8 = "";
    var db_path: ?[:0]const u8 = null;
    var from: i64 = 1;
    var limit: usize = std.math.maxInt(usize);
    var max_chunk: usize = 6000;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        const k: []const u8 = args[i];
        if (i + 1 >= args.len) fail("missing value for {s}\n" ++ usage, .{k});
        const v: []const u8 = args[i + 1];
        if (std.mem.eql(u8, k, "--set")) set_path = v else if (std.mem.eql(u8, k, "--extract")) {
            ex = allow.resolve(v) catch fail("--extract {s}: not on the allowlist\n", .{v});
        } else if (std.mem.eql(u8, k, "--judge")) {
            judge_set = true;
            judge = if (std.mem.eql(u8, v, "none")) null else allow.resolve(v) catch fail("--judge {s}: not on the allowlist\n", .{v});
        } else if (std.mem.eql(u8, k, "--run-id")) run_id = v else if (std.mem.eql(u8, k, "--store")) {
            db_path = try arena.dupeSentinel(u8, v, 0);
        } else if (std.mem.eql(u8, k, "--from")) {
            from = std.fmt.parseInt(i64, v, 10) catch fail("bad --from\n", .{});
        } else if (std.mem.eql(u8, k, "--max-chunk")) {
            max_chunk = std.fmt.parseInt(usize, v, 10) catch fail("bad --max-chunk\n", .{});
            if (max_chunk < 1000) fail("--max-chunk must be >= 1000\n", .{});
        } else if (std.mem.eql(u8, k, "--limit")) {
            limit = std.fmt.parseInt(usize, v, 10) catch fail("bad --limit\n", .{});
        } else fail("unknown flag {s}\n" ++ usage, .{k});
    }
    if (set_path == null or ex == null or !judge_set or run_id.len == 0) fail(usage, .{});
    const raw = std.Io.Dir.cwd().readFileAlloc(init.io, set_path.?, arena, .limited(16 << 20)) catch |e| fail("cannot read set: {s}\n", .{@errorName(e)});
    const set = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
    var plist: std.ArrayList(people_mod.Person) = .empty;
    for (set.object.get("people").?.array.items) |p| {
        var al: std.ArrayList([]const u8) = .empty;
        for (p.object.get("aliases").?.array.items) |x| try al.append(arena, x.string);
        try plist.append(arena, .{ .id = str(p, "id"), .aliases = al.items });
    }
    var can: std.ArrayList([]const u8) = .empty;
    for (set.object.get("canaries").?.array.items) |x| try can.append(arena, x.string);
    var client: llm.Client = .{ .canaries = can.items };

    var ms = sink_mod.MemSink.init(gpa);
    defer ms.deinit();
    var st: ?store.Store = null;
    var ss: StoreSink = undefined;
    const the_sink = if (db_path) |pth| blk: {
        st = try store.Store.open(gpa, init.io, pth, .{});
        ss = .{ .st = &st.? };
        break :blk ss.sink();
    } else ms.sink();
    defer if (st) |*s| s.close();

    var p = pipeline.Pipeline.init(gpa, .{ .extractor = ex.?, .judge = judge, .scope = str(set, "scope"), .people = .{ .list = plist.items }, .today = str(set, "today"), .run_id = run_id, .max_chunk = max_chunk }, &client, the_sink);
    defer p.deinit();
    var done: usize = 0;
    for (set.object.get("turns").?.array.items) |tv| {
        const id = tv.object.get("id").?.integer;
        if (id < from or done >= limit) continue;
        done += 1;
        var ta: std.heap.ArenaAllocator = .init(gpa);
        defer ta.deinit();
        const t: pipeline.Turn = .{ .id = id, .session = str(tv, "session"), .speaker = str(tv, "speaker"), .role = str(tv, "role"), .date = str(tv, "date"), .text = str(tv, "text") };
        const lg = p.process(ta.allocator(), t) catch |e| {
            emit(try turnLine(ta.allocator(), .{ .turn_id = id }, @errorName(e)));
            std.debug.print("turn {d}: ERROR {s}\n", .{ id, @errorName(e) });
            continue;
        };
        emit(try turnLine(ta.allocator(), lg, null));
        std.debug.print("turn {d}: {d:.0} ms, calls {d}, applied {d}{s}\n", .{ id, lg.total_ms, lg.calls.items.len, lg.applied.items.len, if (lg.skipped != null) " (skipped)" else "" });
    }
    // Rows: every row ever written, any status (nothing is removed, so this is the whole history).
    var ra: std.heap.ArenaAllocator = .init(gpa);
    defer ra.deinit();
    const a = ra.allocator();
    if (st) |*s| {
        var q = try s.db.prepare("SELECT id, lineage, subject, type, priority, text, valid_from, valid_to, status, superseded_by, src_l0, extractor, run_id, prompt_sha IS NOT NULL FROM atoms ORDER BY id");
        defer q.deinit();
        while (try q.step()) {
            var j = try J.begin(a);
            try j.s("kind", "row");
            try j.n("id", q.int(0));
            try j.s("lineage", q.text(1));
            try j.s("subject", q.text(2));
            try j.s("type", q.text(3));
            try j.n("priority", q.int(4));
            try j.s("text", q.text(5));
            try j.s("valid_from", if (q.isNull(6)) null else q.text(6));
            try j.s("valid_to", if (q.isNull(7)) null else q.text(7));
            try j.s("status", q.text(8));
            try j.o("superseded_by", if (q.isNull(9)) null else q.int(9));
            try j.s("src", q.text(10));
            try j.s("extractor", q.text(11));
            try j.s("run_id", q.text(12));
            try j.bo("prompt_sha", q.int(13) == 1);
            emit(try j.done());
        }
    } else for (ms.rows.items) |r| {
        var j = try J.begin(a);
        try j.s("kind", "row");
        try j.n("id", r.id);
        try j.n("lineage", r.lineage);
        try j.s("subject", r.row.subject);
        try j.s("type", r.row.type);
        try j.n("priority", r.row.priority);
        try j.s("text", r.row.text);
        try j.s("valid_from", r.row.valid_from);
        try j.s("valid_to", r.valid_to);
        try j.s("status", @tagName(r.status));
        try j.o("superseded_by", r.superseded_by);
        try j.s("src", try std.fmt.allocPrint(a, "turn={d} sha={x}", .{ r.row.prov.turn_id, r.row.prov.src_turn_sha[0..16] }));
        try j.s("extractor", try std.fmt.allocPrint(a, "{s}|{s}|p:{s}", .{ r.row.prov.extractor, r.row.prov.model, r.row.prov.prompt_version }));
        try j.s("run_id", r.row.prov.run_id);
        try j.bo("prompt_sha", true);
        emit(try j.done());
    }
    var j = try J.begin(a);
    try j.s("kind", "summary");
    try j.s("extractor", ex.?.model);
    try j.s("judge", if (judge) |x| x.model else null);
    try j.n("connects", client.connects);
    try j.n("refused", client.refused);
    try j.n("requests", client.requests);
    try j.n("canary_hits_in_requests", client.canary_hits);
    try j.s("prompt_sha", try std.fmt.allocPrint(a, "{x}", .{&p.prompt_sha}));
    emit(try j.done());
}
