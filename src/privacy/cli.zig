//! zigmem-gate: JSONL in → JSONL out, one gate call per line. The differential harness (tests/phase3/diff_gates.py) sends the
//! same lines to the Python originals and compares. Args: [--ledger PATH] [--today YYYY-MM-DD] [--cfg a,b,c,d] [--private 0|1]
const std = @import("std");
const g = @import("privacy");
const Value = std.json.Value;

fn writeAll(s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const n = std.c.write(1, s[off..].ptr, s.len - off);
        if (n <= 0) std.process.exit(3);
        off += @intCast(n);
    }
}

pub fn jsonStr(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(a, '"');
    for (s) |b| switch (b) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        0...8, 11, 12, 14...0x1f, 0x7f => try out.print(a, "\\u{x:0>4}", .{b}),
        else => try out.append(a, b),
    };
    try out.append(a, '"');
}

fn str(v: Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const x = v.object.get(key) orelse return "";
    return if (x == .string) x.string else "";
}

fn optStr(v: Value, key: []const u8) ?[]const u8 {
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

fn readStdin(a: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [1 << 16]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &chunk, chunk.len);
        if (n <= 0) break;
        try buf.appendSlice(a, chunk[0..@intCast(n)]);
    }
    return buf.items;
}

pub fn parseDate(s: []const u8) ?g.ledger.Date {
    if (s.len != 10) return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const m = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    return g.ledger.Date.valid(y, m, d);
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var ledger_json: ?[]const u8 = null;
    var today: g.ledger.Date = .{ .y = 2026, .m = 1, .d = 1 };
    var cfg: g.Config = .{};
    var private_on = true;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const k: []const u8 = args[i];
        const v: []const u8 = args[i + 1];
        if (std.mem.eql(u8, k, "--ledger")) {
            ledger_json = std.Io.Dir.cwd().readFileAlloc(init.io, v, arena, .limited(1 << 24)) catch null;
        } else if (std.mem.eql(u8, k, "--today")) {
            today = parseDate(v) orelse return error.BadDate;
        } else if (std.mem.eql(u8, k, "--cfg")) {
            var it = std.mem.splitScalar(u8, v, ',');
            cfg.drop_self_echo = std.mem.eql(u8, it.next() orelse "1", "1");
            cfg.drop_dated_claims = std.mem.eql(u8, it.next() orelse "1", "1");
            cfg.drop_transcript_dumps = std.mem.eql(u8, it.next() orelse "1", "1");
            cfg.drop_tool_logs = std.mem.eql(u8, it.next() orelse "1", "1");
        } else if (std.mem.eql(u8, k, "--private")) {
            private_on = !std.mem.eql(u8, v, "0");
        }
    }
    var gs = try g.Gates.init(gpa, ledger_json, today);
    defer gs.deinit();
    gs.cfg = cfg;
    gs.private_on = private_on;
    const input = try readStdin(arena);
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var ls = std.heap.ArenaAllocator.init(gpa);
        defer ls.deinit();
        const a = ls.allocator();
        var out: std.ArrayList(u8) = .empty;
        const v = std.json.parseFromSliceLeaky(Value, a, line, .{}) catch {
            writeAll("{\"err\":\"badjson\"}\n");
            continue;
        };
        one(&gs, a, v, &out) catch |e| {
            out.clearRetainingCapacity();
            try out.print(a, "{{\"err\":\"{s}\"}}", .{@errorName(e)});
        };
        try out.append(a, '\n');
        writeAll(out.items);
    }
}

fn boolOut(a: std.mem.Allocator, out: *std.ArrayList(u8), b: bool) !void {
    try out.appendSlice(a, if (b) "{\"out\":true}" else "{\"out\":false}");
}

fn strOut(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.appendSlice(a, "{\"out\":");
    try jsonStr(a, out, s);
    try out.append(a, '}');
}

fn one(gs: *g.Gates, a: std.mem.Allocator, v: Value, out: *std.ArrayList(u8)) !void {
    const op = str(v, "op");
    const text = str(v, "text");
    const eq = std.mem.eql;
    if (eq(u8, op, "strip_private")) {
        const r = try g.private.strip(a, text, gs.private_on);
        return strOut(a, out, r.text);
    } else if (eq(u8, op, "private_line")) {
        const r = try g.private.line(a, text, gs.private_on);
        return strOut(a, out, r.text);
    } else if (eq(u8, op, "has_private")) {
        return boolOut(a, out, g.echo.hasPrivate(gs, text));
    } else if (eq(u8, op, "is_machine_traffic")) {
        return boolOut(a, out, g.echo.isMachineTraffic(gs, a, text));
    } else if (eq(u8, op, "is_self_echo")) {
        return boolOut(a, out, g.echo.isSelfEcho(gs, a, text));
    } else if (eq(u8, op, "is_dated_claim")) {
        return boolOut(a, out, g.echo.isDatedClaim(gs, a, text));
    } else if (eq(u8, op, "is_transcript_dump")) {
        return boolOut(a, out, g.echo.isTranscriptDump(gs, a, text));
    } else if (eq(u8, op, "is_tool_log")) {
        return boolOut(a, out, g.echo.isToolLog(gs, a, text));
    } else if (eq(u8, op, "is_correction")) {
        return boolOut(a, out, g.echo.isCorrection(gs, a, text));
    } else if (eq(u8, op, "rejection_reason")) {
        const r = try g.echo.rejectionReason(gs, a, text, optStr(v, "created"));
        if (r) |x| return strOut(a, out, @tagName(x));
        return out.appendSlice(a, "{\"out\":null}");
    } else if (eq(u8, op, "ledger_reject")) {
        return boolOut(a, out, try g.ledger.reject(gs, a, text, optStr(v, "created")));
    } else if (eq(u8, op, "ledger_scrub")) {
        return strOut(a, out, try g.ledger.scrub(gs, a, text));
    } else if (eq(u8, op, "weekday_check")) {
        return strOut(a, out, try g.ledger.weekdayCheck(gs, a, text));
    } else if (eq(u8, op, "resolve_relative")) {
        return strOut(a, out, try g.ledger.resolveRelative(gs, a, text));
    } else if (eq(u8, op, "ledger_lines")) {
        return strOut(a, out, try g.ledger.lines(gs, a, text));
    } else if (eq(u8, op, "money_tokens_k")) {
        const t = try g.re.Text.init(a, text);
        const ms = try g.ledger.moneyTokens(a, &gs.rx, t);
        std.mem.sort(f64, ms, {}, std.sort.asc(f64));
        try out.appendSlice(a, "{\"out\":[");
        for (ms, 0..) |m, k| try out.print(a, "{s}{d}", .{ if (k == 0) "" else ",", m });
        return out.appendSlice(a, "]}");
    } else if (eq(u8, op, "named_family")) {
        const t = try g.re.Text.init(a, text);
        const s = g.medscope.named(gs, t);
        try out.appendSlice(a, "{\"out\":[");
        var k: usize = 0;
        var names: [g.medscope.n_names][]const u8 = undefined;
        for (0..g.medscope.n_names) |n| if (s.isSet(n)) {
            names[k] = g.medscope.nameOf(n);
            k += 1;
        };
        std.mem.sort([]const u8, names[0..k], {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        for (names[0..k], 0..) |n, j| {
            if (j > 0) try out.append(a, ',');
            try jsonStr(a, out, n);
        }
        return out.appendSlice(a, "]}");
    } else if (eq(u8, op, "medical_cross_person") or eq(u8, op, "medical_mixed_others")) {
        const t = try g.re.Text.init(a, text);
        const tg = g.medscope.indexOf(str(v, "target")) orelse return error.UnknownTarget;
        if (eq(u8, op, "medical_cross_person")) return boolOut(a, out, try g.medscope.crossPerson(gs, t, tg));
        const os = try g.medscope.mixedOthers(gs, a, t, tg);
        try out.appendSlice(a, "{\"out\":[");
        for (os, 0..) |o, j| {
            if (j > 0) try out.append(a, ',');
            try jsonStr(a, out, g.medscope.nameOf(o));
        }
        return out.appendSlice(a, "]}");
    } else if (eq(u8, op, "medical_subject_gate")) {
        const rv = v.object.get("rows") orelse return error.NoRows;
        var rows: std.ArrayList(g.medscope.Row) = .empty;
        for (rv.array.items) |r| try rows.append(a, .{ .text = if (r == .string) r.string else "" });
        const mode = std.meta.stringToEnum(g.MedMode, str(v, "mode")) orelse .enforce;
        const o = try g.medscope.gate(gs, a, rows.items, str(v, "query"), mode, false);
        try out.appendSlice(a, "{\"out\":[");
        for (o.rows, 0..) |r, j| {
            if (j > 0) try out.append(a, ',');
            try jsonStr(a, out, r.text);
        }
        return out.appendSlice(a, "]}");
    } else if (eq(u8, op, "re")) {
        var rx = try g.re.Regex.compile(a, str(v, "pattern"), .{ .i = std.mem.indexOfScalar(u8, str(v, "flags"), 'i') != null, .s = std.mem.indexOfScalar(u8, str(v, "flags"), 's') != null });
        defer rx.deinit();
        const t = try g.re.Text.init(a, text);
        try out.appendSlice(a, "{\"out\":[");
        for (try rx.findAll(a, t), 0..) |m, j| {
            if (j > 0) try out.append(a, ',');
            try out.append(a, '[');
            for (0..rx.ngroups) |gi| {
                if (gi > 0) try out.append(a, ',');
                if (m.caps[2 * gi]) |s| try out.print(a, "[{d},{d}]", .{ s, m.caps[2 * gi + 1].? }) else try out.appendSlice(a, "null");
            }
            try out.append(a, ']');
        }
        return out.appendSlice(a, "]}");
    } else if (eq(u8, op, "escape")) {
        var e = try g.escape.Escaper.init(a);
        defer e.deinit();
        return strOut(a, out, try e.row(a, text, optStr(v, "marker")));
    }
    return error.UnknownOp;
}
