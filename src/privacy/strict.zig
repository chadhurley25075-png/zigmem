//! zigmem-only (NOT a Python port, so not in the parity set): a second stamping pass after the window firewall. It covers what the
//! firewall cannot see: a fact whose dead phrasings share no single number (no derivable dead_core), so a bare dead count in a new
//! phrasing is never stamped (found 10/12: bench item 77 — the live lane leaks it too). A line is stamped (annotate, never delete;
//! same note as the firewall) when it carries a ≥3-digit number that appears in ANY of a fact's dead phrasings together with one
//! of that fact's query words, and no stamp/cue is already on it. `deadMoney` is blend_rerank's fill-row screen (parity).
const std = @import("std");
const g = @import("gates.zig");
const re = g.re;

fn digitsOnly(w: []const u8) bool {
    if (w.len < 3) return false;
    for (w) |b| if (!std.ascii.isDigit(b)) return false;
    return true;
}

fn words(a: std.mem.Allocator, rx: *const g.Rx, low: []const u8) ![][]const u8 {
    const t = try re.Text.init(a, low);
    var out: std.ArrayList([]const u8) = .empty;
    for (try rx.kw_tok.findAll(a, t)) |m| try out.append(a, std.mem.trim(u8, m.group(t, 0).?, ".,'"));
    return out.items;
}

/// blend_rerank fill screen: ledger_reject(t) or money_tokens_k(t) ∩ every fact's dead_money_k (parity with the live lane).
pub fn fillReject(gs: *g.Gates, a: std.mem.Allocator, text: []const u8) !bool {
    if (try g.ledger.reject(gs, a, text, null)) return true;
    const t = try re.Text.init(a, text);
    const money = try g.ledger.moneyTokens(a, &gs.rx, t);
    for (gs.led.facts) |f| {
        if (f.v != .object) continue;
        const dm = f.v.object.get("dead_money_k") orelse continue;
        if (dm != .array) continue;
        for (dm.array.items) |x| {
            const v: f64 = switch (x) {
                .integer => |i| @floatFromInt(i),
                .float => |fl| fl,
                else => continue,
            };
            for (money) |m| if (m == v) return true;
        }
    }
    return false;
}

/// Index of the first fact whose dead number + topic word both sit in `line`, else null.
pub fn deadNumberFact(gs: *g.Gates, a: std.mem.Allocator, line: []const u8) !?usize {
    const low = try g.lowerBytes(a, line);
    const ws = try words(a, &gs.rx, low);
    for (gs.led.facts, 0..) |f, fi| {
        if (f.v != .object) continue;
        const qk = f.v.object.get("query_keywords") orelse continue;
        if (qk != .array) continue;
        var topic = false;
        for (qk.array.items) |q| if (q == .string and q.string.len > 0) {
            const ql = try g.lowerBytes(a, q.string);
            if (std.mem.indexOf(u8, low, ql) != null) topic = true;
        };
        if (!topic) continue;
        const dk = f.v.object.get("dead_keywords") orelse continue;
        if (dk != .array) continue;
        for (dk.array.items) |k| {
            if (k != .string) continue;
            for (try words(a, &gs.rx, try g.lowerBytes(a, k.string))) |n| {
                if (!digitsOnly(n)) continue;
                for (ws) |w| if (std.mem.eql(u8, w, n)) return fi;
            }
        }
    }
    return null;
}

fn hasDigitRun(s: []const u8, n: usize) bool {
    var run: usize = 0;
    for (s) |b| {
        run = if (std.ascii.isDigit(b)) run + 1 else 0;
        if (run >= n) return true;
    }
    return false;
}

/// The second stamping pass over a whole block (lines already stamped or carrying a supersession cue are left alone).
pub fn stamp(gs: *g.Gates, gpa: std.mem.Allocator, block: []const u8) ![]u8 {
    return stampWith(gs, gpa, block, true);
}

/// `prefilter = false` = the full pass on every line (`stamp` must equal it; tested in tests.zig).
pub fn stampWith(gs: *g.Gates, gpa: std.mem.Allocator, block: []const u8, prefilter: bool) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, block, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(a, '\n');
        first = false;
        try out.appendSlice(a, line);
        if (std.mem.indexOf(u8, line, "[LEDGER") != null or g.strip(line).len == 0) continue;
        // a stamp needs a token of >= 3 ASCII digits: no such run in the line → nothing to do (sound prefilter)
        if (prefilter and !hasDigitRun(line, 3)) continue;
        const t = try re.Text.init(a, line);
        if ((try gs.rx.supersession_cue.search(t, 0)) != null) continue;
        const fi = (try deadNumberFact(gs, a, line)) orelse continue;
        const f = gs.led.facts[fi].v.object;
        const cur = if (f.get("current")) |c| (if (c == .string) c.string else "") else "";
        const cps = try g.decode(a, cur);
        try out.print(a, "  ⚠[LEDGER {s}: superseded — {s} = {s}]", .{
            try g.ledger.pyStr(a, f.get("as_of")), try g.ledger.pyStr(a, f.get("label")), try g.encode(a, cps[0..@min(110, cps.len)]),
        });
    }
    return gpa.dupe(u8, out.items);
}
