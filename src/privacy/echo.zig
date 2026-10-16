//! Self-echo / transcript / tool-log / dated-claim rejection and the machine-traffic door: ports of is_self_echo,
//! is_dated_claim, is_transcript_dump, is_tool_log, rejection_reason, should_inject_document, is_machine_traffic.
//! Regex failures (error.TooComplex) map to the Python `except Exception` result of each function.
const std = @import("std");
const g = @import("gates.zig");
const re = g.re;
const Text = re.Text;

fn search(rx: *const re.Regex, t: Text) !bool {
    return (try rx.search(t, 0)) != null;
}
fn match(rx: *const re.Regex, t: Text) !bool {
    return (try rx.matchAt(t, 0)) != null;
}

fn cpLen(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

pub fn isCorrection(gs: *g.Gates, a: std.mem.Allocator, text: []const u8) bool {
    const t = Text.init(a, text) catch return false;
    return search(&gs.rx.correction, t) catch false;
}

pub fn isSelfEcho(gs: *g.Gates, a: std.mem.Allocator, text: []const u8) bool {
    if (!gs.cfg.drop_self_echo) return false;
    const s = g.strip(text);
    if (s.len == 0) return false;
    const t = Text.init(a, s) catch return false;
    return selfEchoInner(gs, t) catch false;
}

fn selfEchoInner(gs: *g.Gates, t: Text) !bool {
    if (try search(&gs.rx.correction, t)) return false;
    if (try match(&gs.rx.self_echo, t) or try match(&gs.rx.self_echo_lead, t)) return true;
    if (try search(&gs.rx.assistant_tag, t)) return true;
    return match(&gs.rx.first_person, t);
}

pub fn isDatedClaim(gs: *g.Gates, a: std.mem.Allocator, text: []const u8) bool {
    if (!gs.cfg.drop_dated_claims) return false;
    const t = Text.init(a, text) catch return false;
    const d = search(&gs.rx.dated, t) catch return false;
    if (!d) return false;
    return !(search(&gs.rx.durable, t) catch return false);
}

pub fn isTranscriptDump(gs: *g.Gates, a: std.mem.Allocator, text: []const u8) bool {
    if (!gs.cfg.drop_transcript_dumps) return false;
    const s = g.strip(text);
    if (s.len == 0) return true;
    const low = g.lowerBytes(a, s) catch return false;
    const t = Text.init(a, s) catch return false;
    if (match(&gs.rx.transcript_prefix, t) catch return false) return true;
    for (g.pat.transcript_markers) |m| if (std.mem.indexOf(u8, low, m) != null) return true;
    if (match(&gs.rx.empty_fragment, t) catch return false) return true;
    if (s[0] == '|' and std.mem.count(u8, s, "|") >= 3) return true;
    return cpLen(s) < 25;
}

pub fn isToolLog(gs: *g.Gates, a: std.mem.Allocator, text: []const u8) bool {
    if (!gs.cfg.drop_tool_logs) return false;
    const t = Text.init(a, g.strip(text)) catch return false;
    return toolInner(gs, t) catch false;
}

fn toolInner(gs: *g.Gates, t: Text) !bool {
    const r = &gs.rx;
    if (try match(&r.tool_log, t) or try match(&r.tool_log2, t)) return true;
    if (try match(&r.tool_rewrite, t) or try match(&r.tool_rewrite_path, t) or try match(&r.tool_rewrite_at, t) or try search(&r.file_meta, t)) return true;
    return search(&r.toolu, t);
}

pub fn firstLine(text: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |ln| {
        const s = g.strip(ln);
        if (s.len > 0) return s;
    }
    return "";
}

pub const Reason = enum { transcript, toollog, selfecho, dated, superseded };

/// rejection_reason(text, created): why a row must NOT be injected, or null.
pub fn rejectionReason(gs: *g.Gates, gpa: std.mem.Allocator, text: []const u8, created: ?[]const u8) !?Reason {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const head = firstLine(text);
    const ht = try Text.init(a, head);
    if (match(&gs.rx.clock_heading, ht) catch return null) return .transcript;
    for ([_][]const u8{ text, head }) |probe| {
        if (isTranscriptDump(gs, a, probe)) return .transcript;
        if (isToolLog(gs, a, probe)) return .toollog;
        if (isSelfEcho(gs, a, probe)) return .selfecho;
    }
    if (isDatedClaim(gs, a, text)) return .dated;
    if (try g.ledger.reject(gs, gpa, text, created)) return .superseded;
    return null;
}

pub fn shouldInjectDocument(gs: *g.Gates, a: std.mem.Allocator, text: []const u8) bool {
    return !(isTranscriptDump(gs, a, text) or isToolLog(gs, a, text));
}

/// has_private(text)
pub fn hasPrivate(gs: *g.Gates, text: []const u8) bool {
    return g.private.hasOpen(text, gs.private_on);
}

/// _mt_strip: peel stacked labels ("[Session ..] [USER]: <relevant-memories>..</..> text"), one re.sub(count=1) at a time.
fn mtStrip(gs: *g.Gates, a: std.mem.Allocator, seg: []const u8) ![]const u8 {
    var cur = seg;
    while (true) {
        const t = try Text.init(a, cur);
        const m = (try gs.rx.mt_labels.search(t, 0)) orelse return g.strip(cur);
        var b: std.ArrayList(u8) = .empty;
        try b.appendSlice(a, t.slice(0, m.start()));
        try b.append(a, ' ');
        try b.appendSlice(a, t.slice(m.end(), t.cps.len));
        const next = g.strip(b.items);
        if (std.mem.eql(u8, next, cur)) return cur;
        cur = next;
    }
}

fn mtSegment(gs: *g.Gates, a: std.mem.Allocator, seg: []const u8) !bool {
    const s = try mtStrip(gs, a, seg);
    if (s.len == 0) return true;
    const t = try Text.init(a, s);
    if (try search(&gs.rx.mt_start, t) or try match(&gs.rx.mt_ready, t) or try match(&gs.rx.mt_session_end, t)) return true;
    const ws = try gs.rx.mt_words.findAll(a, t);
    if (ws.len == 0 or ws.len > 4) return false;
    for (ws) |m| {
        const w = try g.lowerBytes(a, m.group(t, 0).?);
        var ok = false;
        for (g.pat.mt_bare) |b| if (std.mem.eql(u8, b, w)) {
            ok = true;
        };
        if (!ok) return false;
    }
    return true;
}

/// is_machine_traffic(text): warm-ups, READY probes, canaries, contentless session markers — and anything still tagged private.
pub fn isMachineTraffic(gs: *g.Gates, gpa: std.mem.Allocator, text: []const u8) bool {
    if (g.strip(text).len == 0) return false;
    if (hasPrivate(gs, text)) return true;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    return mtInner(gs, arena.allocator(), text) catch false;
}

fn mtInner(gs: *g.Gates, a: std.mem.Allocator, text: []const u8) !bool {
    const t = try Text.init(a, text);
    var segs: std.ArrayList([]const u8) = .empty;
    var prev: usize = 0;
    const ms = try gs.rx.mt_split.findAll(a, t);
    for (0..ms.len + 1) |k| {
        const end = if (k < ms.len) ms[k].start() else t.cps.len;
        const s = t.slice(prev, end);
        if (k < ms.len) prev = ms[k].end();
        if (g.strip(s).len > 0) try segs.append(a, s);
    }
    if (segs.items.len == 0) return false;
    const s0 = try Text.init(a, segs.items[0]);
    if (try match(&gs.rx.mt_q, s0) and try mtSegment(gs, a, segs.items[0])) return true;
    for (segs.items) |s| if (!try mtSegment(gs, a, s)) return false;
    return true;
}
