//! State changes (all POST, all behind the CSRF + same-origin guard in panel.zig) and the two pages that carry
//! forms for them: login, and seats. Nothing is deleted anywhere: supersede writes a new version, status changes
//! are flips with an audit row, revocation stamps `revoked_ms`. A new seat token is shown exactly once, in the
//! response to its creation; only its sha256 is stored.
const std = @import("std");
const api = @import("api");
const store = @import("store");
const http = api.http;
const auth = api.auth;
const access = api.access;
const panel = @import("panel.zig");
const html = @import("html.zig");
const session = @import("session.zig");
const pages = @import("pages.zig");
const Ctx = panel.Ctx;
const Buf = html.Buf;
const esc = html.esc;

// ---- login / logout ----

pub fn loginPage(c: *Ctx, err: ?[]const u8) !http.Response {
    const a = c.a;
    const pre = try c.p.sess.newPre();
    const tok = c.p.sess.loginToken(&pre);
    c.set_cookie = try std.fmt.allocPrint(a, "Set-Cookie: {s}={s}; Path=/panel; HttpOnly; SameSite=Strict; Max-Age={d}\r\n", .{ session.pre_name, &pre, session.pre_ttl_s });
    var b: Buf = .empty;
    try html.begin(a, &b, c.shell("Log in", .none));
    try b.appendSlice(a, "<section class=\"card narrow\"><h1>Log in</h1><p class=\"dim\">Paste a seat token. It is checked once and never stored " ++
        "in the browser; the panel keeps a session cookie instead.</p>");
    if (err) |e| {
        try b.appendSlice(a, "<p class=\"err\" role=\"alert\">");
        try esc(a, &b, e);
        try b.appendSlice(a, "</p>");
    }
    try b.appendSlice(a, "<form method=\"post\" action=\"/panel/login\" autocomplete=\"off\">");
    try html.csrfField(a, &b, &tok);
    try b.appendSlice(a, "<label>Seat token<input type=\"password\" name=\"token\" required autocomplete=\"off\" autocapitalize=\"off\" spellcheck=\"false\"></label>" ++
        "<button type=\"submit\">Log in</button></form></section>");
    try html.end(a, &b, &c.nonce);
    return c.page(if (err == null) 200 else 401, b.items);
}

pub fn login(c: *Ctx) !http.Response {
    const pre = html.cookie(c.req.header("cookie"), session.pre_name) orelse return c.deny(403, "login form expired or opened elsewhere; reload the login page");
    if (pre.len != 32) return c.deny(403, "login form expired; reload the login page");
    if (!session.tokenEq(c.f.get("csrf"), &c.p.sess.loginToken(pre))) return c.deny(403, "missing or wrong CSRF token");
    const tok = std.mem.trim(u8, c.f.get("token") orelse "", " \t\r\n");
    if (tok.len == 0 or tok.len > 256) return failLogin(c, "enter a seat token");
    const table = c.p.h.tokens.current() orelse return failLogin(c, "token table unavailable (fail closed)");
    const seat = switch (table.verify(tok)) {
        .ok => |s| s,
        else => return failLogin(c, "that token is not valid"),
    };
    const ck = try c.p.sess.create(seat.hash, c.now());
    c.au.seat = seat.name;
    c.set_cookie = try std.fmt.allocPrint(c.a, "Set-Cookie: {s}={s}; Path=/panel; HttpOnly; SameSite=Strict; Max-Age={d}\r\n" ++
        "Set-Cookie: {s}=; Path=/panel; HttpOnly; SameSite=Strict; Max-Age=0\r\n", .{ session.cookie_name, &ck, @divTrunc(session.absolute_ms, 1000), session.pre_name });
    return c.redirect("/panel/atoms");
}

fn failLogin(c: *Ctx, msg: []const u8) !http.Response {
    c.au.denied = "login failed";
    return loginPage(c, msg);
}

pub fn logout(c: *Ctx) !http.Response {
    c.p.sess.drop(c.who.?.slot);
    c.set_cookie = try std.fmt.allocPrint(c.a, "Set-Cookie: {s}=; Path=/panel; HttpOnly; SameSite=Strict; Max-Age=0\r\n", .{session.cookie_name});
    return c.redirect("/panel/login");
}

// ---- memories ----

fn validDate(s: []const u8) bool {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return false;
    for (s, 0..) |ch, i| if (i != 4 and i != 7 and !std.ascii.isDigit(ch)) return false;
    return true;
}

fn needWrites(c: *Ctx) ?http.Response {
    if (!c.seat().writes) return c.deny(403, "this seat is read-only");
    return null;
}

fn screen(c: *Ctx, text: []const u8) ?http.Response {
    if (c.seat().trusted) return null;
    if (api.screen.find(text) != null) return c.deny(403, "refused by the privacy screen (untrusted seat): family, medical or money text");
    return null;
}

pub fn supersede(c: *Ctx) !http.Response {
    if (needWrites(c)) |r| return r;
    const id = c.f.int("id") orelse return c.fail(400, "id is required");
    const text = std.mem.trim(u8, c.f.get("text") orelse "", " \t\r\n");
    if (text.len == 0 or text.len > 8000) return c.fail(400, "text must be 1-8000 bytes");
    if (screen(c, text)) |r| return r;
    const vf = c.f.val("valid_from");
    if (vf) |v| if (!validDate(v)) return c.fail(400, "valid from must be YYYY-MM-DD");
    const old = (try visibleAtom(c, id)) orelse return c.fail(404, "no such memory in this seat's scopes");
    if (!c.house().mayWrite(old.scope)) return c.deny(403, "this seat cannot change this memory");
    if (std.mem.eql(u8, old.raw_text, text)) return c.fail(400, "the new text is the same as the old");
    const n: store.atoms.New = .{ .subject = old.subject, .scope = old.scope, .type = old.type, .text = text, .priority = old.priority, .valid_from = vf, .extractor = "panel", .seat = c.seat().name };
    const new_id = c.p.h.writer.call(access.supersedeOp, .{ c.a, id, n, @as(?[]const u8, null), @as(?bool, null) }) catch |e| return switch (e) {
        error.NotActive => c.fail(409, "only an active memory can be corrected"),
        else => e,
    };
    return c.redirect(try std.fmt.allocPrint(c.a, "/panel/atom?id={d}&msg=superseded", .{new_id}));
}

const Seen = struct { subject: []const u8, scope: []const u8, type: []const u8, priority: i64, raw_text: []const u8 };

/// An atom this seat may see (readable scope + household/medical gates, as on the pages), or null.
fn visibleAtom(c: *Ctx, id: i64) !?Seen {
    if (c.scope().names.len == 0) return null;
    const rd = c.p.h.readers.acquire();
    defer c.p.h.readers.release(rd);
    var x = (try store.atoms.get(rd, c.a, c.scope(), id)) orelse return null;
    const raw = x.text;
    if (!try pages.visible(c, rd, &x)) return null;
    return .{ .subject = x.subject, .scope = x.scope, .type = x.type, .priority = x.priority, .raw_text = raw };
}

fn statusOp(st: *store.Store, id: i64, to: store.atoms.Status, seat: []const u8, reason: ?[]const u8) !void {
    try store.atoms.setStatus(st, id, to, seat);
    if (reason) |r| try st.audit(seat, "reason", "atoms", id, r);
}

pub fn status(c: *Ctx) !http.Response {
    if (needWrites(c)) |r| return r;
    const id = c.f.int("id") orelse return c.fail(400, "id is required");
    const to_s = c.f.get("to") orelse return c.fail(400, "to is required");
    const to = std.meta.stringToEnum(store.atoms.Status, to_s) orelse return c.fail(400, "unknown status");
    if (to == .superseded) return c.fail(400, "use Correct it to supersede");
    // Approving a reviewed memory is a ratification: trusted seats only (SPEC §4, the review pipeline: nobody writes canon directly).
    if (to == .active and !c.seat().trusted) return c.deny(403, "only a trusted seat can approve a memory");
    const reason = c.f.val("reason");
    if (reason) |r| {
        if (r.len > 300) return c.fail(400, "reason is longer than 300 bytes");
        if (screen(c, r)) |resp| return resp;
    }
    const x = (try visibleAtom(c, id)) orelse return c.fail(404, "no such memory in this seat's scopes");
    if (!c.house().mayWrite(x.scope)) return c.deny(403, "this seat cannot change this memory");
    c.p.h.writer.call(statusOp, .{ id, to, c.seat().name, reason }) catch |e| return switch (e) {
        error.BadTransition => c.fail(409, "that status change is not allowed from the memory's current status"),
        else => e,
    };
    return c.redirect(try std.fmt.allocPrint(c.a, "/panel/atom?id={d}&msg={s}", .{ id, @tagName(to) }));
}

// ---- seats ----

fn seatRow(c: *Ctx, b: *Buf, s: auth.Seat, admin_view: bool) !void {
    const a = c.a;
    try b.appendSlice(a, "<li><div class=\"meta\"><b>");
    try esc(a, b, s.name);
    try b.appendSlice(a, "</b>");
    if (s.revoked_ms != null) try b.appendSlice(a, "<span class=\"badge st-retired\">revoked</span>") else try b.appendSlice(a, "<span class=\"badge st-active\">active</span>");
    if (s.writes) try b.appendSlice(a, "<span class=\"badge\">writes</span>");
    if (s.trusted) try b.appendSlice(a, "<span class=\"badge\">trusted</span>");
    if (s.admin) try b.appendSlice(a, "<span class=\"badge\">admin</span>");
    try b.appendSlice(a, "</div><div class=\"small\">scopes: ");
    for (s.scopes, 0..) |x, i| {
        if (i > 0) try b.appendSlice(a, ", ");
        try esc(a, b, x);
    }
    try b.appendSlice(a, "<br>person: ");
    try esc(a, b, s.person orelse "—");
    try b.appendSlice(a, " · created ");
    try html.when(a, b, s.created_ms);
    if (s.revoked_ms) |r| {
        try b.appendSlice(a, " · revoked ");
        try html.when(a, b, r);
    }
    try b.appendSlice(a, "</div>");
    if (admin_view and s.revoked_ms == null and !std.mem.eql(u8, s.name, c.seat().name)) {
        try b.appendSlice(a, "<form method=\"post\" action=\"/panel/seats/revoke\" class=\"row\"><input type=\"hidden\" name=\"seat\" value=\"");
        try esc(a, b, s.name);
        try b.appendSlice(a, "\">");
        try html.csrfField(a, b, &c.who.?.csrf_hex);
        try b.appendSlice(a, "<button type=\"submit\" class=\"warn\" data-confirm=\"Revoke this seat? Its token stops working at once.\">Revoke</button></form>");
    }
    try b.appendSlice(a, "</li>");
}

/// `new_token`: shown once, right after creation, with a copy button. Never rendered anywhere else.
pub fn seatsPage(c: *Ctx, new_token: ?struct { seat: []const u8, token: []const u8 }) !http.Response {
    const a = c.a;
    const me = c.seat();
    const table = c.p.h.tokens.current() orelse return c.fail(503, "token table unavailable (fail closed)");
    var b: Buf = .empty;
    try html.begin(a, &b, c.shell("Seats", .seats));
    try pages.flash(c, &b);
    if (new_token) |nt| {
        try b.appendSlice(a, "<section class=\"card once\"><h2>New token for ");
        try esc(a, &b, nt.seat);
        try b.appendSlice(a, "</h2><p>Copy it now. It is shown this once and cannot be shown again (only its hash is kept).</p><code id=\"newtok\" class=\"tok\">");
        try esc(a, &b, nt.token);
        try b.appendSlice(a, "</code><button type=\"button\" id=\"copytok\">Copy</button></section>");
    }
    try b.appendSlice(a, "<section class=\"card\"><h2>Seats</h2><ul class=\"seats\">");
    const is_admin = c.house().admin();
    for (table.seats) |s| {
        if (!is_admin and !std.mem.eql(u8, s.name, me.name)) continue;
        try seatRow(c, &b, s, is_admin);
    }
    try b.appendSlice(a, "</ul>");
    if (!is_admin) try b.appendSlice(a, "<p class=\"dim small\">Only an admin seat can see other seats or create and revoke tokens.</p>");
    try b.appendSlice(a, "</section>");
    if (is_admin) {
        try b.appendSlice(a, "<section class=\"card\"><h2>New seat</h2><form method=\"post\" action=\"/panel/seats/create\" autocomplete=\"off\">");
        try html.csrfField(a, &b, &c.who.?.csrf_hex);
        try b.appendSlice(a, "<label>Seat name<input name=\"seat\" required maxlength=\"64\" pattern=\"[A-Za-z0-9._\\-]+\" autocapitalize=\"off\"></label>" ++
            "<label>Scopes (comma-separated)<input name=\"scopes\" required maxlength=\"400\" autocapitalize=\"off\"></label>" ++
            "<label>Person (optional)<input name=\"person\" maxlength=\"64\" autocapitalize=\"off\"></label>" ++
            "<div class=\"checks\"><label><input type=\"checkbox\" name=\"writes\" value=\"1\"> writes</label>" ++
            "<label><input type=\"checkbox\" name=\"trusted\" value=\"1\"> trusted</label>" ++
            "<label><input type=\"checkbox\" name=\"admin\" value=\"1\"> admin</label></div>" ++
            "<button type=\"submit\">Create and show the token once</button></form></section>");
    }
    try html.end(a, &b, &c.nonce);
    return c.page(200, b.items);
}

/// Token admin flag AND a household principal (integration).
fn needAdmin(c: *Ctx) ?http.Response {
    if (!c.house().admin()) return c.deny(403, "admin seat required (an admin token held by a household principal)");
    return null;
}

/// Read the token file fresh (under the panel's lock), so a concurrent CLI change is never lost by a stale copy.
fn freshTable(c: *Ctx) !auth.Table {
    const path = c.p.h.tokens.path;
    _ = try auth.checkMode(path);
    return auth.parse(c.a, try auth.readAll(c.a, path, 1 << 20));
}

fn auditSeatOp(st: *store.Store, by: []const u8, action: []const u8, target: []const u8) !void {
    try st.audit(by, action, "seats", null, target);
}

pub fn seatCreate(c: *Ctx) !http.Response {
    if (needAdmin(c)) |r| return r;
    const name = std.mem.trim(u8, c.f.get("seat") orelse "", " ");
    if (!auth.validName(name)) return c.fail(400, "seat name: letters, digits, . _ - (max 64)");
    var sc: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, c.f.get("scopes") orelse "", ',');
    while (it.next()) |raw| {
        const x = std.mem.trim(u8, raw, " ");
        if (x.len == 0) continue;
        if (!auth.validScope(x)) return c.fail(400, "scopes: lowercase letters, digits, : _ - (max 64 each)");
        try sc.append(c.a, x);
    }
    if (sc.items.len == 0 or sc.items.len > 16) return c.fail(400, "1-16 scopes");
    const person = c.f.val("person");
    if (person) |p| if (!auth.validName(p)) return c.fail(400, "person: letters, digits, . _ - (max 64)");
    var buf: [67]u8 = undefined;
    const tok = blk: {
        c.p.tok_mu.lockUncancelable(c.p.h.io);
        defer c.p.tok_mu.unlock(c.p.h.io);
        const table = try freshTable(c);
        if (table.find(name) != null) return c.fail(409, "that seat already has an active token (revoke it first)");
        const t = try auth.newToken(c.p.h.io, &buf);
        var list: std.ArrayList(auth.Seat) = .empty;
        try list.appendSlice(c.a, table.seats);
        try list.append(c.a, .{ .name = name, .hash = auth.hashToken(t), .scopes = sc.items, .writes = c.f.get("writes") != null, .trusted = c.f.get("trusted") != null, .admin = c.f.get("admin") != null, .person = person, .created_ms = c.now(), .revoked_ms = null });
        if (list.items.len > auth.max_seats) return c.fail(409, "too many seats");
        try auth.writeAtomic(c.a, c.p.h.tokens.path, try auth.render(c.a, list.items));
        break :blk t;
    };
    try c.p.h.writer.call(auditSeatOp, .{ c.seat().name, "token_create", name });
    return seatsPage(c, .{ .seat = name, .token = tok });
}

pub fn seatRevoke(c: *Ctx) !http.Response {
    if (needAdmin(c)) |r| return r;
    const name = c.f.get("seat") orelse return c.fail(400, "seat is required");
    if (std.mem.eql(u8, name, c.seat().name)) return c.fail(400, "a seat cannot revoke itself from the panel (use the CLI)");
    var gone: ?[32]u8 = null;
    {
        c.p.tok_mu.lockUncancelable(c.p.h.io);
        defer c.p.tok_mu.unlock(c.p.h.io);
        const table = try freshTable(c);
        for (table.seats) |*s| if (std.mem.eql(u8, s.name, name) and s.revoked_ms == null) {
            s.revoked_ms = c.now();
            gone = s.hash;
        };
        if (gone == null) return c.fail(404, "no active seat by that name");
        try auth.writeAtomic(c.a, c.p.h.tokens.path, try auth.render(c.a, table.seats));
    }
    c.p.sess.dropSeat(gone.?);
    try c.p.h.writer.call(auditSeatOp, .{ c.seat().name, "token_revoke", name });
    return c.redirect("/panel/seats?msg=revoked");
}

test "date check" {
    try std.testing.expect(validDate("2026-10-12"));
    try std.testing.expect(!validDate("2026-1-12"));
    try std.testing.expect(!validDate("2026-10-1x"));
}
