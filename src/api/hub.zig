//! The hub: one store file, one writer thread, a pool of read-only connections, the seat token table, the
//! Retriever (phase-4 stub until phase 3 lands), the extraction worker, and an append-only audit log (one JSON line
//! per call: seat, route/tool, status, ms, sizes — never arguments or text).
const std = @import("std");
const linux = std.os.linux;
const store = @import("store");
const extract = @import("extract");
const auth = @import("auth.zig");
const http = @import("http.zig");
const retrieval = @import("retrieval.zig");
const hh = @import("household");
const worker_mod = @import("worker.zig");
const fold = @import("fold.zig");
const json = @import("json.zig");

pub const version = "0.8.0-integration";

/// How often the background thread re-runs `PRAGMA quick_check` for /health (fix batch item 3). /health?deep=1 runs it now.
pub const db_check_every_ms: u64 = 10 * 60 * 1000;

/// Cached database check for /health. Each run opens a FRESH short-lived read-only connection (never a pooled reader, never
/// the writer, never kept between runs), so the hot paths do not wait for it: first at startup in the background, then every
/// `db_check_every_ms`, and on demand. Merge-lane fix 10/14: a connection KEPT between runs reported FTS5 "corruption found
/// reading blob" on every other check once the writer had rewritten FTS5 segments (stale cached structure; the file was
/// sound: receipts/merge/hub_stale_*.json, fix/repro_*.txt). A fresh connection per run never did.
pub const DbCheck = struct {
    /// Serialises runs (one check at a time).
    run_mu: std.Io.Mutex = .init,
    /// Guards the cached result below (held only to copy it).
    st_mu: std.Io.Mutex = .init,
    state: enum { pending, ok, failed } = .pending,
    msg: [240]u8 = undefined,
    msg_len: usize = 0,
    at_ms: i64 = 0,
    dur_ms: f64 = 0,
    runs: u64 = 0,
};

pub const Config = struct {
    home: []const u8,
    bind: [4]u8 = .{ 127, 0, 0, 1 },
    port: u16 = 8470,
    /// null = no background extraction (captures still land in L0; nothing is queued).
    extract: ?extract.allow.Endpoint = null,
    workers: u8 = 2,
    /// Bounded extraction queue: a capture that would exceed it is refused with 429 (nothing written).
    queue_cap: i64 = 10_000,
    readers: usize = 8,
    /// Phase-3 retrieval + gates (ledger, embedder, reranker, today).
    retrieval: retrieval.Config = .{ .today = .{ .y = 1970, .m = 1, .d = 1 } },
    /// The L2/L3 fold cadence (SPEC §1.2 defaults).
    fold: fold.Cadence = .{},
};

pub const Readers = struct {
    io: std.Io,
    mu: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    stores: []store.Store,
    free: []usize,
    nfree: usize,

    pub fn acquire(r: *Readers) *store.Store {
        r.mu.lockUncancelable(r.io);
        defer r.mu.unlock(r.io);
        while (r.nfree == 0) r.cond.waitUncancelable(r.io, &r.mu);
        r.nfree -= 1;
        return &r.stores[r.free[r.nfree]];
    }

    /// The slot index of a reader (its own retrieval engine context lives at the same index).
    pub fn slotOf(r: *const Readers, st: *const store.Store) usize {
        return @divExact(@intFromPtr(st) - @intFromPtr(r.stores.ptr), @sizeOf(store.Store));
    }

    pub fn release(r: *Readers, st: *store.Store) void {
        const idx = r.slotOf(st);
        r.mu.lockUncancelable(r.io);
        defer r.mu.unlock(r.io);
        r.free[r.nfree] = idx;
        r.nfree += 1;
        r.cond.signal(r.io);
    }
};

pub const Audit = struct {
    route: []const u8 = "",
    seat: []const u8 = "-",
    tool: ?[]const u8 = null,
    method: ?[]const u8 = null,
    /// The request carried identity claims (vendor identity headers, x-zigmem-seat, body user/seat ids) — ignored, but recorded.
    ignored_identity: bool = false,
    denied: ?[]const u8 = null,
    /// Time spent inside Retriever.search (incl. waiting for a reader), for latency attribution.
    search_ms: f64 = 0,
    /// Household read audit (phase 5): one entry per cross-person/seat scope a read searched, plus 8 hex of the query's
    /// sha256 — never the query. Kept in audit.log, so a read never writes to the memory database (a write would also
    /// reset every reader's page cache).
    xread: std.ArrayList([]const u8) = .empty,
    qh: ?[8]u8 = null,
};

pub const Hub = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    db_path: [:0]const u8,
    wst: store.Store,
    writer: store.writer.Writer,
    readers: Readers,
    tokens: auth.Live,
    eng: retrieval.Engine = undefined,
    audit_fd: i32,
    started_ms: i64,
    worker: ?worker_mod.Worker = null,
    dbc: DbCheck = .{},

    /// Opens (creating/migrating) `<home>/zigmem.db`, the token file `<home>/tokens` (must exist, 0600) and the audit
    /// log `<home>/audit.log` (0600, append-only). `hub` must not move afterwards (threads keep pointers into it).
    pub fn init(hub: *Hub, gpa: std.mem.Allocator, io: std.Io, cfg: Config) !void {
        const db_path = try std.fmt.allocPrintSentinel(gpa, "{s}/zigmem.db", .{cfg.home}, 0);
        const tok_path = try std.fmt.allocPrintSentinel(gpa, "{s}/tokens", .{cfg.home}, 0);
        const audit_path = try std.fmt.allocPrintSentinel(gpa, "{s}/audit.log", .{cfg.home}, 0);
        hub.* = .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .db_path = db_path,
            .wst = try store.Store.open(gpa, io, db_path, .{}),
            .writer = undefined,
            .readers = undefined,
            .tokens = try auth.Live.open(gpa, io, tok_path),
            .audit_fd = undefined,
            .started_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        };
        const rc = linux.open(audit_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true, .NOFOLLOW = true }, 0o600);
        if (linux.errno(rc) != .SUCCESS) return error.AuditLogOpenFailed;
        hub.audit_fd = @intCast(rc);
        // household tables (phase 5) beside the store schema, before any reader opens
        try hh.schema.migrate(&hub.wst);
        hub.writer = store.writer.Writer.init(&hub.wst);
        try hub.writer.start();
        // Every job a crash left `running` goes back to the queue (its try already counted).
        _ = try hub.writer.call(store.jobs.recover, .{});
        const n = @max(cfg.readers, 1);
        const stores = try gpa.alloc(store.Store, n);
        const free = try gpa.alloc(usize, n);
        for (stores, 0..) |*s, i| {
            s.* = try store.Store.open(gpa, io, db_path, .{ .read_only = true });
            free[i] = i;
        }
        hub.readers = .{ .io = io, .stores = stores, .free = free, .nfree = n };
        hub.eng = try retrieval.Engine.init(gpa, &hub.wst, n, cfg.retrieval);
        // /health's database check: first run now in the background, then every db_check_every_ms (process lifetime).
        const ct = try std.Thread.spawn(.{}, dbCheckLoop, .{hub});
        ct.detach();
        if (cfg.extract) |ep| {
            hub.worker = .{ .gpa = gpa, .io = io, .db_path = db_path, .w = &hub.writer, .ep = ep, .threads = @min(cfg.workers, worker_mod.max_threads), .person_of = .{ .ctx = hub, .f = personOf }, .eng = &hub.eng, .cadence = cfg.fold };
            try hub.worker.?.start();
        }
    }

    /// Who spoke a captured turn: the household member the seat is bound to (live registry), else the token's person.
    fn personOf(ctx: *anyopaque, a: std.mem.Allocator, seat: []const u8) ?[]const u8 {
        const hub: *Hub = @ptrCast(@alignCast(ctx));
        {
            const rd = hub.readers.acquire();
            defer hub.readers.release(rd);
            const house: hh.House = .{ .st = rd };
            if (house.load(a)) |L| {
                if (L.reg.seat(seat)) |s| if (s.member) |m| return a.dupe(u8, m) catch null;
            } else |_| {}
        }
        const t = hub.tokens.current() orelse return null;
        const s = t.find(seat) orelse return null;
        return if (s.person) |p| a.dupe(u8, p) catch null else null;
    }

    pub fn nowMs(hub: *Hub) i64 {
        return std.Io.Timestamp.now(hub.io, .real).toMilliseconds();
    }

    /// One JSON line per call. A failed audit write is reported on stderr, never silently dropped.
    pub fn audit(hub: *Hub, a: std.mem.Allocator, au: Audit, status: u16, ms: f64, in_bytes: usize, out_bytes: usize) void {
        var b: std.ArrayList(u8) = .empty;
        var o = json.Obj.begin(a, &b) catch return;
        o.n("ts_ms", hub.nowMs()) catch return;
        o.s("seat", au.seat) catch return;
        o.s("route", au.route[0..@min(au.route.len, 80)]) catch return;
        o.s("method", au.method) catch return;
        o.s("tool", au.tool) catch return;
        o.n("status", status) catch return;
        o.f("ms", ms) catch return;
        o.n("in", @intCast(in_bytes)) catch return;
        o.n("out", @intCast(out_bytes)) catch return;
        if (au.ignored_identity) o.b_("ignored_identity", true) catch return;
        if (au.denied) |d| o.s("denied", d) catch return;
        if (au.search_ms > 0) o.f("search_ms", au.search_ms) catch return;
        if (au.xread.items.len > 0) {
            var xs: std.ArrayList(u8) = .empty;
            xs.append(a, '[') catch return;
            for (au.xread.items, 0..) |s, i| {
                if (i > 0) xs.append(a, ',') catch return;
                json.writeString(a, &xs, s) catch return;
            }
            xs.append(a, ']') catch return;
            o.raw("xread", xs.items) catch return;
        }
        if (au.qh) |q| o.s("q", &q) catch return;
        o.end() catch return;
        b.append(a, '\n') catch return;
        const rc = linux.write(hub.audit_fd, b.items.ptr, b.items.len);
        if (linux.errno(rc) != .SUCCESS or rc != b.items.len) std.debug.print("zigmem: audit write failed\n", .{});
    }

    pub fn queuedJobs(hub: *Hub) !i64 {
        const rd = hub.readers.acquire();
        defer hub.readers.release(rd);
        return store.jobs.count(rd, "queued");
    }

    fn dbCheckLoop(hub: *Hub) void {
        while (true) {
            hub.runDbCheck();
            var ts: linux.timespec = .{ .sec = @intCast(db_check_every_ms / 1000), .nsec = @intCast((db_check_every_ms % 1000) * 1_000_000) };
            _ = linux.nanosleep(&ts, null);
        }
    }

    /// `PRAGMA quick_check(5)` on a fresh read-only connection opened for this run and closed after it; result cached for /health.
    pub fn runDbCheck(hub: *Hub) void {
        const c = &hub.dbc;
        c.run_mu.lockUncancelable(hub.io);
        defer c.run_mu.unlock(hub.io);
        const t0 = std.Io.Timestamp.now(hub.io, .awake).nanoseconds;
        var buf: [240]u8 = undefined;
        var ok = false;
        var msg: []const u8 = "";
        var conn: ?store.Store = store.Store.open(hub.gpa, hub.io, hub.db_path, .{ .read_only = true }) catch |e| blk: {
            msg = std.fmt.bufPrint(&buf, "cannot open: {s}", .{@errorName(e)}) catch "cannot open";
            break :blk null;
        };
        if (conn) |*cs| {
            defer cs.close(); // never kept between runs (see DbCheck)
            if (quickCheck(cs, &buf)) |m| {
                msg = m;
                ok = std.mem.eql(u8, m, "ok");
            } else |e| {
                msg = std.fmt.bufPrint(&buf, "quick_check error: {s}", .{@errorName(e)}) catch "quick_check error";
            }
        }
        const dur: f64 = @as(f64, @floatFromInt(std.Io.Timestamp.now(hub.io, .awake).nanoseconds - t0)) / 1e6;
        c.st_mu.lockUncancelable(hub.io);
        defer c.st_mu.unlock(hub.io);
        const n = @min(msg.len, c.msg.len);
        @memcpy(c.msg[0..n], msg[0..n]);
        c.msg_len = n;
        c.state = if (ok) .ok else .failed;
        c.at_ms = hub.nowMs();
        c.dur_ms = dur;
        c.runs += 1;
    }

    /// Rows of quick_check joined with "; " (truncated to `buf`). Exactly "ok" means the file is sound.
    fn quickCheck(cs: *store.Store, buf: []u8) ![]const u8 {
        var st = try cs.db.prepare("PRAGMA quick_check(5)");
        defer st.deinit();
        var w: usize = 0;
        var first = true;
        while (try st.step()) {
            const t = st.text(0);
            if (!first and w + 2 <= buf.len) {
                @memcpy(buf[w .. w + 2], "; ");
                w += 2;
            }
            first = false;
            const k = @min(t.len, buf.len - w);
            @memcpy(buf[w .. w + k], t[0..k]);
            w += k;
        }
        return if (first) "quick_check returned no rows" else buf[0..w];
    }

    /// /health (no auth): counts only, no row text.
    pub fn health(hub: *Hub, a: std.mem.Allocator) ![]u8 {
        return (try hub.healthCheck(a, false)).body;
    }

    pub const Health = struct { ok: bool, body: []u8 };

    /// /health body plus whether the hub is healthy (false → the route answers 503). ok is false when the last database
    /// check failed or a count query errors. `deep` re-runs the database check now instead of using the cached result.
    pub fn healthCheck(hub: *Hub, a: std.mem.Allocator, deep: bool) !Health {
        if (deep) hub.runDbCheck();
        var dbs: []const u8 = "pending";
        var db_ok = true;
        var at_ms: i64 = 0;
        var dur_ms: f64 = 0;
        var runs: u64 = 0;
        {
            hub.dbc.st_mu.lockUncancelable(hub.io);
            defer hub.dbc.st_mu.unlock(hub.io);
            if (hub.dbc.state != .pending) dbs = try a.dupe(u8, hub.dbc.msg[0..hub.dbc.msg_len]);
            db_ok = hub.dbc.state != .failed;
            at_ms = hub.dbc.at_ms;
            dur_ms = hub.dbc.dur_ms;
            runs = hub.dbc.runs;
        }
        const rd = hub.readers.acquire();
        defer hub.readers.release(rd);
        var count_err: ?[]const u8 = null;
        const n_l0 = rd.db.oneInt("SELECT count(*) FROM l0", .{}) catch |e| blk: {
            count_err = @errorName(e);
            break :blk null;
        };
        const n_atoms = rd.db.oneInt("SELECT count(*) FROM atoms", .{}) catch |e| blk: {
            count_err = @errorName(e);
            break :blk null;
        };
        const n_active = rd.db.oneInt("SELECT count(*) FROM atoms WHERE status = 'active'", .{}) catch |e| blk: {
            count_err = @errorName(e);
            break :blk null;
        };
        const healthy = db_ok and count_err == null;
        var b: std.ArrayList(u8) = .empty;
        var o = try json.Obj.begin(a, &b);
        try o.b_("ok", healthy);
        try o.s("version", version);
        try o.n("schema", store.schema.version);
        var dbo: std.ArrayList(u8) = .empty;
        var d = try json.Obj.begin(a, &dbo);
        try d.s("quick_check", dbs);
        try d.n("checked_ms", at_ms);
        try d.f("check_ms", dur_ms);
        try d.n("checks", @intCast(runs));
        try d.s("count_error", count_err);
        try d.end();
        try o.raw("db", dbo.items);
        var rows: std.ArrayList(u8) = .empty;
        var r = try json.Obj.begin(a, &rows);
        try r.n("l0", n_l0 orelse 0);
        try r.n("atoms", n_atoms orelse 0);
        try r.n("active", n_active orelse 0);
        try r.end();
        try o.raw("rows", rows.items);
        try o.b_("fts", true);
        try o.s("retriever", retrieval.name);
        try o.n("vectors", @intCast(hub.eng.vectorCount()));
        var ex: std.ArrayList(u8) = .empty;
        var e = try json.Obj.begin(a, &ex);
        try e.b_("enabled", hub.worker != null);
        try e.s("engine", if (hub.cfg.extract) |x| @tagName(x.engine) else null);
        try e.n("threads", if (hub.worker) |w| @min(w.threads, worker_mod.max_threads) else 0);
        try e.n("queued", try store.jobs.count(rd, "queued"));
        try e.n("running", try store.jobs.count(rd, "running"));
        try e.n("done_total", try store.jobs.count(rd, "done"));
        try e.n("dead", try store.jobs.count(rd, "dead"));
        if (hub.worker) |*w| {
            try e.n("inflight", w.stats.inflight.load(.acquire));
            try e.n("inflight_max", w.stats.inflight_max.load(.acquire));
            try e.n("engine_connects", @intCast(w.stats.connects.load(.acquire)));
            try e.n("engine_refused", @intCast(w.stats.refused.load(.acquire)));
            try e.n("failed", @intCast(w.stats.failed.load(.acquire)));
        }
        try e.end();
        try o.raw("extract", ex.items);
        // the live path's other three jobs: embedding, the reviewer, the fold
        var em: std.ArrayList(u8) = .empty;
        var emo = try json.Obj.begin(a, &em);
        try emo.b_("enabled", hub.eng.embedder != null);
        try emo.n("unembedded", (rd.db.oneInt("SELECT count(*) FROM atoms a LEFT JOIN vec v ON v.kind = 'atom' AND v.row_id = a.id WHERE a.status = 'active' AND v.row_id IS NULL", .{}) catch null) orelse 0);
        if (hub.worker) |*w| {
            try emo.n("embedded", @intCast(w.stats.embedded.load(.acquire)));
            try emo.n("failed_calls", @intCast(w.stats.embed_failed.load(.acquire)));
        }
        try emo.end();
        try o.raw("embed", em.items);
        var rv: std.ArrayList(u8) = .empty;
        var rvo = try json.Obj.begin(a, &rv);
        try rvo.n("pending", (rd.db.oneInt("SELECT count(*) FROM atoms WHERE status = 'pending_review'", .{}) catch null) orelse 0);
        try rvo.n("unreviewed", (rd.db.oneInt("SELECT count(*) FROM atoms WHERE status = 'pending_review' AND id NOT IN (SELECT row_id FROM audit WHERE table_name = 'atoms' AND action = 'review' AND row_id IS NOT NULL)", .{}) catch null) orelse 0);
        if (hub.worker) |*w| {
            try rvo.n("resolved", @intCast(w.stats.reviewed.load(.acquire)));
            try rvo.n("retired", @intCast(w.stats.review_retired.load(.acquire)));
            try rvo.n("failed", @intCast(w.stats.review_failed.load(.acquire)));
        }
        try rvo.end();
        try o.raw("review", rv.items);
        var fo: std.ArrayList(u8) = .empty;
        var foo = try json.Obj.begin(a, &fo);
        try foo.n("runs", @intCast(fold.runs(rd)));
        try foo.n("last_ms", fold.lastMs(rd));
        try foo.n("scenes", (rd.db.oneInt("SELECT count(*) FROM scenes WHERE status = 'active'", .{}) catch null) orelse 0);
        try foo.n("persona", (rd.db.oneInt("SELECT count(*) FROM persona", .{}) catch null) orelse 0);
        if (hub.worker) |*w| {
            try foo.n("new_since_fold", w.stats.new_since_fold.load(.acquire));
            try foo.n("due_ms", w.stats.fold_due_ms.load(.acquire));
        }
        try foo.end();
        try o.raw("fold", fo.items);
        try o.n("uptime_ms", hub.nowMs() - hub.started_ms);

        try o.end();
        return .{ .ok = healthy, .body = b.items };
    }
};
