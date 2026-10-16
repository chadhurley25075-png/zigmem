//! `zigmem serve | token | people`. serve = hub API + MCP on 127.0.0.1:8470 (or an explicit tailnet 100.x via --bind),
//! the extraction worker, and optionally the phase-0 proxy fed by frozen session blocks from the store.
const std = @import("std");
const linux = std.os.linux;
const store = @import("store");
const extract = @import("extract");
const auth = @import("auth.zig");
const http = @import("http.zig");
const hub_mod = @import("hub.zig");
const rest = @import("rest.zig");
const block = @import("block.zig");
const hh = @import("household");
const privacy = @import("privacy");

/// main.zig owns the phase-0 proxy; it hands us these so the same binary can run it with store-backed blocks.
pub const ProxyHooks = struct {
    /// `authBlockFn`: every proxied request carries a seat token; the block is that verified seat's (null = refuse).
    start: *const fn (gpa: std.mem.Allocator, port: u16, upstream: []const u8, ctx: *const anyopaque, blockFn: *const fn (*const anyopaque, []const u8) []const u8, authBlockFn: *const fn (*const anyopaque, []const u8, []const u8) ?[]const u8) anyerror!void,
    message: *const fn (a: std.mem.Allocator, raw: []const u8) anyerror![]u8,
    /// Phase 6: wraps the REST handler so /panel/* is served by the web panel (null = API only).
    panel: ?*const fn (hub: *hub_mod.Hub, inner: http.Handler) anyerror!http.Handler = null,
};

pub const usage =
    \\usage:
    \\  zigmem serve [--home DIR] [--port 8470] [--bind 127.0.0.1|100.x.y.z] [--extract none|primary|secondary]
    \\               [--workers 1|2] [--queue-cap N] [--proxy-upstream http://IP:PORT --proxy-port P]
    \\               [--ledger FILE|none] [--embed-url U|none] [--rerank U|none] [--rerank-fallback U|none] [--today YYYY-MM-DD]
    \\               [--fold-cadence SECONDS] [--fold-idle SECONDS]   (L2/L3 fold: minimum spacing, default 900; idle trigger, default 600)
    \\               (the proxy needs `Authorization: Bearer <seat token>` on every request; the block is that seat's)
    \\  zigmem token add --seat NAME --scopes a,b|* [--writes] [--trusted] [--admin] [--person ID] [--home DIR]
    \\               (--trusted: may write family / medical / money text; without it the privacy screen refuses such captures with 403)
    \\  zigmem household bootstrap --file FILE.json [--home DIR]   (first run only: members + seats)
    \\  zigmem household list [--home DIR]
    \\  zigmem token revoke --seat NAME [--home DIR]
    \\  zigmem token list [--home DIR]
    \\  zigmem people add --id ID [--aliases A,B] [--display NAME] [--home DIR]
    \\  zigmem proxy --upstream http://IP:PORT [--port 18140] [--memory FILE]   (phase 0, frozen file)
    \\
;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zigmem: " ++ fmt, args);
    std.process.exit(2);
}

const Flags = struct {
    args: []const [:0]const u8,
    i: usize = 2,
    fn next(f: *Flags) ?[]const u8 {
        if (f.i >= f.args.len) return null;
        defer f.i += 1;
        return f.args[f.i];
    }
    fn value(f: *Flags, name: []const u8) []const u8 {
        return f.next() orelse fail("missing value for {s}\n", .{name});
    }
};

fn defaultHome(a: std.mem.Allocator, env: *const std.process.Environ.Map) []const u8 {
    if (env.get("ZIGMEM_HOME")) |h| return h;
    const home = env.get("HOME") orelse fail("HOME is not set; pass --home\n", .{});
    return std.fmt.allocPrint(a, "{s}/.zigmem", .{home}) catch fail("oom\n", .{});
}

fn ensureHome(a: std.mem.Allocator, home: []const u8) void {
    const z = a.dupeSentinel(u8, home, 0) catch fail("oom\n", .{});
    const rc = linux.mkdirat(linux.AT.FDCWD, z.ptr, 0o700);
    switch (linux.errno(rc)) {
        .SUCCESS, .EXIST => {},
        else => fail("cannot create home {s}\n", .{home}),
    }
}

pub fn main(init: std.process.Init, args: []const [:0]const u8, hooks: ProxyHooks) !void {
    const arena = init.arena.allocator();
    const cmd: []const u8 = args[1];
    if (std.mem.eql(u8, cmd, "serve")) return serve(init, args, hooks);
    if (std.mem.eql(u8, cmd, "token")) return token(init, arena, args);
    if (std.mem.eql(u8, cmd, "people")) return people(init, arena, args);
    if (std.mem.eql(u8, cmd, "household")) return household(init, arena, args);
    fail("{s}", .{usage});
}

// ---- token ----

fn token(init: std.process.Init, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 3) fail("{s}", .{usage});
    const sub: []const u8 = args[2];
    var f: Flags = .{ .args = args, .i = 3 };
    var home: ?[]const u8 = null;
    var seat: ?[]const u8 = null;
    var scopes: ?[]const u8 = null;
    var person: ?[]const u8 = null;
    var writes = false;
    var trusted = false;
    var admin = false;
    while (f.next()) |k| {
        if (std.mem.eql(u8, k, "--home")) home = f.value(k) else if (std.mem.eql(u8, k, "--seat")) seat = f.value(k) else if (std.mem.eql(u8, k, "--scopes")) scopes = f.value(k) else if (std.mem.eql(u8, k, "--person")) person = f.value(k) else if (std.mem.eql(u8, k, "--writes")) writes = true else if (std.mem.eql(u8, k, "--trusted")) trusted = true else if (std.mem.eql(u8, k, "--admin")) admin = true else fail("unknown flag {s}\n", .{k});
    }
    const h = home orelse defaultHome(a, init.environ_map);
    ensureHome(a, h);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/tokens", .{h}, 0);
    var table: auth.Table = blk: {
        _ = auth.checkMode(path) catch |e| switch (e) {
            error.FileNotFound => break :blk try auth.parse(a, ""),
            else => fail("token file {s}: {s}\n", .{ path, @errorName(e) }),
        };
        break :blk try auth.parse(a, try auth.readAll(a, path, 1 << 20));
    };
    const now = std.Io.Timestamp.now(init.io, .real).toMilliseconds();
    var list: std.ArrayList(auth.Seat) = .empty;
    try list.appendSlice(a, table.seats);
    if (std.mem.eql(u8, sub, "list")) {
        for (list.items) |s| {
            std.debug.print("{s}\tscopes=", .{s.name});
            for (s.scopes, 0..) |x, i| std.debug.print("{s}{s}", .{ if (i == 0) "" else ",", x });
            std.debug.print("\twrites={} trusted={} admin={} person={s} {s}\n", .{ s.writes, s.trusted, s.admin, s.person orelse "-", if (s.revoked_ms != null) "REVOKED" else "active" });
        }
        return;
    }
    const name = seat orelse fail("--seat is required\n", .{});
    if (!auth.validName(name)) fail("bad seat name (A-Z a-z 0-9 . _ -, max 64)\n", .{});
    if (std.mem.eql(u8, sub, "add")) {
        if (table.find(name) != null) fail("seat {s} already has an active token (revoke it first)\n", .{name});
        var sc: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, scopes orelse fail("--scopes is required\n", .{}), ',');
        while (it.next()) |x| {
            if (!auth.validScope(x)) fail("bad scope '{s}' (a-z 0-9 : _ -, max 64)\n", .{x});
            try sc.append(a, x);
        }
        if (sc.items.len == 0 or sc.items.len > 16) fail("1-16 scopes\n", .{});
        var buf: [67]u8 = undefined;
        const tok = try auth.newToken(init.io, &buf);
        try list.append(a, .{ .name = name, .hash = auth.hashToken(tok), .scopes = sc.items, .writes = writes, .trusted = trusted, .admin = admin, .person = person, .created_ms = now, .revoked_ms = null });
        try auth.writeAtomic(a, path, try auth.render(a, list.items));
        // The token is shown once, on stdout; only its hash is stored.
        _ = linux.write(1, tok.ptr, tok.len);
        _ = linux.write(1, "\n", 1);
        return;
    }
    if (std.mem.eql(u8, sub, "revoke")) {
        var hit = false;
        for (list.items) |*s| if (std.mem.eql(u8, s.name, name) and s.revoked_ms == null) {
            s.revoked_ms = now;
            hit = true;
        };
        if (!hit) fail("no active token for seat {s}\n", .{name});
        try auth.writeAtomic(a, path, try auth.render(a, list.items));
        std.debug.print("revoked {s}\n", .{name});
        return;
    }
    table.deinit();
    fail("{s}", .{usage});
}

// ---- people ----

fn peopleOp(st: *store.Store, id: []const u8, display: []const u8, aliases: []const u8) !void {
    try st.db.run("INSERT INTO people(id, display, aliases) VALUES (?1,?2,?3) ON CONFLICT(id) DO UPDATE SET display = excluded.display, aliases = excluded.aliases", .{ id, display, aliases });
    try st.audit("cli", "people", "people", null, id);
}

fn people(init: std.process.Init, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 3 or !std.mem.eql(u8, args[2], "add")) fail("{s}", .{usage});
    var f: Flags = .{ .args = args, .i = 3 };
    var home: ?[]const u8 = null;
    var id: ?[]const u8 = null;
    var aliases: []const u8 = "";
    var display: ?[]const u8 = null;
    while (f.next()) |k| {
        if (std.mem.eql(u8, k, "--home")) home = f.value(k) else if (std.mem.eql(u8, k, "--id")) id = f.value(k) else if (std.mem.eql(u8, k, "--aliases")) aliases = f.value(k) else if (std.mem.eql(u8, k, "--display")) display = f.value(k) else fail("unknown flag {s}\n", .{k});
    }
    const pid = id orelse fail("--id is required\n", .{});
    if (!auth.validName(pid)) fail("bad id\n", .{});
    const h = home orelse defaultHome(a, init.environ_map);
    ensureHome(a, h);
    var st = try store.Store.open(init.gpa, init.io, try std.fmt.allocPrintSentinel(a, "{s}/zigmem.db", .{h}, 0), .{});
    defer st.close();
    try st.savepoint(peopleOp, .{ &st, pid, display orelse pid, aliases });
    std.debug.print("person {s} saved\n", .{pid});
}

// ---- household ----

fn hhBootstrapOp(st: *store.Store, a: std.mem.Allocator, members: []const hh.House.MemberIn, seats: []const hh.policy.Seat) !void {
    const house = try hh.House.init(st);
    try house.bootstrap(a, members, seats);
}

fn household(init: std.process.Init, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 3) fail("{s}", .{usage});
    const sub: []const u8 = args[2];
    var f: Flags = .{ .args = args, .i = 3 };
    var home: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    while (f.next()) |k| {
        if (std.mem.eql(u8, k, "--home")) home = f.value(k) else if (std.mem.eql(u8, k, "--file")) file = f.value(k) else fail("unknown flag {s}\n", .{k});
    }
    const h = home orelse defaultHome(a, init.environ_map);
    ensureHome(a, h);
    var st = try store.Store.open(init.gpa, init.io, try std.fmt.allocPrintSentinel(a, "{s}/zigmem.db", .{h}, 0), .{});
    defer st.close();
    const house = try hh.House.init(&st);
    if (std.mem.eql(u8, sub, "list")) {
        const L = try house.load(a);
        for (L.reg.members) |m| std.debug.print("member {s}\t{s}\trole={s}{s}\n", .{ m.id, m.display, @tagName(m.role), if (m.revoked) "\tREVOKED" else "" });
        for (L.reg.seats) |s| std.debug.print("seat {s}\tmember={s}{s}\n", .{ s.name, s.member orelse "(shared)", if (s.revoked) "\tREVOKED" else "" });
        return;
    }
    if (!std.mem.eql(u8, sub, "bootstrap")) fail("{s}", .{usage});
    const path = file orelse fail("--file is required\n", .{});
    const raw = std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(1 << 20)) catch fail("cannot read --file\n", .{});
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch fail("--file is not JSON\n", .{});
    var members: std.ArrayList(hh.House.MemberIn) = .empty;
    var seats: std.ArrayList(hh.policy.Seat) = .empty;
    const ms = if (v == .object) v.object.get("members") else null;
    const ss = if (v == .object) v.object.get("seats") else null;
    if (ms == null or ms.? != .array or ss == null or ss.? != .array) fail("--file needs {{\"members\":[...],\"seats\":[...]}}\n", .{});
    for (ms.?.array.items) |m| {
        if (m != .object) fail("bad member\n", .{});
        const g = struct {
            fn s(o: std.json.Value, k: []const u8) []const u8 {
                const x = o.object.get(k) orelse return "";
                return if (x == .string) x.string else "";
            }
        };
        var al: std.ArrayList([]const u8) = .empty;
        if (m.object.get("aliases")) |x| if (x == .array) for (x.array.items) |y| if (y == .string) try al.append(a, y.string);
        const role = std.meta.stringToEnum(hh.policy.Role, g.s(m, "role")) orelse fail("bad role for {s}\n", .{g.s(m, "id")});
        try members.append(a, .{ .id = g.s(m, "id"), .display = g.s(m, "display"), .aliases = al.items, .role = role, .relation = g.s(m, "relation") });
    }
    for (ss.?.array.items) |s| {
        if (s != .object) fail("bad seat\n", .{});
        const n = s.object.get("name") orelse fail("seat needs a name\n", .{});
        const mem = s.object.get("member");
        try seats.append(a, .{ .name = if (n == .string) n.string else fail("bad seat name\n", .{}), .member = if (mem != null and mem.? == .string) mem.?.string else null });
    }
    try st.savepoint(hhBootstrapOp, .{ &st, a, members.items, seats.items });
    std.debug.print("household bootstrapped: {d} members, {d} seats\n", .{ members.items.len, seats.items.len });
}

// ---- serve ----

/// Proxy MemorySource: every request names its seat by TOKEN (verified per request, so revocation is immediate);
/// the block is that seat's frozen session block (household scopes + phase-3 gates), cached per seat+session.
const ProxySource = struct {
    hub: *hub_mod.Hub,
    message: *const fn (a: std.mem.Allocator, raw: []const u8) anyerror![]u8,
    mu: std.Io.Mutex = .init,
    cache: std.StringHashMapUnmanaged([]const u8) = .empty,

    const max_sessions = 4096;

    /// Phase-0 shape (no token): never used by the hub's proxy — it always passes authBlockFn. Refuses.
    fn blockFn(_: *const anyopaque, _: []const u8) []const u8 {
        return "";
    }

    fn authBlockFn(ctx: *const anyopaque, tok: []const u8, session: []const u8) ?[]const u8 {
        const p: *ProxySource = @ptrCast(@alignCast(@constCast(ctx)));
        return p.get(tok, if (session.len == 0) "default" else session) catch |e| {
            std.debug.print("proxy block: {s} (refused)\n", .{@errorName(e)});
            return null;
        };
    }

    fn get(p: *ProxySource, tok: []const u8, session: []const u8) !?[]const u8 {
        var arena: std.heap.ArenaAllocator = .init(p.hub.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const who = switch (try rest.identify(p.hub, a, tok)) {
            .ok => |w| w,
            else => return null,
        };
        const key = try std.fmt.allocPrint(a, "{s}/{s}", .{ who.seat.name, session });
        const io = p.hub.io;
        p.mu.lockUncancelable(io);
        defer p.mu.unlock(io);
        if (p.cache.get(key)) |m| return m;
        if (p.cache.count() >= max_sessions) return error.SessionCacheFull;
        const text = blk: {
            const rd = p.hub.readers.acquire();
            defer p.hub.readers.release(rd);
            if (try block.lookup(a, rd, key)) |f| break :blk f.text;
            break :blk try block.buildFor(a, rd, &who, &p.hub.eng, p.hub.readers.slotOf(rd));
        };
        var out: block.Frozen = undefined;
        try p.hub.writer.call(block.freezeOp, .{ a, key, text, &out });
        const msg = try p.message(p.hub.gpa, out.text);
        try p.cache.put(p.hub.gpa, try p.hub.gpa.dupe(u8, key), msg);
        return msg;
    }
};

fn optUrl(v: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, v, "none")) null else v;
}

fn parseDate(s: []const u8) ?privacy.ledger.Date {
    if (s.len != 10) return null;
    return privacy.ledger.Date.valid(
        std.fmt.parseInt(i64, s[0..4], 10) catch return null,
        std.fmt.parseInt(i64, s[5..7], 10) catch return null,
        std.fmt.parseInt(i64, s[8..10], 10) catch return null,
    );
}

/// Local civil date (UTC) for the gates' "today".
fn todayUtc(io: std.Io) privacy.ledger.Date {
    const ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    var b: [10]u8 = undefined;
    const s = @import("worker.zig").dateOf(&b, ms);
    return parseDate(s) orelse .{ .y = 1970, .m = 1, .d = 1 };
}

fn serve(init: std.process.Init, args: []const [:0]const u8, hooks: ProxyHooks) !void {
    const a = init.arena.allocator();
    var f: Flags = .{ .args = args };
    var cfg: hub_mod.Config = .{ .home = "" };
    var home: ?[]const u8 = null;
    var proxy_up: ?[]const u8 = null;
    var proxy_port: u16 = 18141;
    var ledger_path: ?[]const u8 = null;
    var ledger_none = false;
    cfg.retrieval.today = todayUtc(init.io);
    while (f.next()) |k| {
        if (std.mem.eql(u8, k, "--home")) {
            home = f.value(k);
        } else if (std.mem.eql(u8, k, "--port")) {
            cfg.port = std.fmt.parseInt(u16, f.value(k), 10) catch fail("bad --port\n", .{});
        } else if (std.mem.eql(u8, k, "--bind")) {
            const v = f.value(k);
            cfg.bind = http.parseBind(v) catch |e| switch (e) {
                error.Unsafe => fail("refusing to bind {s}: only 127.0.0.1 or this host's tailnet 100.64.0.0/10 address (never 0.0.0.0 or a LAN address)\n", .{v}),
                error.BadAddress => fail("--bind needs an IPv4 literal: 127.0.0.1 or a 100.x tailnet address\n", .{}),
            };
        } else if (std.mem.eql(u8, k, "--extract")) {
            const v = f.value(k);
            cfg.extract = if (std.mem.eql(u8, v, "none")) null else extract.allow.resolve(v) catch fail("--extract {s}: not on the allowlist\n", .{v});
        } else if (std.mem.eql(u8, k, "--workers")) {
            cfg.workers = std.fmt.parseInt(u8, f.value(k), 10) catch fail("bad --workers\n", .{});
            if (cfg.workers < 1 or cfg.workers > 2) fail("--workers must be 1 or 2 (the primary engine takes at most 2 concurrent requests)\n", .{});
        } else if (std.mem.eql(u8, k, "--queue-cap")) {
            cfg.queue_cap = std.fmt.parseInt(i64, f.value(k), 10) catch fail("bad --queue-cap\n", .{});
        } else if (std.mem.eql(u8, k, "--proxy-upstream")) {
            proxy_up = f.value(k);
        } else if (std.mem.eql(u8, k, "--proxy-port")) {
            proxy_port = std.fmt.parseInt(u16, f.value(k), 10) catch fail("bad --proxy-port\n", .{});
        } else if (std.mem.eql(u8, k, "--proxy-seat")) {
            fail("--proxy-seat is gone: the proxy takes the seat from each request's Authorization: Bearer <seat token>\n", .{});
        } else if (std.mem.eql(u8, k, "--ledger")) {
            const v = f.value(k);
            if (std.mem.eql(u8, v, "none")) ledger_none = true else ledger_path = v;
        } else if (std.mem.eql(u8, k, "--embed-url")) {
            cfg.retrieval.embed_url = optUrl(f.value(k));
        } else if (std.mem.eql(u8, k, "--rerank")) {
            cfg.retrieval.rerank = optUrl(f.value(k));
        } else if (std.mem.eql(u8, k, "--rerank-fallback")) {
            cfg.retrieval.rerank_fallback = optUrl(f.value(k));
        } else if (std.mem.eql(u8, k, "--today")) {
            cfg.retrieval.today = parseDate(f.value(k)) orelse fail("bad --today (YYYY-MM-DD)\n", .{});
        } else if (std.mem.eql(u8, k, "--fold-cadence")) {
            cfg.fold.l2_min_ms = 1000 * (std.fmt.parseInt(i64, f.value(k), 10) catch fail("bad --fold-cadence\n", .{}));
        } else if (std.mem.eql(u8, k, "--fold-idle")) {
            cfg.fold.idle_ms = 1000 * (std.fmt.parseInt(i64, f.value(k), 10) catch fail("bad --fold-idle\n", .{}));
        } else fail("unknown flag {s}\n{s}", .{ k, usage });
    }
    cfg.home = home orelse defaultHome(a, init.environ_map);
    // the window firewall's ledger: --ledger FILE, else the home deployment ledger if present (read-only), --ledger none = off
    if (!ledger_none) {
        const lp = ledger_path orelse if (init.environ_map.get("HOME")) |hm| std.fmt.allocPrint(a, "{s}/.claude/current_facts_ledger.json", .{hm}) catch null else null;
        if (lp) |p| cfg.retrieval.ledger_json = std.Io.Dir.cwd().readFileAlloc(init.io, p, a, .limited(1 << 24)) catch |e| blk: {
            if (ledger_path != null) fail("cannot read --ledger {s}: {s}\n", .{ p, @errorName(e) });
            break :blk null;
        };
    }
    ensureHome(a, cfg.home);
    // Listen before opening anything else: a refused or busy port fails fast and leaves nothing behind.
    const fd = http.Server.listen(cfg.bind, cfg.port) catch |e| fail("cannot listen on {d}.{d}.{d}.{d}:{d}: {s}\n", .{ cfg.bind[0], cfg.bind[1], cfg.bind[2], cfg.bind[3], cfg.port, @errorName(e) });
    const hub = try init.gpa.create(hub_mod.Hub);
    hub.init(init.gpa, init.io, cfg) catch |e| fail("cannot start the hub in {s}: {s} (create a seat first: zigmem token add ...)\n", .{ cfg.home, @errorName(e) });
    if (proxy_up) |up| {
        const ps = try init.gpa.create(ProxySource);
        ps.* = .{ .hub = hub, .message = hooks.message };
        try hooks.start(init.gpa, proxy_port, up, ps, ProxySource.blockFn, ProxySource.authBlockFn);
    }
    var handler = rest.handler(hub);
    if (hooks.panel) |wrapFn| handler = wrapFn(hub, handler) catch |e| fail("cannot start the panel: {s}\n", .{@errorName(e)});
    var server: http.Server = .{ .fd = fd, .handler = handler, .gpa = init.gpa };
    std.debug.print("zigmem serve: listening {d}.{d}.{d}.{d}:{d} pid={d} home={s} extract={s} retriever={s} vectors={d} ledger={s} rerank={s}\n", .{
        cfg.bind[0],                                          cfg.bind[1],                   cfg.bind[2],                         cfg.bind[3],                  cfg.port, linux.getpid(), cfg.home,
        if (cfg.extract) |x| @tagName(x.engine) else "off", @import("retrieval.zig").name, hub.eng.vectorCount(), if (cfg.retrieval.ledger_json != null) "on" else "off", cfg.retrieval.rerank orelse "none",
    });
    server.run();
}
