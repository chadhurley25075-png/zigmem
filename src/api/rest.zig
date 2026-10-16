//! Routes. Every route but GET /health needs a seat token. Identity: the token → its seat → that seat's household
//! member, role and readable scopes (access.zig, read live on every request); the token's own scope list can only
//! narrow. Client identity headers (x-*-user-id and kin, x-zigmem-seat) and body user_id/agent_id/team_id/seat are ignored
//! and recorded as such.
//! Every row served passes retrieval.zig (phase-3 retrieval + phase-5 household gate + phase-3 privacy gates).
//! Routes: v1 (`/recall /capture /search/* /session/end`, also under /v1), v3-style compatibility routes
//! (`/v3/conversation/{add,search}`, `/v3/atomic/{search,delete}`), and zigmem's own: /v1/atoms/*, /v1/session/block,
//! /v1/household/*, /admin/retire, /mcp. Nothing is ever deleted: "delete" and "demote" are status flips.
const std = @import("std");
const store = @import("store");
const mcp = @import("mcp");
const hh = @import("household");
const http = @import("http.zig");
const json = @import("json.zig");
const auth = @import("auth.zig");
const screen = @import("screen.zig");
const block = @import("block.zig");
const retriever = @import("retriever.zig");
const retrieval = @import("retrieval.zig");
const access = @import("access.zig");
const render = @import("render.zig");
const hitsJson = render.hitsJson;
const recallContext = render.recallContext;
const atomJson = render.atomJson;
const hub_mod = @import("hub.zig");
const Hub = hub_mod.Hub;
const Audit = hub_mod.Audit;
const Value = json.Value;
const Who = access.Who;

const Fail = error{ BadRequest, Unauthorized, Forbidden, NotFound, Conflict, TooMany, NotImplemented };

pub const Ctx = struct {
    h: *Hub,
    a: std.mem.Allocator,
    seat: *const auth.Seat,
    who: Who,
    au: *Audit,
    msg: []const u8 = "",

    fn fail(c: *Ctx, comptime e: Fail, msg: []const u8) Fail {
        c.msg = msg;
        return e;
    }

    /// A household denial: audited in the store (seat + reason, never the request) and in audit.log, then 403.
    fn deny(c: *Ctx, why: []const u8) Fail {
        c.au.denied = why;
        c.h.writer.call(access.denyOp, .{ c.seat.name, why }) catch {};
        c.msg = why;
        return error.Forbidden;
    }

    /// Requested scopes (`scope` or `scopes`), unvalidated. Absent → empty (= everything readable).
    fn wantScopes(c: *Ctx, v: Value) ![]const []const u8 {
        var want: std.ArrayList([]const u8) = .empty;
        if (try json.array(v, "scopes")) |arr| {
            for (arr) |x| {
                if (x != .string) return c.fail(error.BadRequest, "scopes must be strings");
                try want.append(c.a, x.string);
            }
        } else if (try json.str(v, "scope")) |s| try want.append(c.a, s);
        if (want.items.len > store.Scope.max) return c.fail(error.BadRequest, "too many scopes");
        return want.items;
    }

    /// The search set: each requested scope must be readable by this seat (else 403 + a denial row).
    fn readSet(c: *Ctx, want: []const []const u8) ![]const []const u8 {
        return access.narrowTo(c.who, want) orelse return c.deny("scope not granted to this seat");
    }

    /// The one scope a write lands in: the requested one or the member's own scope; it must be writable.
    fn writeScope(c: *Ctx, v: Value) ![]const u8 {
        const s = (try json.str(v, "scope")) orelse try c.who.defaultWriteScope(c.a);
        if (!c.who.mayWrite(s)) return c.deny("scope not writable by this seat");
        return s;
    }

    fn needWrites(c: *Ctx) !void {
        if (!c.seat.writes) {
            c.au.denied = "read-only seat";
            return c.fail(error.Forbidden, "this seat is read-only");
        }
    }

    /// Untrusted seats may not write family / medical / money text (SPEC §1.8, the handoff-gateway screen).
    fn screenText(c: *Ctx, field: []const u8, text: []const u8) !void {
        if (c.seat.trusted) return;
        if (screen.find(text) != null) {
            c.au.denied = "privacy screen";
            return c.fail(error.Forbidden, try std.fmt.allocPrint(c.a, "refused by the privacy screen (untrusted seat): {s} — a seat that writes family, medical or money text needs a token minted with `zigmem token add ... --trusted`", .{field}));
        }
    }

    fn sessionId(c: *Ctx, key: []const u8) ![]const u8 {
        if (key.len == 0 or key.len > 200) return c.fail(error.BadRequest, "session_key must be 1-200 bytes");
        for (key) |ch| if (ch < 0x20 or ch == 0x7f) return c.fail(error.BadRequest, "session_key has control characters");
        return std.fmt.allocPrint(c.a, "{s}/{s}", .{ c.seat.name, key });
    }

    /// One `xread` audit entry per cross scope this read searched (scope + query hash), in this call's audit.log line.
    fn auditReads(c: *Ctx, scopes: []const []const u8, query: []const u8) !void {
        for (scopes) |s| if (access.policy.isCross(c.who.actor, s)) try c.au.xread.append(c.a, s);
        if (c.au.xread.items.len > 0 and c.au.qh == null) c.au.qh = access.qhash(query);
    }
};

pub fn handler(h: *Hub) http.Handler {
    return .{ .ctx = h, .f = handle };
}

fn monoNs(h: *Hub) i96 {
    return std.Io.Timestamp.now(h.io, .awake).nanoseconds;
}

fn handle(ctx: *anyopaque, a: std.mem.Allocator, req: http.Request) http.Response {
    const h: *Hub = @ptrCast(@alignCast(ctx));
    const t0 = monoNs(h);
    var au: Audit = .{ .route = req.path };
    const resp = dispatch(h, a, req, &au) catch |e| http.Response{ .status = 500, .body = json.errBody(a, @errorName(e)) catch "{}" };
    h.audit(a, au, resp.status, @as(f64, @floatFromInt(monoNs(h) - t0)) / 1e6, req.body.len, resp.body.len);
    return resp;
}

fn errResp(a: std.mem.Allocator, status: u16, msg: []const u8) http.Response {
    return .{ .status = status, .body = json.errBody(a, msg) catch "{}", .extra = if (status == 401) "WWW-Authenticate: Bearer realm=\"zigmem\"\r\n" else "" };
}

fn identityClaims(req: http.Request) bool {
    for (req.headers) |hd| {
        if (std.ascii.eqlIgnoreCase(hd.name, "x-zigmem-seat")) return true;
        // Any vendor-prefixed identity claim (x-<vendor>-user-id / -service-id / -agent-id / -team-id / -seat).
        if (hd.name.len > 2 and std.ascii.eqlIgnoreCase(hd.name[0..2], "x-")) {
            for ([_][]const u8{ "-user-id", "-service-id", "-agent-id", "-team-id", "-seat" }) |suf| {
                if (hd.name.len > suf.len and std.ascii.eqlIgnoreCase(hd.name[hd.name.len - suf.len ..], suf)) return true;
            }
        }
    }
    return false;
}

fn bodyClaims(v: Value) bool {
    if (v != .object) return false;
    for ([_][]const u8{ "user_id", "agent_id", "team_id", "seat", "seat_id", "service_id" }) |k| if (v.object.get(k) != null) return true;
    return false;
}

pub fn bearer(req: http.Request) ?[]const u8 {
    const v = req.header("authorization") orelse return null;
    return bearerValue(v);
}

pub fn bearerValue(v: []const u8) ?[]const u8 {
    if (v.len < 7 or !std.ascii.eqlIgnoreCase(v[0..7], "bearer ")) return null;
    const t = std.mem.trim(u8, v[7..], " \t");
    return if (t.len == 0 or t.len > 256) null else t;
}

/// Token → seat → household identity. Shared by REST, MCP, the panel and the proxy.
pub const Ident = union(enum) { ok: Who, unauthorized: []const u8, forbidden: []const u8 };

pub fn identify(h: *Hub, a: std.mem.Allocator, tok: []const u8) !Ident {
    const table = h.tokens.current() orelse return .{ .unauthorized = "token table unavailable (fail closed)" };
    return identifySeat(h, a, switch (table.verify(tok)) {
        .ok => |s| s,
        .unknown => return .{ .unauthorized = "unknown token" },
        .revoked => return .{ .unauthorized = "revoked token" },
    });
}

/// An already verified seat (the panel re-checks its session's seat against the live token table first).
pub fn identifySeat(h: *Hub, a: std.mem.Allocator, seat: *const auth.Seat) !Ident {
    const rd = h.readers.acquire();
    defer h.readers.release(rd);
    return switch (try access.resolve(a, rd, seat)) {
        .ok => |w| .{ .ok = w },
        .denied => |why| blk: {
            h.writer.call(access.denyOp, .{ seat.name, why }) catch {};
            break :blk .{ .forbidden = why };
        },
    };
}

fn dispatch(h: *Hub, a: std.mem.Allocator, req: http.Request, au: *Audit) !http.Response {
    if (std.mem.eql(u8, req.path, "/health")) {
        if (!std.mem.eql(u8, req.method, "GET")) return errResp(a, 405, "GET only");
        const hc = try h.healthCheck(a, std.mem.eql(u8, req.query, "deep=1"));
        return .{ .status = if (hc.ok) 200 else 503, .body = hc.body };
    }
    au.ignored_identity = identityClaims(req);
    const tok = bearer(req) orelse {
        au.denied = "no token";
        return errResp(a, 401, "missing bearer token");
    };
    const who = switch (try identify(h, a, tok)) {
        .ok => |w| w,
        .unauthorized => |why| {
            au.denied = why;
            return errResp(a, 401, if (std.mem.startsWith(u8, why, "token table")) why else "invalid token");
        },
        .forbidden => |why| {
            au.denied = why;
            return errResp(a, 403, why);
        },
    };
    au.seat = who.seat.name;
    var c: Ctx = .{ .h = h, .a = a, .seat = who.seat, .who = who, .au = au };
    if (std.mem.eql(u8, req.path, "/mcp")) {
        if (!std.mem.eql(u8, req.method, "POST")) return .{ .status = 405, .body = try json.errBody(a, "POST only (no SSE stream)"), .extra = "Allow: POST\r\n" };
        return mcpRoute(&c, req);
    }
    if (!std.mem.eql(u8, req.method, "POST")) return errResp(a, 405, "POST only");
    const v = json.parse(a, req.body) catch return errResp(a, 400, "body must be a JSON object");
    if (v != .object) return errResp(a, 400, "body must be a JSON object");
    if (bodyClaims(v)) au.ignored_identity = true;
    const r = route(&c, req.path, v) catch |e| return switch (e) {
        error.BadRequest, error.BadType => errResp(a, 400, if (e == error.BadType) "a field has the wrong type" else c.msg),
        error.Forbidden => errResp(a, 403, c.msg),
        error.NotFound => errResp(a, 404, if (c.msg.len > 0) c.msg else "not found"),
        error.Conflict => errResp(a, 409, c.msg),
        error.TooMany => .{ .status = 429, .body = json.errBody(a, c.msg) catch "{}", .extra = "Retry-After: 5\r\n" },
        error.NotImplemented => errResp(a, 501, c.msg),
        else => errResp(a, 500, @errorName(e)),
    };
    return .{ .status = 200, .body = r };
}

fn is(p: []const u8, comptime names: anytype) bool {
    inline for (names) |n| if (std.mem.eql(u8, p, n)) return true;
    return false;
}

fn route(c: *Ctx, p: []const u8, v: Value) ![]u8 {
    if (is(p, .{ "/search/memories", "/v1/search/memories" })) return searchRoute(c, v, .atoms, .v1);
    if (is(p, .{"/v3/atomic/search"})) return searchRoute(c, v, .atoms, .v3);
    if (is(p, .{ "/search/conversations", "/v1/search/conversations" })) return searchRoute(c, v, .turns, .v1);
    if (is(p, .{"/v3/conversation/search"})) return searchRoute(c, v, .turns, .v3);
    if (is(p, .{ "/recall", "/v1/recall" })) return recallRoute(c, v);
    if (is(p, .{ "/capture", "/v1/capture" })) return captureRoute(c, v);
    if (is(p, .{"/v3/conversation/add"})) return conversationAdd(c, v);
    if (is(p, .{ "/session/end", "/v1/session/end" })) return sessionEnd(c, v);
    if (is(p, .{"/v1/session/block"})) return blockRoute(c, v);
    if (is(p, .{"/v1/atoms/get"})) return getRoute(c, v);
    if (is(p, .{"/v1/atoms/list"})) return listRoute(c, v);
    if (is(p, .{"/v1/atoms/add"})) return addRoute(c, v);
    if (is(p, .{"/v1/atoms/supersede"})) return supersedeRoute(c, v);
    if (is(p, .{"/v1/atoms/demote"})) return demoteRoute(c, v);
    if (is(p, .{ "/admin/retire", "/v3/atomic/delete" })) return retireRoute(c, v);
    if (std.mem.startsWith(u8, p, "/v1/household/")) return householdRoute(c, p["/v1/household/".len..], v);
    if (is(p, .{ "/seed", "/v1/seed" })) return c.fail(error.NotImplemented, "seed import is phase 8 (zigmem import)");
    return c.fail(error.NotFound, "no such route");
}

// ---- shared cores (REST and MCP) ----

const SearchIn = struct {
    text: []const u8,
    want: []const []const u8 = &.{},
    limit: u32 = 5,
    kind: retriever.Kind = .atoms,
    type: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    session: ?[]const u8 = null,
    since_ms: ?i64 = null,
    until_ms: ?i64 = null,
};

fn search(c: *Ctx, q: SearchIn) ![]retriever.Hit {
    const scopes = try c.readSet(q.want);
    try c.auditReads(scopes, q.text);
    const t0 = monoNs(c.h);
    const rd = c.h.readers.acquire();
    defer c.h.readers.release(rd);
    defer c.au.search_ms += @as(f64, @floatFromInt(monoNs(c.h) - t0)) / 1e6;
    const slot = c.h.readers.slotOf(rd);
    const narrow = access.narrowPerson(q.want);
    return switch (q.kind) {
        .atoms => retrieval.atoms(&c.h.eng, c.a, rd, slot, &c.who, .{ .text = q.text, .scopes = scopes, .narrow = narrow, .limit = q.limit, .type = q.type, .subject = q.subject }),
        .turns => retrieval.turns(&c.h.eng, c.a, rd, slot, &c.who, .{ .text = q.text, .scopes = scopes, .narrow = narrow, .limit = q.limit, .session = q.session, .since_ms = q.since_ms, .until_ms = q.until_ms }),
    };
}

fn recallCore(c: *Ctx, text: []const u8, want: []const []const u8, keep: usize) !retrieval.Recalled {
    const scopes = try c.readSet(want);
    try c.auditReads(scopes, text);
    const t0 = monoNs(c.h);
    const rd = c.h.readers.acquire();
    defer c.h.readers.release(rd);
    defer c.au.search_ms += @as(f64, @floatFromInt(monoNs(c.h) - t0)) / 1e6;
    return retrieval.recallBlock(&c.h.eng, c.a, rd, c.h.readers.slotOf(rd), &c.who, text, scopes, access.narrowPerson(want), keep);
}

const TurnIn = struct { role: []const u8, text: []const u8 };
const Captured = struct { ids: []?i64, queued: bool, session: []const u8 };

fn captureOp(st: *store.Store, turns: []const store.l0.Turn, enqueue: bool, ids: []?i64, now: i64) !void {
    for (turns, 0..) |t, i| {
        ids[i] = try store.l0.append(st, t);
        if (enqueue and std.mem.eql(u8, t.role, "user")) if (ids[i]) |id| {
            var kb: [24]u8 = undefined;
            _ = try store.jobs.enqueue(st, "extract", try std.fmt.bufPrint(&kb, "{d}", .{id}), now);
        };
    }
}

fn capture(c: *Ctx, scope: []const u8, session_key: []const u8, ts: ?i64, turns: []const TurnIn) !Captured {
    try c.needWrites();
    if (turns.len == 0) return c.fail(error.BadRequest, "nothing to capture");
    for (turns) |t| {
        if (t.text.len > 64 << 10) return c.fail(error.BadRequest, "a turn is longer than 64 KiB");
        try c.screenText(t.role, t.text);
    }
    const sid = try c.sessionId(session_key);
    const now = c.h.nowMs();
    const enqueue = c.h.worker != null;
    if (enqueue and try c.h.queuedJobs() >= c.h.cfg.queue_cap) {
        c.au.denied = "queue full";
        return c.fail(error.TooMany, "extraction queue is full; retry later (nothing was written)");
    }
    const l0t = try c.a.alloc(store.l0.Turn, turns.len);
    for (turns, l0t) |t, *o| o.* = .{ .session_id = sid, .seat = c.seat.name, .scope = scope, .role = t.role, .text = t.text, .ts_ms = ts orelse now };
    const ids = try c.a.alloc(?i64, turns.len);
    try c.h.writer.call(captureOp, .{ l0t, enqueue, ids, now });
    return .{ .ids = ids, .queued = enqueue, .session = sid };
}

/// An atom by id, only when this seat may read its scope AND the row gates pass with the row's own subject as the
/// target. Its text comes back as served (firewall, stamp, escape). Null = invisible (404, never "forbidden").
fn getAtom(c: *Ctx, want: []const []const u8, id: i64) !?store.atoms.Atom {
    const scopes = try c.readSet(want);
    if (scopes.len == 0) return null;
    const x = blk: {
        const rd = c.h.readers.acquire();
        defer c.h.readers.release(rd);
        const slot = c.h.readers.slotOf(rd);
        var x = (try store.atoms.get(rd, c.a, .{ .names = scopes }, id)) orelse return null;
        // judged as a live row whatever its status (get shows history; search never serves an inactive row)
        const row: hh.house.Row = .{ .id = x.id, .scope = x.scope, .subject = x.subject, .type = x.type, .text = x.text };
        if (!try retrieval.gateOne(&c.h.eng, c.a, rd, slot, &c.who, row, "", x.subject)) return null;
        x.text = @constCast((try retrieval.serveText(&c.h.eng, c.a, slot, x.text, true)) orelse return null);
        break :blk x;
    };
    try c.auditReads(&.{x.scope}, "");
    return x;
}

fn frozenBlock(c: *Ctx, session_key: []const u8) !block.Frozen {
    const sid = try c.sessionId(session_key);
    const text = blk: {
        const rd = c.h.readers.acquire();
        defer c.h.readers.release(rd);
        if (try block.lookup(c.a, rd, sid)) |f| return f;
        break :blk try block.buildFor(c.a, rd, &c.who, &c.h.eng, c.h.readers.slotOf(rd));
    };
    var out: block.Frozen = undefined;
    try c.h.writer.call(block.freezeOp, .{ c.a, sid, text, &out });
    return out;
}

// ---- REST routes ----

const Flavor = enum { v1, v3 };

fn limitOf(v: Value, default: i64, max: i64) !u32 {
    const n = (try json.int(v, "limit")) orelse default;
    return @intCast(std.math.clamp(n, 1, max));
}

fn searchRoute(c: *Ctx, v: Value, kind: retriever.Kind, fl: Flavor) ![]u8 {
    const q = (try json.str(v, "query")) orelse return c.fail(error.BadRequest, "query is required");
    if (q.len == 0 or q.len > 2000) return c.fail(error.BadRequest, "query must be 1-2000 bytes");
    const want = try c.wantScopes(v);
    const sess = if (try json.str(v, "session_key")) |k| try c.sessionId(k) else null;
    const hits = try search(c, .{ .want = want, .text = q, .limit = try limitOf(v, 5, 20), .kind = kind, .type = try json.str(v, "type"), .subject = try json.str(v, "subject"), .session = sess, .since_ms = try json.int(v, "since_ms"), .until_ms = try json.int(v, "until_ms") });
    var b: std.ArrayList(u8) = .empty;
    var o = try json.Obj.begin(c.a, &b);
    if (fl == .v3) {
        try o.n("code", 0);
        try o.s("message", "ok");
        var d: std.ArrayList(u8) = .empty;
        var od = try json.Obj.begin(c.a, &d);
        try od.raw("items", try hitsJson(c.a, hits));
        try od.n("total", @intCast(hits.len));
        try od.end();
        try o.raw("data", d.items);
    } else {
        try o.s("results", try recallContext(c.a, hits));
        try o.n("total", @intCast(hits.len));
        try o.s("strategy", retrieval.name);
        try o.raw("hits", try hitsJson(c.a, hits));
    }
    try o.end();
    return b.items;
}

fn idsJson(a: std.mem.Allocator, ids: []const i64) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.append(a, '[');
    for (ids, 0..) |id, i| try b.print(a, "{s}{d}", .{ if (i == 0) "" else ",", id });
    try b.append(a, ']');
    return b.items;
}

fn recallRoute(c: *Ctx, v: Value) ![]u8 {
    const q = (try json.str(v, "query")) orelse return c.fail(error.BadRequest, "query is required");
    if (q.len == 0 or q.len > 2000) return c.fail(error.BadRequest, "query must be 1-2000 bytes");
    const r = try recallCore(c, q, try c.wantScopes(v), try limitOf(v, 4, 20));
    var b: std.ArrayList(u8) = .empty;
    var o = try json.Obj.begin(c.a, &b);
    try o.s("context", r.block);
    try o.s("strategy", retrieval.name);
    try o.n("memory_count", @intCast(r.rows));
    try o.raw("memory_ids", try idsJson(c.a, r.ids));
    try o.s("rerank", r.rerank);
    try o.n("code", 0);
    try o.s("message", "ok");
    try o.b_("retryable", false);
    try o.end();
    return b.items;
}

fn capturedJson(c: *Ctx, r: Captured, v3: bool) ![]u8 {
    var n: i64 = 0;
    var ids: std.ArrayList(u8) = .empty;
    try ids.append(c.a, '[');
    for (r.ids, 0..) |x, i| {
        if (i > 0) try ids.append(c.a, ',');
        if (x) |id| {
            n += 1;
            try ids.print(c.a, "{d}", .{id});
        } else try ids.appendSlice(c.a, "null");
    }
    try ids.append(c.a, ']');
    var b: std.ArrayList(u8) = .empty;
    var o = try json.Obj.begin(c.a, &b);
    if (v3) {
        try o.n("code", 0);
        try o.s("message", "ok");
    }
    try o.n("l0_recorded", n);
    try o.b_("scheduler_notified", r.queued and n > 0);
    try o.raw("ids", ids.items);
    try o.s("session_id", r.session);
    try o.end();
    return b.items;
}

fn captureRoute(c: *Ctx, v: Value) ![]u8 {
    const user = (try json.str(v, "user_content")) orelse return c.fail(error.BadRequest, "user_content is required");
    const asst = (try json.str(v, "assistant_content")) orelse "";
    const key = (try json.str(v, "session_key")) orelse return c.fail(error.BadRequest, "session_key is required");
    try c.needWrites();
    const scope = try c.writeScope(v);
    var turns: [2]TurnIn = .{ .{ .role = "user", .text = user }, .{ .role = "assistant", .text = asst } };
    const r = try capture(c, scope, key, try json.int(v, "ts_ms"), if (asst.len > 0) turns[0..2] else turns[0..1]);
    return capturedJson(c, r, false);
}

fn conversationAdd(c: *Ctx, v: Value) ![]u8 {
    const key = (try json.str(v, "session_id")) orelse (try json.str(v, "session_key")) orelse return c.fail(error.BadRequest, "session_id is required");
    const msgs = (try json.array(v, "messages")) orelse return c.fail(error.BadRequest, "messages is required");
    if (msgs.len == 0 or msgs.len > 64) return c.fail(error.BadRequest, "messages must hold 1-64 items");
    var turns: std.ArrayList(TurnIn) = .empty;
    for (msgs) |m| {
        const role = (try json.str(m, "role")) orelse return c.fail(error.BadRequest, "message.role is required");
        const text = (try json.str(m, "content")) orelse return c.fail(error.BadRequest, "message.content must be a string");
        if (!std.mem.eql(u8, role, "user") and !std.mem.eql(u8, role, "assistant")) return c.fail(error.BadRequest, "message.role must be user or assistant");
        try turns.append(c.a, .{ .role = role, .text = text });
    }
    try c.needWrites();
    const r = try capture(c, try c.writeScope(v), key, try json.int(v, "ts_ms"), turns.items);
    return capturedJson(c, r, true);
}

fn endOp(st: *store.Store, sid: []const u8) !void {
    try st.db.run("UPDATE sessions SET state = 'ended' WHERE id = ?1", .{sid});
}

fn sessionEnd(c: *Ctx, v: Value) ![]u8 {
    try c.needWrites();
    const key = (try json.str(v, "session_key")) orelse return c.fail(error.BadRequest, "session_key is required");
    try c.h.writer.call(endOp, .{try c.sessionId(key)});
    if (c.h.worker) |*w| w.requestFold(c.h.nowMs()); // C10: a session end is a fold trigger
    return c.a.dupe(u8, "{\"flushed\":true}");
}

fn blockRoute(c: *Ctx, v: Value) ![]u8 {
    const key = (try json.str(v, "session_key")) orelse return c.fail(error.BadRequest, "session_key is required");
    const f = try frozenBlock(c, key);
    var b: std.ArrayList(u8) = .empty;
    var o = try json.Obj.begin(c.a, &b);
    try o.s("session_key", key);
    try o.s("text", f.text);
    try o.s("sha256", try std.fmt.allocPrint(c.a, "{x}", .{&f.sha256}));
    try o.n("built_ms", f.built_ms);
    try o.b_("fresh", f.fresh);
    try o.end();
    return b.items;
}

fn getRoute(c: *Ctx, v: Value) ![]u8 {
    const id = (try json.int(v, "id")) orelse return c.fail(error.BadRequest, "id is required");
    const x = (try getAtom(c, try c.wantScopes(v), id)) orelse return c.fail(error.NotFound, "no such atom in this seat's scopes");
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(c.a, "{\"atom\":");
    try atomJson(c.a, &b, x);
    try b.append(c.a, '}');
    return b.items;
}

fn listRoute(c: *Ctx, v: Value) ![]u8 {
    const scopes = try c.readSet(try c.wantScopes(v));
    const status = (try json.str(v, "status")) orelse "active";
    if (!is(status, .{ "active", "superseded", "pending_review", "retired", "any" })) return c.fail(error.BadRequest, "bad status");
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(c.a, "{\"atoms\":[");
    var n: usize = 0;
    var withheld: usize = 0;
    if (scopes.len > 0) {
        var sql: std.ArrayList(u8) = .empty;
        try sql.appendSlice(c.a, "SELECT id, lineage, subject, scope, type, priority, text, valid_from, valid_to, recorded_ms, superseded_by, status " ++
            "FROM atoms WHERE (?1 IS NULL OR id < ?1) AND (?2 = 'any' OR status = ?2) AND (?3 IS NULL OR subject = ?3) AND ");
        const scope: store.Scope = .{ .names = scopes };
        try scope.sqlIn(c.a, &sql, "scope", 5);
        try sql.appendSlice(c.a, " ORDER BY id DESC LIMIT ?4");
        const rd = c.h.readers.acquire();
        defer c.h.readers.release(rd);
        const slot = c.h.readers.slotOf(rd);
        var s = try rd.db.prepare(sql.items);
        defer s.deinit();
        try s.bindAll(.{ try json.int(v, "before_id"), status, try json.str(v, "subject"), try limitOf(v, 50, 200) });
        try scope.bind(s, 5);
        while (try s.step()) {
            var x: store.atoms.Atom = .{
                .id = s.int(0),
                .lineage = try c.a.dupe(u8, s.text(1)),
                .subject = try c.a.dupe(u8, s.text(2)),
                .scope = try c.a.dupe(u8, s.text(3)),
                .type = try c.a.dupe(u8, s.text(4)),
                .priority = s.int(5),
                .text = try c.a.dupe(u8, s.text(6)),
                .valid_from = if (s.isNull(7)) null else try c.a.dupe(u8, s.text(7)),
                .valid_to = if (s.isNull(8)) null else try c.a.dupe(u8, s.text(8)),
                .recorded_ms = s.int(9),
                .superseded_by = if (s.isNull(10)) null else s.int(10),
                .status = std.meta.stringToEnum(store.atoms.Status, s.text(11)) orelse .pending_review,
                .run_id = null,
            };
            // listing = asking about each row's own subject; the household + medical gates decide per row
            const row: hh.house.Row = .{ .id = x.id, .scope = x.scope, .subject = x.subject, .type = x.type, .text = x.text };
            if (!try retrieval.gateOne(&c.h.eng, c.a, rd, slot, &c.who, row, "", x.subject)) {
                withheld += 1;
                continue;
            }
            x.text = @constCast((try retrieval.serveText(&c.h.eng, c.a, slot, x.text, true)) orelse {
                withheld += 1;
                continue;
            });
            if (n > 0) try b.append(c.a, ',');
            try atomJson(c.a, &b, x);
            n += 1;
        }
    }
    try c.auditReads(scopes, "");
    try b.print(c.a, "],\"count\":{d},\"withheld\":{d}}}", .{ n, withheld });
    return b.items;
}

/// Writer-thread op: a new atom through the household write rule (House.write: scope check, pending_review for a
/// medical row outside its owner's scope or an unknown subject, the medical tag).
fn addOp(st: *store.Store, a: std.mem.Allocator, seat: []const u8, n: hh.house.NewAtom, out: *HhOut) !void {
    const house: hh.House = .{ .st = st };
    if (house.write(a, seat, n)) |id| out.id = id else |e| out.err = e;
}

fn addRoute(c: *Ctx, v: Value) ![]u8 {
    try c.needWrites();
    const text = (try json.str(v, "text")) orelse return c.fail(error.BadRequest, "text is required");
    if (text.len == 0 or text.len > 8000) return c.fail(error.BadRequest, "text must be 1-8000 bytes");
    const scope = try c.writeScope(v);
    const subject = (try json.str(v, "subject")) orelse (c.who.actor.member orelse "household");
    if (subject.len == 0 or subject.len > 64) return c.fail(error.BadRequest, "subject must be 1-64 bytes");
    const typ = (try json.str(v, "type")) orelse "fact";
    if (!store.atoms.validType(typ)) return c.fail(error.BadRequest, "bad type");
    try c.screenText("text", text);
    var out: HhOut = .{};
    try c.h.writer.call(addOp, .{ c.a, c.seat.name, hh.house.NewAtom{ .scope = scope, .subject = subject, .type = typ, .text = text, .medical = try json.boolean(v, "medical") }, &out });
    if (out.err) |e| {
        c.au.denied = @errorName(e);
        return switch (e) {
            error.Forbidden, error.SeatRevoked, error.MemberRevoked, error.UnknownSeat, error.MemberMissing => c.fail(error.Forbidden, @errorName(e)),
            error.ScopeRequired, error.BadAtomType, error.BadPriority => c.fail(error.BadRequest, @errorName(e)),
            else => e,
        };
    }
    const id = out.id.?;
    const st = blk: {
        const rd = c.h.readers.acquire();
        defer c.h.readers.release(rd);
        var s = try rd.db.prepare("SELECT status FROM atoms WHERE id = ?1");
        defer s.deinit();
        try s.bind(1, id);
        break :blk if (try s.step()) try c.a.dupe(u8, s.text(0)) else "?";
    };
    var b: std.ArrayList(u8) = .empty;
    var o = try json.Obj.begin(c.a, &b);
    try o.n("id", id);
    try o.s("status", st);
    try o.s("scope", scope);
    try o.end();
    return b.items;
}

fn supersedeRoute(c: *Ctx, v: Value) ![]u8 {
    try c.needWrites();
    const id = (try json.int(v, "id")) orelse return c.fail(error.BadRequest, "id is required");
    const text = (try json.str(v, "text")) orelse return c.fail(error.BadRequest, "text is required");
    if (text.len == 0 or text.len > 8000) return c.fail(error.BadRequest, "text must be 1-8000 bytes");
    try c.screenText("text", text);
    const old = (try getAtom(c, &.{}, id)) orelse return c.fail(error.NotFound, "no such atom in this seat's scopes");
    if (!c.who.mayWrite(old.scope)) return c.deny("atom's scope not writable by this seat");
    const pr = (try json.int(v, "priority")) orelse old.priority;
    const n: store.atoms.New = .{ .subject = old.subject, .scope = old.scope, .type = (try json.str(v, "type")) orelse old.type, .text = text, .priority = pr, .valid_from = try json.str(v, "valid_from"), .extractor = "api", .seat = c.seat.name };
    const new_id = c.h.writer.call(access.supersedeOp, .{ c.a, id, n, try json.str(v, "valid_to"), try json.boolean(v, "medical") }) catch |e| return switch (e) {
        error.NotActive => c.fail(error.Conflict, "atom is not active"),
        error.BadAtomType, error.BadPriority => c.fail(error.BadRequest, @errorName(e)),
        else => e,
    };
    return std.fmt.allocPrint(c.a, "{{\"id\":{d},\"superseded\":{d}}}", .{ new_id, id });
}

fn statusOp(st: *store.Store, id: i64, to: store.atoms.Status, seat: []const u8, reason: ?[]const u8) !void {
    try store.atoms.setStatus(st, id, to, seat);
    if (reason) |r| try st.audit(seat, "reason", "atoms", id, r[0..@min(r.len, 300)]);
}

fn demoteRoute(c: *Ctx, v: Value) ![]u8 {
    try c.needWrites();
    const id = (try json.int(v, "id")) orelse return c.fail(error.BadRequest, "id is required");
    const to_s = (try json.str(v, "to")) orelse "retired";
    const to: store.atoms.Status = if (std.mem.eql(u8, to_s, "retired")) .retired else if (std.mem.eql(u8, to_s, "pending_review")) .pending_review else return c.fail(error.BadRequest, "to must be retired or pending_review");
    const reason = try json.str(v, "reason");
    if (reason) |r| try c.screenText("reason", r);
    const x = (try getAtom(c, &.{}, id)) orelse return c.fail(error.NotFound, "no such atom in this seat's scopes");
    if (!c.who.mayWrite(x.scope)) return c.deny("atom's scope not writable by this seat");
    c.h.writer.call(statusOp, .{ id, to, c.seat.name, reason }) catch |e| return switch (e) {
        error.BadTransition => c.fail(error.Conflict, "that status change is not allowed"),
        else => e,
    };
    return std.fmt.allocPrint(c.a, "{{\"id\":{d},\"status\":\"{s}\"}}", .{ id, @tagName(to) });
}

/// Admin token AND a household principal. "delete" in the v3 shape is a retire (status flip + audit); nothing is
/// removed; only atoms in scopes this seat may read.
fn retireRoute(c: *Ctx, v: Value) ![]u8 {
    if (!c.who.admin()) {
        if (c.seat.admin) return c.deny("admin needs a household principal");
        c.au.denied = "admin only";
        return c.fail(error.Forbidden, "admin token required");
    }
    var ids: std.ArrayList(i64) = .empty;
    if (try json.int(v, "id")) |id| try ids.append(c.a, id);
    if (try json.array(v, "ids")) |arr| for (arr) |x| {
        if (x != .integer) return c.fail(error.BadRequest, "ids must be integers");
        try ids.append(c.a, x.integer);
    };
    if (ids.items.len == 0 or ids.items.len > 100) return c.fail(error.BadRequest, "1-100 ids");
    var done: i64 = 0;
    for (ids.items) |id| {
        const visible = blk: {
            if (c.who.read.len == 0) break :blk false;
            const rd = c.h.readers.acquire();
            defer c.h.readers.release(rd);
            break :blk (try store.atoms.get(rd, c.a, c.who.scope(), id)) != null;
        };
        if (!visible) continue;
        c.h.writer.call(statusOp, .{ id, store.atoms.Status.retired, c.seat.name, @as(?[]const u8, "admin retire") }) catch continue;
        done += 1;
    }
    return std.fmt.allocPrint(c.a, "{{\"code\":0,\"message\":\"ok\",\"retired\":{d},\"deleted\":0}}", .{done});
}

// ---- household: whoami, promotion, members, seats (phase 5 through the API) ----

/// The House call's own error comes back as a value, so its denial audit rows commit with the batch.
const HhOut = struct { id: ?i64 = null, err: ?anyerror = null };

fn hhCall(house: hh.House, a: std.mem.Allocator, seat: []const u8, what: []const u8, v: Value) anyerror!?i64 {
    if (std.mem.eql(u8, what, "promote/request")) return try house.promoteRequest(a, seat, (try json.int(v, "id")) orelse 0);
    if (std.mem.eql(u8, what, "promote/decide")) return try house.promoteDecide(a, seat, (try json.int(v, "request")) orelse 0, (try json.boolean(v, "approve")) orelse false);
    if (std.mem.eql(u8, what, "member/add")) {
        var al: std.ArrayList([]const u8) = .empty;
        if (try json.array(v, "aliases")) |arr| for (arr) |x| if (x == .string) try al.append(a, x.string);
        const role = std.meta.stringToEnum(hh.policy.Role, (try json.str(v, "role")) orelse "") orelse hh.policy.Role.guest;
        try house.addMember(a, seat, .{ .id = (try json.str(v, "id")) orelse "", .display = (try json.str(v, "display")) orelse "", .aliases = al.items, .role = role, .relation = (try json.str(v, "relation")) orelse "" });
        return null;
    }
    if (std.mem.eql(u8, what, "member/revoke")) {
        try house.revokeMember(a, seat, (try json.str(v, "id")) orelse "");
        return null;
    }
    if (std.mem.eql(u8, what, "seat/bind")) {
        try house.bindSeat(a, seat, (try json.str(v, "name")) orelse "", try json.str(v, "member"));
        return null;
    }
    if (std.mem.eql(u8, what, "seat/revoke")) {
        try house.revokeSeat(a, seat, (try json.str(v, "name")) orelse "");
        return null;
    }
    return error.NoSuchRoute;
}

fn hhOp(st: *store.Store, a: std.mem.Allocator, seat: []const u8, what: []const u8, v: Value, out: *HhOut) !void {
    const house: hh.House = .{ .st = st };
    if (hhCall(house, a, seat, what, v)) |id| out.id = id else |e| out.err = e;
}

fn householdRoute(c: *Ctx, what: []const u8, v: Value) ![]u8 {
    if (std.mem.eql(u8, what, "whoami")) {
        var b: std.ArrayList(u8) = .empty;
        var o = try json.Obj.begin(c.a, &b);
        try o.s("seat", c.seat.name);
        try o.s("member", c.who.actor.member);
        try o.s("role", if (c.who.actor.role) |r| @tagName(r) else "shared");
        var rs: std.ArrayList(u8) = .empty;
        try rs.append(c.a, '[');
        for (c.who.read, 0..) |s, i| {
            if (i > 0) try rs.append(c.a, ',');
            try json.writeString(c.a, &rs, s);
        }
        try rs.append(c.a, ']');
        try o.raw("read", rs.items);
        try o.end();
        return b.items;
    }
    if (!is(what, .{ "promote/request", "promote/decide", "member/add", "member/revoke", "seat/bind", "seat/revoke" })) return c.fail(error.NotFound, "no such household route");
    try c.needWrites();
    // admin verbs need the token's admin flag too (a principal's ordinary token cannot change the household)
    if (is(what, .{ "member/add", "member/revoke", "seat/bind" }) and !c.seat.admin) return c.deny("admin token required");
    if (std.mem.eql(u8, what, "promote/request")) {
        // the atom must be visible to this token (its narrowing and the row gates apply too)
        const id = (try json.int(v, "id")) orelse return c.fail(error.BadRequest, "id is required");
        _ = (try getAtom(c, &.{}, id)) orelse return c.fail(error.NotFound, "no such atom in this seat's scopes");
    }
    var out: HhOut = .{};
    try c.h.writer.call(hhOp, .{ c.a, c.seat.name, what, v, &out });
    if (out.err) |e| {
        c.au.denied = @errorName(e);
        return switch (e) {
            error.Forbidden, error.MedicalNotShareable, error.PrincipalNotRevocable, error.SeatRevoked, error.MemberRevoked, error.UnknownSeat, error.MemberMissing => c.fail(error.Forbidden, @errorName(e)),
            error.NoSuchAtom => c.fail(error.NotFound, @errorName(e)),
            error.BadId, error.NoSuchRoute, error.BadType => c.fail(error.BadRequest, @errorName(e)),
            error.Exists, error.AlreadyShared, error.NotActive, error.NotPending, error.BootstrapDone => c.fail(error.Conflict, @errorName(e)),
            else => e,
        };
    }
    return if (out.id) |id| std.fmt.allocPrint(c.a, "{{\"ok\":true,\"id\":{d}}}", .{id}) else c.a.dupe(u8, "{\"ok\":true}");
}

// ---- MCP: the same cores behind the five tools ----

fn mcpRoute(c: *Ctx, req: http.Request) !http.Response {
    const be: mcp.Backend = .{ .ptr = c, .call = mcpCall };
    const out = try mcp.handle(c.a, req.body, be);
    c.au.method = out.method;
    c.au.tool = out.tool;
    return .{ .status = out.status, .body = out.body };
}

fn toolErr(c: *Ctx, e: anyerror) mcp.Result {
    return .{ .is_error = true, .text = if (c.msg.len > 0) c.msg else @errorName(e) };
}

fn mcpCall(ptr: *anyopaque, _: std.mem.Allocator, tool: mcp.Tool, args: mcp.Args) mcp.Result {
    const c: *Ctx = @ptrCast(@alignCast(ptr));
    return mcpTool(c, tool, args) catch |e| toolErr(c, e);
}

fn mcpTool(c: *Ctx, tool: mcp.Tool, args: mcp.Args) !mcp.Result {
    const lim: u32 = @intCast(args.limit orelse 5);
    switch (tool) {
        .memory_search => {
            const hits = try search(c, .{ .text = args.query.?, .limit = lim, .type = args.type, .subject = args.subject });
            var b: std.ArrayList(u8) = .empty;
            try b.appendSlice(c.a, "{\"hits\":");
            try b.appendSlice(c.a, try hitsJson(c.a, hits));
            if (args.include_turns orelse false) {
                try b.appendSlice(c.a, ",\"turns\":");
                try b.appendSlice(c.a, try hitsJson(c.a, try search(c, .{ .text = args.query.?, .limit = lim, .kind = .turns })));
            }
            try b.append(c.a, '}');
            return .{ .text = b.items };
        },
        .memory_recall => {
            const r = try recallCore(c, args.query.?, &.{}, @min(lim, 20));
            return .{ .text = if (r.block.len == 0) "(no memories matched)" else r.block };
        },
        .memory_add => {
            const t = [1]TurnIn{.{ .role = "user", .text = args.text.? }};
            try c.needWrites();
            const sc = try c.who.defaultWriteScope(c.a);
            if (!c.who.mayWrite(sc)) return c.deny("scope not writable by this seat");
            const r = try capture(c, sc, args.session_key orelse "mcp", null, &t);
            return .{ .text = try capturedJson(c, r, false) };
        },
        .memory_get => {
            const x = (try getAtom(c, &.{}, args.id.?)) orelse return .{ .is_error = true, .text = "no such atom in this seat's scopes" };
            var b: std.ArrayList(u8) = .empty;
            try atomJson(c.a, &b, x);
            return .{ .text = b.items };
        },
        .memory_block => {
            const f = try frozenBlock(c, args.session_key.?);
            return .{ .text = if (f.text.len == 0) "(empty block: no persona or scene rows in this seat's scopes)" else f.text };
        },
    }
}
