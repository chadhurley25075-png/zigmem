//! Read pages: memories (browse by subject / status, search), one memory (provenance, source turn, lineage history,
//! audit trail, and the supersede / demote / approve forms), the extraction queue, and health. Every query is
//! limited to the logged-in seat's scopes, exactly like the API; every dynamic value is escaped.
const std = @import("std");
const api = @import("api");
const store = @import("store");
const http = api.http;
const retrieval = api.retrieval;
const hh = api.household;
const panel = @import("panel.zig");
const html = @import("html.zig");
const Ctx = panel.Ctx;
const Buf = html.Buf;
const esc = html.esc;

const statuses = [_][]const u8{ "active", "pending_review", "superseded", "retired", "any" };

/// Fixed flash messages chosen by code (`?msg=`), so nothing user-supplied is ever reflected.
pub fn flash(c: *Ctx, b: *Buf) !void {
    const code = c.q.val("msg") orelse return;
    const table = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "superseded", .v = "Saved as a new version; the old one is kept as superseded." },
        .{ .k = "retired", .v = "Retired (a status flip, nothing deleted)." },
        .{ .k = "pending_review", .v = "Sent back to review." },
        .{ .k = "active", .v = "Approved: the memory is active." },
        .{ .k = "revoked", .v = "Seat revoked. Its token stops working on the next request." },
    };
    for (table) |x| if (std.mem.eql(u8, x.k, code)) {
        try b.appendSlice(c.a, "<p class=\"flash\" role=\"status\">");
        try b.appendSlice(c.a, x.v);
        try b.appendSlice(c.a, "</p>");
    };
}

fn statusBadge(c: *Ctx, b: *Buf, st: store.atoms.Status) !void {
    try b.print(c.a, "<span class=\"badge st-{s}\">{s}</span>", .{ @tagName(st), switch (st) {
        .active => "active",
        .superseded => "superseded",
        .pending_review => "review",
        .retired => "retired",
    } });
}

fn card(c: *Ctx, b: *Buf, x: store.atoms.Atom) !void {
    try b.appendSlice(c.a, "<article class=\"card atom\"><div class=\"meta\"><a class=\"subj\" href=\"/panel/atoms?subject=");
    try html.urlEnc(c.a, b, x.subject);
    try b.appendSlice(c.a, "\">");
    try esc(c.a, b, x.subject);
    try b.appendSlice(c.a, "</a><span>");
    try esc(c.a, b, x.type);
    try b.appendSlice(c.a, "</span><span class=\"dim\">");
    try esc(c.a, b, x.scope);
    try b.appendSlice(c.a, "</span>");
    try statusBadge(c, b, x.status);
    if (x.valid_from) |v| {
        try b.appendSlice(c.a, "<span class=\"dim\">from ");
        try esc(c.a, b, v);
        try b.appendSlice(c.a, "</span>");
    }
    try b.print(c.a, "</div><p class=\"txt\"><a href=\"/panel/atom?id={d}\">", .{x.id});
    try html.escCut(c.a, b, x.text, 400);
    try b.print(c.a, "</a></p><div class=\"dim small\">#{d} · ", .{x.id});
    try html.when(c.a, b, x.recorded_ms);
    try b.appendSlice(c.a, "</div></article>");
}

/// Integration: a row the panel shows passes the household + medical gates with its own subject as the target (the
/// browse question is "about" that row), and its text is shown through the window firewall + strict stamp.
pub fn visible(c: *Ctx, rd: *store.Store, x: *store.atoms.Atom) !bool {
    if (c.scope().names.len == 0) return false;
    const slot = c.p.h.readers.slotOf(rd);
    const row: hh.house.Row = .{ .id = x.id, .scope = x.scope, .subject = x.subject, .type = x.type, .text = x.text };
    if (!try retrieval.gateOne(&c.p.h.eng, c.a, rd, slot, c.house(), row, "", x.subject)) return false;
    x.text = @constCast((try retrieval.serveText(&c.p.h.eng, c.a, slot, x.text, false)) orelse return false);
    return true;
}

fn rowAtom(a: std.mem.Allocator, s: store.sqlite.Stmt) !store.atoms.Atom {
    return .{
        .id = s.int(0),
        .lineage = try a.dupe(u8, s.text(1)),
        .subject = try a.dupe(u8, s.text(2)),
        .scope = try a.dupe(u8, s.text(3)),
        .type = try a.dupe(u8, s.text(4)),
        .priority = s.int(5),
        .text = try a.dupe(u8, s.text(6)),
        .valid_from = if (s.isNull(7)) null else try a.dupe(u8, s.text(7)),
        .valid_to = if (s.isNull(8)) null else try a.dupe(u8, s.text(8)),
        .recorded_ms = s.int(9),
        .superseded_by = if (s.isNull(10)) null else s.int(10),
        .status = std.meta.stringToEnum(store.atoms.Status, s.text(11)) orelse .pending_review,
        .run_id = null,
    };
}

pub fn atoms(c: *Ctx) !http.Response {
    const a = c.a;
    const scope = c.scope();
    const q = c.q.val("q");
    const subject = c.q.val("subject");
    const status = c.q.val("status") orelse "active";
    var ok_status = false;
    for (statuses) |s| if (std.mem.eql(u8, s, status)) {
        ok_status = true;
    };
    if (!ok_status) return c.fail(400, "unknown status filter");
    if (q) |x| if (x.len > 500) return c.fail(400, "search text is longer than 500 bytes");
    const before = c.q.int("before");
    const page_n: usize = 50;

    var rows: std.ArrayList(store.atoms.Atom) = .empty;
    var subjects: std.ArrayList(struct { s: []const u8, n: i64 }) = .empty;
    if (scope.names.len > 0) {
        const rd = c.p.h.readers.acquire();
        defer c.p.h.readers.release(rd);
        // subject chips: counted over the newest 400 active rows this seat may SEE (gated), never raw counts
        var sql: std.ArrayList(u8) = .empty;
        try sql.appendSlice(a, "SELECT id, lineage, subject, scope, type, priority, text, valid_from, valid_to, recorded_ms, superseded_by, status FROM atoms WHERE status = 'active' AND ");
        try scope.sqlIn(a, &sql, "scope", 1);
        try sql.appendSlice(a, " ORDER BY id DESC LIMIT 400");
        var s = try rd.db.prepare(sql.items);
        defer s.deinit();
        try scope.bind(s, 1);
        var counts: std.StringArrayHashMapUnmanaged(i64) = .empty;
        while (try s.step()) {
            var x = try rowAtom(a, s);
            if (!try visible(c, rd, &x)) continue;
            const gop = try counts.getOrPut(a, x.subject);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
        for (counts.keys(), counts.values()) |k, v| if (subjects.items.len < 40) try subjects.append(a, .{ .s = k, .n = v });

        if (q) |text| {
            const hits = try store.atoms.search(rd, a, scope, text, .{ .limit = 200, .include_inactive = !std.mem.eql(u8, status, "active") });
            for (hits) |x0| {
                if (rows.items.len >= page_n) break;
                var x = x0;
                if (subject) |sj| if (!std.mem.eql(u8, sj, x.subject)) continue;
                if (!std.mem.eql(u8, status, "any") and !std.mem.eql(u8, status, @tagName(x.status))) continue;
                if (!try visible(c, rd, &x)) continue;
                try rows.append(a, x);
            }
        } else {
            var l: std.ArrayList(u8) = .empty;
            try l.appendSlice(a, "SELECT id, lineage, subject, scope, type, priority, text, valid_from, valid_to, recorded_ms, superseded_by, status " ++
                "FROM atoms WHERE (?1 IS NULL OR id < ?1) AND (?2 = 'any' OR status = ?2) AND (?3 IS NULL OR subject = ?3) AND ");
            try scope.sqlIn(a, &l, "scope", 5);
            try l.appendSlice(a, " ORDER BY id DESC LIMIT ?4");
            var s2 = try rd.db.prepare(l.items);
            defer s2.deinit();
            try s2.bindAll(.{ before, status, subject, page_n });
            try scope.bind(s2, 5);
            while (try s2.step()) {
                var x = try rowAtom(a, s2);
                if (!try visible(c, rd, &x)) continue;
                try rows.append(a, x);
            }
        }
    }

    var b: Buf = .empty;
    try html.begin(a, &b, c.shell(if (std.mem.eql(u8, status, "pending_review")) "Review" else "Memories", if (std.mem.eql(u8, status, "pending_review")) .review else .atoms));
    try flash(c, &b);
    try b.appendSlice(a, "<form class=\"search\" method=\"get\" action=\"/panel/atoms\"><input type=\"search\" name=\"q\" placeholder=\"Search memories\" aria-label=\"Search\" value=\"");
    try esc(a, &b, q orelse "");
    try b.appendSlice(a, "\"><select name=\"status\" aria-label=\"Status\">");
    for (statuses) |s| try b.print(a, "<option value=\"{s}\"{s}>{s}</option>", .{ s, if (std.mem.eql(u8, s, status)) " selected" else "", s });
    try b.appendSlice(a, "</select>");
    if (subject) |sj| {
        try b.appendSlice(a, "<input type=\"hidden\" name=\"subject\" value=\"");
        try esc(a, &b, sj);
        try b.appendSlice(a, "\">");
    }
    try b.appendSlice(a, "<button type=\"submit\">Search</button></form><div class=\"chips\"><a href=\"/panel/atoms\"");
    if (subject == null) try b.appendSlice(a, " aria-current=\"true\"");
    try b.appendSlice(a, ">all</a>");
    for (subjects.items) |x| {
        try b.appendSlice(a, "<a href=\"/panel/atoms?subject=");
        try html.urlEnc(a, &b, x.s);
        try b.appendSlice(a, "\"");
        if (subject) |sj| if (std.mem.eql(u8, sj, x.s)) try b.appendSlice(a, " aria-current=\"true\"");
        try b.appendSlice(a, ">");
        try esc(a, &b, x.s);
        try b.print(a, " <span class=\"dim\">{d}</span></a>", .{x.n});
    }
    try b.appendSlice(a, "</div>");
    if (rows.items.len == 0) try b.appendSlice(a, "<p class=\"empty\">No memories match.</p>");
    for (rows.items) |x| try card(c, &b, x);
    if (q == null and rows.items.len == page_n) {
        try b.print(a, "<p class=\"more\"><a href=\"/panel/atoms?before={d}&amp;status={s}", .{ rows.items[rows.items.len - 1].id, status });
        if (subject) |sj| {
            try b.appendSlice(a, "&amp;subject=");
            try html.urlEnc(a, &b, sj);
        }
        try b.appendSlice(a, "\">Older →</a></p>");
    }
    try html.end(a, &b, &c.nonce);
    return c.page(200, b.items);
}

fn dt(c: *Ctx, b: *Buf, k: []const u8, v: ?[]const u8) !void {
    try b.print(c.a, "<dt>{s}</dt><dd>", .{k});
    if (v) |x| try esc(c.a, b, x) else try b.appendSlice(c.a, "<span class=\"dim\">—</span>");
    try b.appendSlice(c.a, "</dd>");
}

pub fn atom(c: *Ctx) !http.Response {
    const a = c.a;
    const id = c.q.int("id") orelse return c.fail(400, "id is required");
    const scope = c.scope();
    var b: Buf = .empty;
    if (scope.names.len == 0) return c.fail(404, "no such memory in this seat's scopes");
    const rd = c.p.h.readers.acquire();
    defer c.p.h.readers.release(rd);
    const raw = (try store.atoms.get(rd, a, scope, id)) orelse return c.fail(404, "no such memory in this seat's scopes");
    const raw_text = raw.text;
    var x = raw;
    if (!try visible(c, rd, &x)) return c.fail(404, "no such memory in this seat's scopes");

    try html.begin(a, &b, c.shell("Memory", .atoms));
    try flash(c, &b);
    try b.appendSlice(a, "<section class=\"card\"><div class=\"meta\">");
    try b.appendSlice(a, "<a class=\"subj\" href=\"/panel/atoms?subject=");
    try html.urlEnc(a, &b, x.subject);
    try b.appendSlice(a, "\">");
    try esc(a, &b, x.subject);
    try b.appendSlice(a, "</a><span>");
    try esc(a, &b, x.type);
    try b.appendSlice(a, "</span>");
    try statusBadge(c, &b, x.status);
    try b.print(a, "<span class=\"dim\">#{d}</span></div><p class=\"big\">", .{x.id});
    try esc(a, &b, x.text);
    try b.appendSlice(a, "</p>");
    if (x.superseded_by) |n| try b.print(a, "<p>Replaced by <a href=\"/panel/atom?id={d}\">#{d}</a>.</p>", .{ n, n });
    try b.appendSlice(a, "</section>");

    // Provenance: columns the API does not return, read for this already scope-checked row.
    try b.appendSlice(a, "<section class=\"card\"><h2>Provenance</h2><dl class=\"kv\">");
    try dt(c, &b, "scope", x.scope);
    try dt(c, &b, "priority", try std.fmt.allocPrint(a, "{d}", .{x.priority}));
    try dt(c, &b, "valid from", x.valid_from);
    try dt(c, &b, "valid to", x.valid_to);
    try b.appendSlice(a, "<dt>recorded</dt><dd>");
    try html.when(a, &b, x.recorded_ms);
    try b.appendSlice(a, "</dd>");
    var src_turn: ?i64 = null;
    var run_id: ?[]const u8 = null;
    {
        var s = try rd.db.prepare("SELECT src_l0, extractor, hex(prompt_sha), run_id, hex(sha256), lineage FROM atoms WHERE id = ?1");
        defer s.deinit();
        try s.bind(1, x.id);
        if (try s.step()) {
            const src = if (s.isNull(0)) null else try a.dupe(u8, s.text(0));
            try dt(c, &b, "source", src);
            try dt(c, &b, "extractor", if (s.isNull(1)) null else s.text(1));
            try dt(c, &b, "prompt sha256", if (s.text(2).len == 0) null else s.text(2));
            run_id = if (s.isNull(3)) null else try a.dupe(u8, s.text(3));
            try dt(c, &b, "run", run_id);
            try dt(c, &b, "content sha256", s.text(4));
            try dt(c, &b, "lineage", s.text(5));
            if (src) |sv| if (std.mem.startsWith(u8, sv, "turn=")) {
                const e = std.mem.indexOfScalar(u8, sv, ' ') orelse sv.len;
                src_turn = std.fmt.parseInt(i64, sv[5..e], 10) catch null;
            };
        }
    }
    try b.appendSlice(a, "</dl>");
    if (run_id) |r| {
        var s = try rd.db.prepare("SELECT kind, model, started_ms, ended_ms, outcome FROM runs WHERE id = ?1");
        defer s.deinit();
        try s.bind(1, r);
        if (try s.step()) {
            try b.appendSlice(a, "<h3>Run</h3><dl class=\"kv\">");
            try dt(c, &b, "kind", s.text(0));
            try dt(c, &b, "model", if (s.isNull(1)) null else s.text(1));
            try b.appendSlice(a, "<dt>started</dt><dd>");
            try html.when(a, &b, s.int(2));
            try b.appendSlice(a, "</dd>");
            try dt(c, &b, "outcome", if (s.isNull(4)) null else s.text(4));
            try b.appendSlice(a, "</dl>");
        }
    }
    if (src_turn) |tid| {
        var sql: std.ArrayList(u8) = .empty;
        try sql.appendSlice(a, "SELECT role, text, ts_ms, session_id, scope FROM l0 WHERE id = ?1 AND ");
        try scope.sqlIn(a, &sql, "scope", 2);
        var s = try rd.db.prepare(sql.items);
        defer s.deinit();
        try s.bind(1, tid);
        try scope.bind(s, 2);
        if (try s.step() and try retrieval.gateTurn(&c.p.h.eng, a, rd, c.p.h.readers.slotOf(rd), c.house(), s.text(4), s.text(1))) {
            try b.print(a, "<h3>Source turn #{d}</h3><blockquote><div class=\"dim small\">", .{tid});
            try esc(a, &b, s.text(0));
            try b.appendSlice(a, " · ");
            try esc(a, &b, s.text(3));
            try b.appendSlice(a, " · ");
            try html.when(a, &b, s.int(2));
            try b.appendSlice(a, "</div>");
            try html.escCut(a, &b, s.text(1), 2000);
            try b.appendSlice(a, "</blockquote>");
        }
    }
    try b.appendSlice(a, "</section>");

    // Lineage: every version, oldest first.
    const hist = try store.atoms.history(rd, a, scope, x.lineage);
    try b.print(a, "<section class=\"card\"><h2>History <span class=\"dim\">{d} version{s}</span></h2><ol class=\"hist\">", .{ hist.len, if (hist.len == 1) "" else "s" });
    for (hist) |v0| {
        var v = v0;
        if (!try visible(c, rd, &v)) continue;
        try b.print(a, "<li{s}><div class=\"meta\"><a href=\"/panel/atom?id={d}\">#{d}</a>", .{ if (v.id == x.id) " class=\"me\"" else "", v.id, v.id });
        try statusBadge(c, &b, v.status);
        try b.appendSlice(a, "<span class=\"dim\">");
        try html.when(a, &b, v.recorded_ms);
        try b.appendSlice(a, "</span>");
        if (v.valid_to) |t| {
            try b.appendSlice(a, "<span class=\"dim\">to ");
            try esc(a, &b, t);
            try b.appendSlice(a, "</span>");
        }
        try b.appendSlice(a, "</div>");
        try html.escCut(a, &b, v.text, 600);
        try b.appendSlice(a, "</li>");
    }
    try b.appendSlice(a, "</ol></section>");

    // Audit rows for every version of the lineage.
    {
        var sql: std.ArrayList(u8) = .empty;
        try sql.appendSlice(a, "SELECT ts_ms, seat, action, row_id, detail FROM audit WHERE table_name = 'atoms' AND row_id IN (");
        for (hist, 0..) |v, i| try sql.print(a, "{s}{d}", .{ if (i == 0) "" else ",", v.id });
        if (hist.len == 0) try sql.print(a, "{d}", .{x.id});
        try sql.appendSlice(a, ") ORDER BY id DESC LIMIT 100");
        var s = try rd.db.prepare(sql.items);
        defer s.deinit();
        try b.appendSlice(a, "<section class=\"card\"><h2>Audit</h2><ul class=\"audit\">");
        while (try s.step()) {
            try b.appendSlice(a, "<li><span class=\"dim\">");
            try html.when(a, &b, s.int(0));
            try b.print(a, "</span> #{d} <b>", .{s.int(3)});
            try esc(a, &b, s.text(2));
            try b.appendSlice(a, "</b> by ");
            try esc(a, &b, s.text(1));
            if (!s.isNull(4)) {
                try b.appendSlice(a, " <span class=\"dim\">");
                try html.escCut(a, &b, s.text(4), 300);
                try b.appendSlice(a, "</span>");
            }
            try b.appendSlice(a, "</li>");
        }
        try b.appendSlice(a, "</ul></section>");
    }
    var editable = x;
    editable.text = raw_text; // the correction form edits the stored text, not the served annotation
    try actionsFor(c, &b, editable);
    try html.end(a, &b, &c.nonce);
    return c.page(200, b.items);
}

fn actionsFor(c: *Ctx, b: *Buf, x: store.atoms.Atom) !void {
    const a = c.a;
    const st = c.seat();
    const csrf: []const u8 = &c.who.?.csrf_hex;
    if (!c.house().mayWrite(x.scope)) {
        try b.appendSlice(a, "<p class=\"dim\">This seat cannot change this memory.</p>");
        return;
    }
    if (x.status == .active) {
        try b.print(a, "<section class=\"card\"><h2>Correct it</h2><p class=\"dim small\">Writes a new version; this one is kept as superseded.</p>" ++
            "<form method=\"post\" action=\"/panel/atom/supersede\"><input type=\"hidden\" name=\"id\" value=\"{d}\">", .{x.id});
        try html.csrfField(a, b, csrf);
        try b.appendSlice(a, "<label>New text<textarea name=\"text\" rows=\"4\" required maxlength=\"8000\">");
        try esc(a, b, x.text);
        try b.appendSlice(a, "</textarea></label><label>Valid from (optional, YYYY-MM-DD)<input name=\"valid_from\" inputmode=\"numeric\" pattern=\"\\d{4}-\\d{2}-\\d{2}\"></label>" ++
            "<button type=\"submit\">Save new version</button></form></section>");
    }
    if (x.status == .active or x.status == .pending_review) {
        try b.print(a, "<section class=\"card\"><h2>Status</h2><form method=\"post\" action=\"/panel/atom/status\" class=\"row\"><input type=\"hidden\" name=\"id\" value=\"{d}\">", .{x.id});
        try html.csrfField(a, b, csrf);
        try b.appendSlice(a, "<input name=\"reason\" placeholder=\"Reason (optional)\" maxlength=\"300\" aria-label=\"Reason\">");
        if (x.status == .pending_review and st.trusted)
            try b.appendSlice(a, "<button type=\"submit\" name=\"to\" value=\"active\">Approve</button>");
        if (x.status == .active)
            try b.appendSlice(a, "<button type=\"submit\" name=\"to\" value=\"pending_review\" class=\"quiet\">Back to review</button>");
        try b.appendSlice(a, "<button type=\"submit\" name=\"to\" value=\"retired\" class=\"warn\" data-confirm=\"Retire this memory? It stays in the history.\">Retire</button></form></section>");
    }
}

pub fn queue(c: *Ctx) !http.Response {
    const a = c.a;
    const scope = c.scope();
    var b: Buf = .empty;
    try html.begin(a, &b, c.shell("Queue", .queue));
    if (scope.names.len == 0) {
        try b.appendSlice(a, "<p class=\"empty\">No scopes.</p>");
        try html.end(a, &b, &c.nonce);
        return c.page(200, b.items);
    }
    const rd = c.p.h.readers.acquire();
    defer c.p.h.readers.release(rd);
    try b.appendSlice(a, "<section class=\"card\"><h2>Extraction queue <span class=\"dim\">(this seat's scopes)</span></h2><dl class=\"kv\">");
    {
        var sql: std.ArrayList(u8) = .empty;
        try sql.appendSlice(a, "SELECT j.state, count(*) FROM jobs j JOIN l0 l ON l.id = CAST(j.key AS INTEGER) WHERE j.kind = 'extract' AND ");
        try scope.sqlIn(a, &sql, "l.scope", 1);
        try sql.appendSlice(a, " GROUP BY j.state ORDER BY j.state");
        var s = try rd.db.prepare(sql.items);
        defer s.deinit();
        try scope.bind(s, 1);
        var any = false;
        while (try s.step()) {
            any = true;
            try b.appendSlice(a, "<dt>");
            try esc(a, &b, s.text(0));
            try b.print(a, "</dt><dd>{d}</dd>", .{s.int(1)});
        }
        if (!any) try b.appendSlice(a, "<dt>jobs</dt><dd>0</dd>");
    }
    var sqlp: std.ArrayList(u8) = .empty;
    try sqlp.appendSlice(a, "SELECT count(*) FROM atoms WHERE status = 'pending_review' AND ");
    try scope.sqlIn(a, &sqlp, "scope", 1);
    var sp = try rd.db.prepare(sqlp.items);
    defer sp.deinit();
    try scope.bind(sp, 1);
    const pending: i64 = if (try sp.step()) sp.int(0) else 0;
    try b.print(a, "<dt>awaiting review</dt><dd><a href=\"/panel/atoms?status=pending_review\">{d}</a></dd></dl></section>", .{pending});

    var sql: std.ArrayList(u8) = .empty;
    try sql.appendSlice(a, "SELECT j.id, j.state, j.tries, j.due_ms, j.last_err, l.id, l.role, l.text, l.scope FROM jobs j JOIN l0 l ON l.id = CAST(j.key AS INTEGER) " ++
        "WHERE j.kind = 'extract' AND ");
    try scope.sqlIn(a, &sql, "l.scope", 1);
    try sql.appendSlice(a, " ORDER BY j.id DESC LIMIT 50");
    var s = try rd.db.prepare(sql.items);
    defer s.deinit();
    try scope.bind(s, 1);
    try b.appendSlice(a, "<section class=\"card\"><h2>Recent jobs</h2><ul class=\"jobs\">");
    var n: usize = 0;
    while (try s.step()) : (n += 1) {
        try b.print(a, "<li><div class=\"meta\"><span>job #{d}</span><span class=\"badge job-", .{s.int(0)});
        try esc(a, &b, s.text(1));
        try b.appendSlice(a, "\">");
        try esc(a, &b, s.text(1));
        try b.print(a, "</span><span class=\"dim\">tries {d} · turn #{d} · ", .{ s.int(2), s.int(5) });
        try esc(a, &b, s.text(6));
        try b.appendSlice(a, "</span></div><div class=\"txt\">");
        if (try retrieval.gateTurn(&c.p.h.eng, a, rd, c.p.h.readers.slotOf(rd), c.house(), s.text(8), s.text(7))) {
            try html.escCut(a, &b, s.text(7), 240);
        } else try b.appendSlice(a, "<span class=\"dim\">(withheld: about someone else)</span>");
        try b.appendSlice(a, "</div>");
        if (!s.isNull(4)) {
            try b.appendSlice(a, "<div class=\"err small\">");
            try html.escCut(a, &b, s.text(4), 300);
            try b.appendSlice(a, "</div>");
        }
        try b.appendSlice(a, "</li>");
    }
    if (n == 0) try b.appendSlice(a, "<li class=\"empty\">No extraction jobs for these scopes.</li>");
    try b.appendSlice(a, "</ul></section>");
    try html.end(a, &b, &c.nonce);
    return c.page(200, b.items);
}

fn flat(c: *Ctx, b: *Buf, prefix: []const u8, v: std.json.Value) !void {
    switch (v) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| try flat(c, b, if (prefix.len == 0) e.key_ptr.* else try std.fmt.allocPrint(c.a, "{s}.{s}", .{ prefix, e.key_ptr.* }), e.value_ptr.*);
        },
        else => {
            try b.appendSlice(c.a, "<dt>");
            try esc(c.a, b, prefix);
            try b.appendSlice(c.a, "</dt><dd>");
            switch (v) {
                .string => |s| try esc(c.a, b, s),
                .integer => |i| try b.print(c.a, "{d}", .{i}),
                .float => |f| try b.print(c.a, "{d:.2}", .{f}),
                .bool => |x| try b.appendSlice(c.a, if (x) "yes" else "no"),
                .null => try b.appendSlice(c.a, "—"),
                else => try b.appendSlice(c.a, "…"),
            }
            try b.appendSlice(c.a, "</dd>");
        },
    }
}

pub fn health(c: *Ctx) !http.Response {
    const a = c.a;
    const body = try c.p.h.health(a);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    var b: Buf = .empty;
    try html.begin(a, &b, c.shell("Health", .health));
    try b.appendSlice(a, "<section class=\"card\"><h2>Hub</h2><dl class=\"kv\">");
    try flat(c, &b, "", v);
    try b.print(a, "<dt>panel.version</dt><dd>{s}</dd><dt>panel.sessions</dt><dd>{d}</dd></dl></section>", .{ panel.version, c.p.sess.count(c.now()) });
    try html.end(a, &b, &c.nonce);
    return c.page(200, b.items);
}
