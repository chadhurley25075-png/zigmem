//! zigmem phase 6: the minimal web panel, served by `zigmem serve` under /panel on the same 127.0.0.1 port.
//! `wrap` puts it in front of the hub's REST handler: /panel and /panel/* come here, everything else passes through
//! untouched. Server-rendered HTML, one embedded CSS + ~40 lines of JS, a strict nonce CSP, no external anything.
//! Guards on every request: Host allowlist (DNS rebinding), GET/POST only; on POST: same-origin Origin and
//! Sec-Fetch-Site, form content type, and the session's CSRF token. Every route but the login page needs a session.
const std = @import("std");
const api = @import("api");
const store = @import("store");
const http = api.http;
const auth = api.auth;
const access = api.access;
const Hub = api.hub.Hub;
const Audit = api.hub.Audit;
pub const html = @import("html.zig");
pub const session = @import("session.zig");
const pages = @import("pages.zig");
const actions = @import("actions.zig");

pub const version = "0.6.0";

pub const Panel = struct {
    h: *Hub,
    inner: http.Handler,
    sess: session.Store,
    /// Serialises token-file rewrites from the panel.
    tok_mu: std.Io.Mutex = .init,
    hosts: [3][]const u8,
};

/// Called by `zigmem serve`: the returned handler serves /panel and forwards every other path to `inner`.
pub fn wrap(h: *Hub, inner: http.Handler) anyerror!http.Handler {
    const p = try h.gpa.create(Panel);
    const b = h.cfg.bind;
    p.* = .{
        .h = h,
        .inner = inner,
        .sess = try session.Store.init(h.io),
        .hosts = .{
            try std.fmt.allocPrint(h.gpa, "127.0.0.1:{d}", .{h.cfg.port}),
            try std.fmt.allocPrint(h.gpa, "localhost:{d}", .{h.cfg.port}),
            try std.fmt.allocPrint(h.gpa, "{d}.{d}.{d}.{d}:{d}", .{ b[0], b[1], b[2], b[3], h.cfg.port }),
        },
    };
    return .{ .ctx = p, .f = handle };
}

pub fn isPanelPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/panel") or std.mem.startsWith(u8, path, "/panel/");
}

fn handle(ctx: *anyopaque, a: std.mem.Allocator, req: http.Request) http.Response {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    if (!isPanelPath(req.path)) return p.inner.f(p.inner.ctx, a, req);
    const t0 = std.Io.Timestamp.now(p.h.io, .awake).nanoseconds;
    var au: Audit = .{ .route = req.path };
    var c: Ctx = .{ .p = p, .a = a, .req = req, .au = &au, .nonce = undefined };
    p.h.io.random(&c.nonce_raw);
    c.nonce = std.fmt.bytesToHex(c.nonce_raw, .lower);
    const resp = serve(&c) catch |e| blk: {
        au.denied = "internal error";
        break :blk c.fail(500, @errorName(e));
    };
    const ms = @as(f64, @floatFromInt(std.Io.Timestamp.now(p.h.io, .awake).nanoseconds - t0)) / 1e6;
    p.h.audit(a, au, resp.status, ms, req.body.len, resp.body.len);
    return resp;
}

pub const Ctx = struct {
    p: *Panel,
    a: std.mem.Allocator,
    req: http.Request,
    au: *Audit,
    q: html.Form = .{},
    f: html.Form = .{},
    who: ?session.Who = null,
    /// The session seat's household identity (scopes, role), resolved live on every request (integration).
    hw: ?access.Who = null,
    nonce_raw: [16]u8 = undefined,
    nonce: [32]u8,
    set_cookie: []const u8 = "",

    pub fn seat(c: *const Ctx) *const auth.Seat {
        return c.who.?.seat;
    }
    /// Every scope the seat may read: household policy ∩ the token's narrowing (never the token's list alone).
    pub fn scope(c: *const Ctx) store.Scope {
        return c.hw.?.scope();
    }
    pub fn house(c: *const Ctx) *const access.Who {
        return &c.hw.?;
    }
    pub fn now(c: *const Ctx) i64 {
        return c.p.h.nowMs();
    }
    pub fn shell(c: *const Ctx, title: []const u8, nav: html.Nav) html.Shell {
        return .{ .title = title, .nav = nav, .seat = if (c.who) |w| w.seat.name else null, .csrf = if (c.who) |*w| &w.csrf_hex else null, .nonce = &c.nonce };
    }

    fn headers(c: *const Ctx, more: []const u8) []const u8 {
        return std.fmt.allocPrint(c.a, "Content-Security-Policy: default-src 'none'; style-src 'nonce-{s}'; script-src 'nonce-{s}'; " ++
            "img-src 'none'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'\r\n" ++
            "X-Frame-Options: DENY\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: same-origin\r\n" ++
            "Cross-Origin-Opener-Policy: same-origin\r\nCross-Origin-Resource-Policy: same-origin\r\nVary: Cookie\r\n{s}{s}", .{ c.nonce, c.nonce, c.set_cookie, more }) catch "";
    }

    pub fn page(c: *const Ctx, status: u16, body: []const u8) http.Response {
        return .{ .status = status, .body = body, .ctype = "text/html; charset=utf-8", .extra = c.headers("") };
    }

    /// 303 to a fixed, server-built panel path (never a user-supplied URL).
    pub fn redirect(c: *const Ctx, loc: []const u8) http.Response {
        std.debug.assert(std.mem.startsWith(u8, loc, "/panel/"));
        for (loc) |ch| std.debug.assert(ch > 0x20 and ch < 0x7f);
        return .{ .status = 303, .ctype = "text/plain; charset=utf-8", .extra = c.headers(std.fmt.allocPrint(c.a, "Location: {s}\r\n", .{loc}) catch "Location: /panel/atoms\r\n") };
    }

    /// An error page; `msg` is escaped like everything else.
    pub fn fail(c: *Ctx, status: u16, msg: []const u8) http.Response {
        var b: html.Buf = .empty;
        const title = http.reason(status);
        build: {
            html.begin(c.a, &b, c.shell(title, .none)) catch break :build;
            b.print(c.a, "<section class=\"card err\"><h1>{d} {s}</h1><p>", .{ status, title }) catch break :build;
            html.esc(c.a, &b, msg) catch break :build;
            b.appendSlice(c.a, "</p><p><a href=\"/panel/atoms\">Back to memories</a></p></section>") catch break :build;
            html.end(c.a, &b, &c.nonce) catch break :build;
            return c.page(status, b.items);
        }
        return .{ .status = status, .body = "error", .ctype = "text/plain; charset=utf-8" };
    }

    pub fn deny(c: *Ctx, status: u16, why: []const u8) http.Response {
        c.au.denied = why;
        return c.fail(status, why);
    }
};

fn hostOk(p: *const Panel, host: ?[]const u8) bool {
    const h = host orelse return false;
    for (p.hosts) |x| if (std.mem.eql(u8, h, x)) return true;
    return false;
}

/// Same-origin proof for a state-changing request. A browser always sends Origin on POST; a request that carries
/// one must name this exact origin, and Sec-Fetch-Site (when present) must say same-origin.
fn originOk(c: *Ctx) bool {
    const host = c.req.header("host").?;
    if (c.req.header("sec-fetch-site")) |s| if (!std.mem.eql(u8, s, "same-origin")) return false;
    if (c.req.header("origin")) |o| {
        if (!std.mem.startsWith(u8, o, "http://")) return false;
        if (!std.mem.eql(u8, o[7..], host)) return false;
    }
    return true;
}

fn isFormType(ct: ?[]const u8) bool {
    const v = ct orelse return false;
    const base = std.mem.trim(u8, v[0 .. std.mem.indexOfScalar(u8, v, ';') orelse v.len], " \t");
    return std.ascii.eqlIgnoreCase(base, "application/x-www-form-urlencoded");
}

fn serve(c: *Ctx) !http.Response {
    const req = c.req;
    if (!hostOk(c.p, req.header("host"))) return c.deny(403, "unexpected Host header (the panel answers only on its own address)");
    const get = std.mem.eql(u8, req.method, "GET");
    const post = std.mem.eql(u8, req.method, "POST");
    if (!get and !post) return c.deny(405, "GET or POST only");
    c.q = html.Form.parse(c.a, req.query) catch return c.deny(400, "malformed query string");
    if (post) {
        if (!originOk(c)) return c.deny(403, "cross-origin request refused");
        if (!isFormType(req.header("content-type"))) return c.deny(415, "form posts only (application/x-www-form-urlencoded)");
        c.f = html.Form.parse(c.a, req.body) catch return c.deny(400, "malformed form body");
    }
    const path = req.path;
    if (std.mem.eql(u8, path, "/panel/login")) return if (get) actions.loginPage(c, null) else actions.login(c);
    const table = c.p.h.tokens.current();
    c.who = c.p.sess.check(html.cookie(req.header("cookie"), session.cookie_name), table, c.now());
    if (c.who == null) {
        c.au.denied = "no panel session";
        if (get) return c.redirect("/panel/login");
        return c.fail(401, "your panel session is missing or has ended; log in again");
    }
    c.au.seat = c.seat().name;
    c.hw = switch (try api.rest.identifySeat(c.p.h, c.a, c.seat())) {
        .ok => |w| w,
        else => |x| return c.deny(403, switch (x) {
            .forbidden => |why| why,
            else => "seat not permitted",
        }),
    };
    if (post) {
        if (!session.tokenEq(c.f.get("csrf"), &c.who.?.csrf_hex)) return c.deny(403, "missing or wrong CSRF token");
        if (std.mem.eql(u8, path, "/panel/logout")) return actions.logout(c);
        if (std.mem.eql(u8, path, "/panel/atom/supersede")) return actions.supersede(c);
        if (std.mem.eql(u8, path, "/panel/atom/status")) return actions.status(c);
        if (std.mem.eql(u8, path, "/panel/seats/create")) return actions.seatCreate(c);
        if (std.mem.eql(u8, path, "/panel/seats/revoke")) return actions.seatRevoke(c);
        return c.fail(404, "no such action");
    }
    if (std.mem.eql(u8, path, "/panel") or std.mem.eql(u8, path, "/panel/")) return c.redirect("/panel/atoms");
    if (std.mem.eql(u8, path, "/panel/atoms")) return pages.atoms(c);
    if (std.mem.eql(u8, path, "/panel/atom")) return pages.atom(c);
    if (std.mem.eql(u8, path, "/panel/queue")) return pages.queue(c);
    if (std.mem.eql(u8, path, "/panel/health")) return pages.health(c);
    if (std.mem.eql(u8, path, "/panel/seats")) return actions.seatsPage(c, null);
    return c.fail(404, "no such page");
}

test {
    _ = html;
    _ = session;
    _ = pages;
    _ = actions;
}

test "content-type and panel path checks" {
    try std.testing.expect(isFormType("application/x-www-form-urlencoded; charset=UTF-8"));
    try std.testing.expect(!isFormType("text/plain"));
    try std.testing.expect(!isFormType("multipart/form-data; boundary=x"));
    try std.testing.expect(!isFormType(null));
    try std.testing.expect(isPanelPath("/panel") and isPanelPath("/panel/x") and !isPanelPath("/panelx") and !isPanelPath("/v1/recall"));
}
