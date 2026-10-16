//! Calendar half of the window firewall: dates (proleptic Gregorian, Monday = 0), weekday_check and resolve_relative.
const std = @import("std");
const g = @import("gates.zig");
const re = g.re;
const Text = re.Text;
const U = g.U;

// ---------------------------------------------------------------- dates (proleptic Gregorian, Monday = 0)

pub const Date = struct {
    y: i32,
    m: u8,
    d: u8,

    pub fn valid(y: i64, m: i64, d: i64) ?Date {
        if (y < 1 or y > 9999 or m < 1 or m > 12 or d < 1) return null;
        if (d > dim(@intCast(y), @intCast(m))) return null;
        return .{ .y = @intCast(y), .m = @intCast(m), .d = @intCast(d) };
    }
    fn leap(y: i32) bool {
        return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
    }
    pub fn dim(y: i32, m: u8) u8 {
        const t = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        return if (m == 2 and leap(y)) 29 else t[m - 1];
    }
    pub fn days(x: Date) i64 {
        const y: i64 = if (x.m <= 2) x.y - 1 else x.y;
        const era = @divFloor(y, 400);
        const yoe = y - era * 400;
        const mp: i64 = @mod(@as(i64, x.m) + 9, 12);
        const doy = @divFloor(153 * mp + 2, 5) + x.d - 1;
        const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
        return era * 146097 + doe - 719468;
    }
    pub fn fromDays(z0: i64) Date {
        const z = z0 + 719468;
        const era = @divFloor(z, 146097);
        const doe = z - era * 146097;
        const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
        const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp = @divFloor(5 * doy + 2, 153);
        const d = doy - @divFloor(153 * mp + 2, 5) + 1;
        const m = if (mp < 10) mp + 3 else mp - 9;
        return .{ .y = @intCast(yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0)), .m = @intCast(m), .d = @intCast(d) };
    }
    pub fn weekday(x: Date) u8 {
        return @intCast(@mod(x.days() + 3, 7));
    }
    pub fn iso(x: Date, buf: *[10]u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(x.y)), x.m, x.d }) catch unreachable;
    }
};


// ---------------------------------------------------------------- calendar

const wd_keys = [_][]const u8{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" };
const months = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };

/// _WD[s[:3].lower()] / _MONTHS[...]: KeyError → error.Py.
fn keyIndex(a: std.mem.Allocator, keys: []const []const u8, s: []const u8) !usize {
    const cps = try g.decode(a, s);
    const l = try g.encode(a, try g.lowerCps(a, cps[0..@min(3, cps.len)]));
    for (keys, 0..) |k, i| if (std.mem.eql(u8, k, l)) return i;
    return error.Py;
}

fn monthIndex(a: std.mem.Allocator, s: []const u8) !?usize {
    return keyIndex(a, &months, s) catch null;
}

/// int(s) of a \d run (Unicode decimals allowed, like Python int()).
pub fn pyIntDigits(s: U) i64 {
    var v: i64 = 0;
    for (s) |c| v = v * 10 + (re.digitValue(c) orelse 0);
    return v;
}

pub fn grp(m: re.Regex.Match, t: Text, k: usize) U {
    return t.cps[m.caps[2 * k].?..m.caps[2 * k + 1].?];
}

/// _parse_full_date(s): null on no match OR ValueError (the caller catches ValueError → None).
fn parseFullDate(a: std.mem.Allocator, rx: *const g.Rx, s: []const u8) !?Date {
    const t = try Text.init(a, g.strip(s));
    if (try rx.full_iso.fullmatch(t)) |m| return Date.valid(pyIntDigits(grp(m, t, 1)), pyIntDigits(grp(m, t, 2)), pyIntDigits(grp(m, t, 3)));
    if (try rx.full_slash.fullmatch(t)) |m| {
        var y = pyIntDigits(grp(m, t, 3));
        if (y < 100) y += 2000;
        return Date.valid(y, pyIntDigits(grp(m, t, 1)), pyIntDigits(grp(m, t, 2)));
    }
    if (try rx.full_mon.fullmatch(t)) |m| {
        const mo = (try monthIndex(a, m.group(t, 1).?)) orelse return null;
        return Date.valid(pyIntDigits(grp(m, t, 3)), @intCast(mo + 1), pyIntDigits(grp(m, t, 2)));
    }
    return null;
}

/// _md(s) → (month, day) or null.
fn md(a: std.mem.Allocator, rx: *const g.Rx, s: []const u8) !?[2]i64 {
    const t = try Text.init(a, g.strip(s));
    if (try rx.md_slash.fullmatch(t)) |m| return .{ pyIntDigits(grp(m, t, 1)), pyIntDigits(grp(m, t, 2)) };
    if (try rx.md_mon.fullmatch(t)) |m| {
        const mo = (try monthIndex(a, m.group(t, 1).?)) orelse return null;
        return .{ @intCast(mo + 1), pyIntDigits(grp(m, t, 2)) };
    }
    return null;
}

fn yearlessNote(gs: *g.Gates, a: std.mem.Allocator, t: Text) !?[]const u8 {
    const y: i64 = gs.today.y;
    for (try gs.rx.wd_ny.findAll(a, t)) |m| {
        const mdv = (try md(a, &gs.rx, m.group(t, 2).?)) orelse continue;
        const want = try keyIndex(a, &wd_keys, m.group(t, 1).?);
        var w: [3]?u8 = undefined;
        var all = true;
        for (0..3) |k| {
            w[k] = if (Date.valid(y - @as(i64, @intCast(k)), mdv[0], mdv[1])) |d| d.weekday() else null;
            if (w[k] == null or w[k].? == want) all = false;
        }
        if (all) {
            const n = g.pat.wdn;
            return try std.fmt.allocPrint(a, "  ⚠[calendar: {d}/{d} was a {s} in {d}, {s} in {d}, {s} in {d} — never a {s}]", .{ mdv[0], mdv[1], n[w[0].?], y, n[w[1].?], y - 1, n[w[2].?], y - 2, n[want] });
        }
    }
    return null;
}

/// weekday_check(text). Any exception → the text unchanged.
pub fn weekdayCheck(gs: *g.Gates, a: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len == 0) return text;
    return weekdayInner(gs, a, text) catch |e| switch (e) {
        error.OutOfMemory => e,
        else => text,
    };
}

fn weekdayInner(gs: *g.Gates, a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(a, '\n');
        first = false;
        // every note needs a weekday token (wd_before / wd_after / wd_ny all require Mon|Tue|…|Sun): an ASCII line with
        // none of them is returned as is without running the patterns (sound prefilter; integration, performance)
        if (noWeekday(line)) {
            try out.appendSlice(a, line);
            continue;
        }
        const t = try Text.init(a, line);
        var note: ?[]const u8 = null;
        const before = try gs.rx.wd_before.findAll(a, t);
        const after = try gs.rx.wd_after.findAll(a, t);
        var k: usize = 0;
        while (k < before.len + after.len) : (k += 1) {
            const m = if (k < before.len) before[k] else after[k - before.len];
            const whole = try Text.init(a, m.group(t, 0).?);
            const is_before = (try gs.rx.wd_before.fullmatch(whole)) != null;
            const wd = (if (is_before) m.group(t, 1) else m.group(t, 2)) orelse return error.Py;
            const ds = (if (is_before) m.group(t, 2) else m.group(t, 1)) orelse return error.Py;
            const d = (try parseFullDate(a, &gs.rx, ds)) orelse continue;
            const want = try keyIndex(a, &wd_keys, wd);
            if (d.weekday() != want) {
                var b: [10]u8 = undefined;
                note = try std.fmt.allocPrint(a, "  ⚠[calendar: {s} was a {s}, not {s}]", .{ d.iso(&b), g.pat.wdn[d.weekday()], g.pat.wdn[want] });
                break;
            }
        }
        if (note == null) note = try yearlessNote(gs, a, t);
        try out.appendSlice(a, line);
        if (note) |n| if (std.mem.indexOf(u8, line, "⚠[calendar") == null) try out.appendSlice(a, n);
    }
    return out.items;
}

fn noWeekday(line: []const u8) bool {
    if (line.len < 3) return true;
    for (line) |b| if (b >= 128) return false; // Unicode case folding (ſ, ı, İ …) → take the full path
    const keys = [_][]const u8{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" };
    var i: usize = 0;
    while (i + 3 <= line.len) : (i += 1) {
        const w = [3]u8{ std.ascii.toLower(line[i]), std.ascii.toLower(line[i + 1]), std.ascii.toLower(line[i + 2]) };
        for (keys) |k| if (std.mem.eql(u8, &w, k)) return false;
    }
    return true;
}

/// resolve_relative(text). Any exception → the text unchanged.
pub fn resolveRelative(gs: *g.Gates, a: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len == 0) return text;
    return relInner(gs, a, text) catch |e| switch (e) {
        error.OutOfMemory => e,
        else => text,
    };
}

fn relInner(gs: *g.Gates, a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(a, '\n');
        first = false;
        // line_date is case-sensitive and starts with the literal "· written " or "[Vol ": without either, no match
        if (std.mem.indexOf(u8, line, "· written ") == null and std.mem.indexOf(u8, line, "[Vol ") == null) {
            try out.appendSlice(a, line);
            continue;
        }
        const t = try Text.init(a, line);
        const m = (try gs.rx.line_date.search(t, 0)) orelse {
            try out.appendSlice(a, line);
            continue;
        };
        if (std.mem.indexOf(u8, line, "[=20") != null) {
            try out.appendSlice(a, line);
            continue;
        }
        // date.fromisoformat: ASCII digits only, real calendar date, else ValueError (→ whole function returns text)
        const iso = grp(m, t, 1);
        for (iso) |c| if (c >= 128) return error.Py;
        const base = Date.valid(pyIntDigits(iso[0..4]), pyIntDigits(iso[5..7]), pyIntDigits(iso[8..10])) orelse return error.Py;
        const body_start: ?usize = blk: {
            var p = m.end();
            while (p < t.cps.len) : (p += 1) if (t.cps[p] == ']') break :blk p;
            break :blk null;
        };
        const from = if (body_start != null and body_start.? > 0) body_start.? + 1 else m.end();
        var done = false;
        for (&gs.rx.rel, g.pat.rel) |*rx, spec| {
            if (from > t.cps.len) break;
            if (try rx.search(t, from)) |mm| {
                var b: [10]u8 = undefined;
                const d = Date.fromDays(base.days() + spec.off);
                try out.appendSlice(a, t.slice(0, mm.end()));
                try out.print(a, " [={s}]", .{d.iso(&b)});
                try out.appendSlice(a, t.slice(mm.end(), t.cps.len));
                done = true;
                break;
            }
        }
        if (!done) try out.appendSlice(a, line);
    }
    return out.items;
}


test "date math" {
    const d = Date.valid(2026, 9, 22).?;
    try std.testing.expectEqual(@as(u8, 1), d.weekday()); // Tuesday
    try std.testing.expectEqual(d, Date.fromDays(d.days()));
}
