//! Recall helpers ported from rerank_lane.py so zigmem judges and trims rows the way the live lane does: focus() windows,
//! the question's date window, cite ages, near-duplicate Jaccard, FTS stopwords. Patterns compiled once.
const std = @import("std");
const privacy = @import("privacy");
const re = privacy.re;
const Date = privacy.ledger.Date;

const stop_words = "the a an of to in on at for and or is was were be been what when how much many did do does which who our we you your my i it this that with from by as are there their";
const fts_stop = "what when where which that this with from have does about there their been were the and for you your our are was how why did make made will would could should has had who is it in on of to a an do me my we us tell right now";
const mn = "(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\.?";

pub const Util = struct {
    words: re.Regex,
    fts_words: re.Regex,
    qty: re.Regex,
    when: re.Regex,
    num: re.Regex,
    dateish: re.Regex,
    iso: re.Regex,
    w_iso: re.Regex,
    w_mdy: re.Regex,
    w_third: re.Regex,
    w_mon_day: re.Regex,
    w_md: re.Regex,
    w_month: re.Regex,
    wset: re.Regex,

    pub fn init(gpa: std.mem.Allocator) !Util {
        const C = re.Regex.compile;
        return .{
            .words = try C(gpa, "[a-z0-9$][a-z0-9$,.']+", .{}),
            .fts_words = try C(gpa, "[A-Za-z0-9][A-Za-z0-9'\\-]{1,}", .{}),
            .qty = try C(gpa, "\\b(how (much|many|big|large|long|old|far|often)|what (size|amount|total|price|value|temperature|percent)|value|cost|total|price)\\b", .{ .i = true }),
            .when = try C(gpa, "\\b(when|what (date|day|time)|which (date|day))\\b", .{ .i = true }),
            .num = try C(gpa, "\\$\\s?\\d[\\d,.]*|\\b\\d{1,3}(?:,\\d{3})+(?:\\.\\d+)?\\b|\\b\\d+(?:\\.\\d+)?\\s?(?:%|k\\b|m\\b|tb\\b|gb\\b|kw\\b|°f|°|shares|a\\b|amp)", .{ .i = true }),
            .dateish = try C(gpa, "\\b\\d{1,2}/\\d{1,2}\\b|\\b20\\d\\d-\\d\\d-\\d\\d\\b|\\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]* \\d{1,2}\\b", .{ .i = true }),
            .iso = try C(gpa, "\\b(20\\d\\d)-(\\d\\d)-(\\d\\d)\\b", .{}),
            .w_iso = try C(gpa, "\\b(20\\d\\d)-(\\d\\d)-(\\d\\d)\\b", .{}),
            .w_mdy = try C(gpa, "\\b(\\d{1,2})/(\\d{1,2})/(20\\d\\d|\\d\\d)\\b", .{}),
            .w_third = try C(gpa, "\\b(early|mid|late)[- ]" ++ mn ++ "(?:,? (20\\d\\d))?", .{}),
            .w_mon_day = try C(gpa, mn ++ " (\\d{1,2})(?:st|nd|rd|th)?(?:,? (20\\d\\d))?\\b", .{}),
            .w_md = try C(gpa, "(?<![\\d/])\\b(\\d{1,2})/(\\d{1,2})\\b(?![/\\d])", .{}),
            .w_month = try C(gpa, "\\b(?:in )?" ++ mn ++ ",? (20\\d\\d)\\b", .{}),
            .wset = try C(gpa, "[a-z0-9$][a-z0-9$.,'/-]*", .{}),
        };
    }

    pub fn deinit(u: *Util) void {
        const info = @typeInfo(Util).@"struct";
        inline for (info.field_names) |n| @field(u, n).deinit();
    }

    pub fn cpLen(_: *const Util, s: []const u8) !usize {
        return std.unicode.utf8CountCodepoints(s) catch s.len;
    }

    /// Largest prefix length ≤ n bytes that ends on a UTF-8 boundary.
    pub fn capBytes(_: *const Util, s: []const u8, n: usize) usize {
        if (s.len <= n) return s.len;
        var i = n;
        while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;
        return i;
    }

    fn inList(list: []const u8, w: []const u8) bool {
        var it = std.mem.tokenizeScalar(u8, list, ' ');
        while (it.next()) |x| if (std.mem.eql(u8, x, w)) return true;
        return false;
    }

    /// Query → FTS text without stopwords (synth_search._fts); the store's planner quotes and OR-joins the rest.
    pub fn ftsText(u: *const Util, a: std.mem.Allocator, q: []const u8) ![]const u8 {
        const low = try privacy.lowerBytes(a, q);
        const t = try re.Text.init(a, low);
        var out: std.ArrayList(u8) = .empty;
        for (try u.fts_words.findAll(a, t)) |m| {
            const w = m.group(t, 0).?;
            if (inList(fts_stop, w)) continue;
            var clean: std.ArrayList(u8) = .empty;
            for (w) |b| if (std.ascii.isAlphanumeric(b)) try clean.append(a, b);
            if (clean.items.len <= 1) continue;
            try out.appendSlice(a, clean.items);
            try out.append(a, ' ');
        }
        return out.items;
    }

    /// focus(q, text, width): the width-char window that best matches the question (blend_rerank.focus), on code points.
    pub fn focus(u: *const Util, a: std.mem.Allocator, q: []const u8, text: []const u8, width: usize) ![]const u8 {
        const t = try re.Text.init(a, text);
        if (t.cps.len <= width) return text;
        const ql = try privacy.lowerBytes(a, q);
        const qt = try re.Text.init(a, ql);
        var words: std.ArrayList([]const u8) = .empty;
        for (try u.words.findAll(a, qt)) |m| {
            const w = std.mem.trim(u8, m.group(qt, 0).?, ",.'");
            if (w.len <= 2 or inList(stop_words, w)) continue;
            var seen = false;
            for (words.items) |x| if (std.mem.eql(u8, x, w)) {
                seen = true;
            };
            if (!seen) try words.append(a, w);
        }
        const qq = try re.Text.init(a, q);
        const qty = (try u.qty.search(qq, 0)) != null;
        const when = (try u.when.search(qq, 0)) != null;
        const step = @max(80, width / 4);
        var best: f64 = -1;
        var bi: usize = 0;
        var i: usize = 0;
        const limit = @max(1, t.cps.len - width + step);
        while (i < limit) : (i += step) {
            const end = @min(t.cps.len, i + width);
            const wl = try privacy.lowerBytes(a, t.slice(i, end));
            var sc: f64 = 0;
            for (words.items) |x| if (std.mem.indexOf(u8, wl, x) != null) {
                sc += 1;
            };
            if (qty or when) {
                const wt = try re.Text.init(a, wl);
                if (qty) sc += 0.6 * @as(f64, @floatFromInt(@min(4, (try u.num.findAll(a, wt)).len)));
                if (when) sc += 0.6 * @as(f64, @floatFromInt(@min(3, (try u.dateish.findAll(a, wt)).len)));
            }
            if (sc > best) {
                best = sc;
                bi = i;
            }
        }
        if (bi == 0) return t.slice(0, width);
        var j = bi;
        while (j > 0 and t.cps[j - 1] != ' ') j -= 1;
        return std.fmt.allocPrint(a, "…{s}", .{t.slice(j, @min(t.cps.len, j + width))});
    }

    /// date_window(text): explicit date words → inclusive ISO window (year-less dates → most recent past occurrence).
    pub fn dateWindow(u: *const Util, a: std.mem.Allocator, text: []const u8, today: Date) !?[2][10]u8 {
        const low = try privacy.lowerBytes(a, text);
        const t = try re.Text.init(a, low);
        const G = struct {
            fn n(m: re.Regex.Match, tt: re.Text, k: usize) i64 {
                const s = m.group(tt, k) orelse return -1;
                return std.fmt.parseInt(i64, s, 10) catch -1;
            }
            fn mon(m: re.Regex.Match, tt: re.Text, k: usize) i64 {
                const s = m.group(tt, k) orelse return -1;
                const ms = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
                for (ms, 1..) |x, i| if (std.mem.startsWith(u8, s, x)) return @intCast(i);
                return -1;
            }
        };
        if (try u.w_iso.search(t, 0)) |m| return day(G.n(m, t, 1), G.n(m, t, 2), G.n(m, t, 3));
        if (try u.w_mdy.search(t, 0)) |m| if (G.n(m, t, 1) >= 1 and G.n(m, t, 1) <= 12) {
            var y = G.n(m, t, 3);
            if (y < 100) y += 2000;
            return day(y, G.n(m, t, 1), G.n(m, t, 2));
        };
        if (try u.w_third.search(t, 0)) |m| {
            const mo = G.mon(m, t, 2);
            const y = if (m.group(t, 3) != null) G.n(m, t, 3) else pastYear(today, mo, 1);
            const yy: i32 = @intCast(y);
            const last = Date.dim(yy, @intCast(mo));
            const which = m.group(t, 1).?;
            const ab: [2]u8 = if (std.mem.eql(u8, which, "early")) .{ 1, 10 } else if (std.mem.eql(u8, which, "mid")) .{ 10, 20 } else .{ 20, last };
            return .{ isoOf(.{ .y = yy, .m = @intCast(mo), .d = ab[0] }), isoOf(.{ .y = yy, .m = @intCast(mo), .d = ab[1] }) };
        }
        if (try u.w_mon_day.search(t, 0)) |m| {
            const d = G.n(m, t, 2);
            if (d >= 1 and d <= 31) {
                const mo = G.mon(m, t, 1);
                const y = if (m.group(t, 3) != null) G.n(m, t, 3) else pastYear(today, mo, d);
                return day(y, mo, d);
            }
        }
        if (try u.w_md.search(t, 0)) |m| {
            const mo = G.n(m, t, 1);
            const d = G.n(m, t, 2);
            if (mo >= 1 and mo <= 12 and d >= 1 and d <= 31) return day(pastYear(today, mo, d), mo, d);
        }
        if (try u.w_month.search(t, 0)) |m| {
            const mo = G.mon(m, t, 1);
            const yy: i32 = @intCast(G.n(m, t, 2));
            return .{ isoOf(.{ .y = yy, .m = @intCast(mo), .d = 1 }), isoOf(.{ .y = yy, .m = @intCast(mo), .d = Date.dim(yy, @intCast(mo)) }) };
        }
        return null;
    }

    fn pastYear(today: Date, mo: i64, d: i64) i64 {
        const c = Date.valid(today.y, mo, d) orelse return today.y;
        return if (c.days() <= today.days() + 1) today.y else today.y - 1;
    }

    fn isoOf(d: Date) [10]u8 {
        var b: [10]u8 = undefined;
        _ = d.iso(&b);
        return b;
    }

    fn day(y: i64, m: i64, d: i64) ?[2][10]u8 {
        const c = Date.valid(y, m, d) orelse return null;
        return .{ isoOf(Date.fromDays(c.days() - 1)), isoOf(Date.fromDays(c.days() + 1)) };
    }

    /// _aged(cite, today): the LAST ISO date in a cite gets "(today|yesterday|Nd ago)" when 0–60 days old.
    pub fn aged(u: *const Util, a: std.mem.Allocator, cite: []const u8, today: Date) ![]const u8 {
        const t = try re.Text.init(a, cite);
        const ms = try u.iso.findAll(a, t);
        if (ms.len == 0) return cite;
        const m = ms[ms.len - 1];
        const y = std.fmt.parseInt(i64, m.group(t, 1).?, 10) catch return cite;
        const mo = std.fmt.parseInt(i64, m.group(t, 2).?, 10) catch return cite;
        const d = std.fmt.parseInt(i64, m.group(t, 3).?, 10) catch return cite;
        const dt = Date.valid(y, mo, d) orelse return cite;
        const n = today.days() - dt.days();
        if (n < 0 or n > 60) return cite;
        var tb: [16]u8 = undefined;
        const tag = if (n == 0) "today" else if (n == 1) "yesterday" else try std.fmt.bufPrint(&tb, "{d}d ago", .{n});
        return std.fmt.allocPrint(a, "{s} ({s}){s}", .{ t.slice(0, m.end()), tag, t.slice(m.end(), t.cps.len) });
    }

    fn wordSet(u: *const Util, a: std.mem.Allocator, s: []const u8) ![][]const u8 {
        const low = try privacy.lowerBytes(a, s);
        const t = try re.Text.init(a, low);
        var out: std.ArrayList([]const u8) = .empty;
        outer: for (try u.wset.findAll(a, t)) |m| {
            const w = std.mem.trim(u8, m.group(t, 0).?, ".,'");
            if (inList(stop_words, w)) continue;
            for (out.items) |x| if (std.mem.eql(u8, x, w)) continue :outer;
            try out.append(a, w);
        }
        return out.items;
    }

    /// _near_dup: word-set Jaccard ≥ th.
    pub fn nearDup(u: *const Util, a: std.mem.Allocator, x: []const u8, y: []const u8, th: f64) !bool {
        const sx = try u.wordSet(a, x);
        const sy = try u.wordSet(a, y);
        if (sx.len == 0 or sy.len == 0) return false;
        var inter: usize = 0;
        for (sx) |w| for (sy) |v| if (std.mem.eql(u8, w, v)) {
            inter += 1;
            break;
        };
        const uni = sx.len + sy.len - inter;
        return @as(f64, @floatFromInt(inter)) / @as(f64, @floatFromInt(uni)) >= th;
    }
};
