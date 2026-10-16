//! Integration: every row the hub serves goes through here. Atoms: phase-3 hybrid recall (FTS5 ∥ nomic vectors → RRF →
//! floors) with the phase-5 household row gate as recall's row filter, then phase 3's own gates (private tags, medical
//! person-scope text + subject column, window firewall, strict stamp, escape). Search routes use recall's list mode
//! (fused order, no rerank); /recall uses the full phase-3 path (rerank, keep, fact-fill, the block). Conversation turns
//! (L0, no subject column) are person-gated by their OWNER (the member of their person/seat scope) with the same row
//! gate, then the same phase-3 gates. One engine context (gates, escaper, util) per reader slot: nothing shared mutably.
const std = @import("std");
const store = @import("store");
const privacy = @import("privacy");
const R = @import("retrieve");
const hh = @import("household");
const access = @import("access.zig");
const retriever = @import("retriever.zig");
const Who = access.Who;
const Hit = retriever.Hit;

pub const name = "phase3-hybrid+household-gates";

pub const Slot = struct {
    gates: privacy.Gates,
    esc: privacy.escape.Escaper,
    util: R.util.Util,
};

pub const Config = struct {
    ledger_json: ?[]const u8 = null,
    today: privacy.ledger.Date,
    embed_url: ?[]const u8 = "http://127.0.0.1:8081/embed",
    /// the dev box-local reranker only by default (family text stays on this box).
    rerank: ?[]const u8 = "http://127.0.0.1:18098/rerank",
    rerank_fallback: ?[]const u8 = null,
    /// The phase-3 gate configuration (bench lane `zigmem`: --min-rerank 0.50).
    min_rerank: f32 = 0.50,
};

pub const Engine = struct {
    slots: []Slot,
    index: store.vec.Index,
    /// Guards `index`: readers hold it for a top-k scan, the worker holds it to append a live atom's vector.
    index_mu: std.Io.Mutex = .init,
    gpa: std.mem.Allocator,
    io: std.Io,
    embedder: ?R.embed.Embedder,
    reranker: R.rerank.Reranker,
    cfg: Config,

    /// Rows in the live vector index (the `vectors` count in /health).
    pub fn vectorCount(e: *Engine) usize {
        e.index_mu.lockUncancelable(e.io);
        defer e.index_mu.unlock(e.io);
        return e.index.ids.items.len;
    }

    /// A freshly embedded atom joins the live index (normalised here; the store keeps its own normalised copy).
    pub fn addVector(e: *Engine, row_id: i64, scope: []const u8, emb: []const f32) !void {
        const unit = try e.gpa.alloc(f32, emb.len);
        defer e.gpa.free(unit);
        store.vec.normalize(unit, emb);
        e.index_mu.lockUncancelable(e.io);
        defer e.index_mu.unlock(e.io);
        try e.index.add(e.gpa, row_id, scope, unit);
    }

    pub fn init(gpa: std.mem.Allocator, wst: *store.Store, n: usize, cfg: Config) !Engine {
        const slots = try gpa.alloc(Slot, n);
        for (slots) |*s| s.* = .{
            .gates = try privacy.Gates.init(gpa, cfg.ledger_json, cfg.today),
            .esc = try privacy.escape.Escaper.init(gpa),
            .util = try R.util.Util.init(gpa),
        };
        var rr: R.rerank.Reranker = .{};
        rr.primary = cfg.rerank;
        rr.fallback = cfg.rerank_fallback;
        // the the dev box-local reranker gets phase 3's the dev box leash (read 8 s), not the LAN reranker's 3 s LAN leash
        if (cfg.rerank) |u| if (std.mem.startsWith(u8, u, "http://127.0.0.1:")) {
            rr.primary_leash = rr.fallback_leash;
        };
        return .{
            .slots = slots,
            .index = try store.vec.Index.load(wst, gpa, .atom),
            .gpa = gpa,
            .io = wst.io,
            .embedder = if (cfg.embed_url) |u| R.embed.Embedder{ .url = u } else null,
            .reranker = rr,
            .cfg = cfg,
        };
    }

    fn ctx(e: *Engine, slot: usize, rd: *store.Store) R.recall.Ctx {
        const s = &e.slots[slot];
        return .{ .st = rd, .index = &e.index, .index_mu = &e.index_mu, .gates = &s.gates, .esc = &s.esc, .util = &s.util, .embedder = e.embedder, .reranker = e.reranker };
    }
};

/// The household row gate as phase-3 recall's row filter (+ the request's narrowing type/subject filters).
const Filter = struct {
    rd: *store.Store,
    who: *const Who,
    query: []const u8,
    narrow: ?[]const u8,
    type: ?[]const u8 = null,
    subject: ?[]const u8 = null,

    fn keep(ptr: *anyopaque, a: std.mem.Allocator, rows: []const R.recall.RowIn) anyerror![]bool {
        const f: *Filter = @ptrCast(@alignCast(ptr));
        const in = try a.alloc(hh.house.Row, rows.len);
        for (rows, in) |r, *x| x.* = .{ .id = r.id, .scope = r.scope, .subject = r.subject, .type = r.type, .text = r.text };
        const house: hh.House = .{ .st = f.rd };
        const g = try house.gate(a, f.who.L, f.who.actor, f.query, in, f.narrow);
        const out = try a.alloc(bool, rows.len);
        for (rows, out) |r, *o| {
            o.* = false;
            if (!f.who.mayRead(r.scope)) continue; // defense in depth: the SQL scope filter already did this
            if (f.type) |t| if (!std.mem.eql(u8, t, r.type)) continue;
            if (f.subject) |s| if (!std.mem.eql(u8, s, r.subject)) continue;
            for (g.rows) |k| if (k.id == r.id) {
                o.* = true;
                break;
            };
        }
        return out;
    }

    fn rowFilter(f: *Filter) R.recall.RowFilter {
        return .{ .ptr = f, .keep = keep };
    }
};

pub const AtomQuery = struct {
    text: []const u8,
    /// The search set (already ⊆ who.read).
    scopes: []const []const u8,
    narrow: ?[]const u8 = null,
    limit: u32 = 5,
    type: ?[]const u8 = null,
    subject: ?[]const u8 = null,
};

/// The subject allow-list for recall: when the household resolver finds exactly one member that the question NAMES
/// (not just the asker by default), that member + "household" (it tells the two Taylors apart, which a name-only
/// filter cannot); otherwise null = phase 3's own name-based narrowing.
fn subjectsFor(a: std.mem.Allocator, who: *const Who, query: []const u8, narrow: ?[]const u8) !?[]const []const u8 {
    const tg = hh.resolve.targetOr(who.L.reg, who.L.rel, who.actor, query, narrow);
    const p = switch (tg) {
        .person => |x| x,
        .many, .none => return null,
    };
    if (!hh.resolve.named(who.L.reg, query).has(who.L.reg, p)) return null;
    const out = try a.alloc([]const u8, 2);
    out[0] = p;
    out[1] = "household";
    return out;
}

/// Search routes: hybrid candidates → household row gate → phase-3 gates → fused order, ≤ limit.
pub fn atoms(e: *Engine, a: std.mem.Allocator, rd: *store.Store, slot: usize, who: *const Who, q: AtomQuery) ![]Hit {
    if (q.scopes.len == 0) return &.{};
    if (q.scopes.len > store.Scope.max) return error.TooManyScopes;
    var c = e.ctx(slot, rd);
    var f: Filter = .{ .rd = rd, .who = who, .query = q.text, .narrow = q.narrow, .type = q.type, .subject = q.subject };
    const filtered = q.type != null or q.subject != null;
    const k_each: u32 = if (filtered) @max(40, @min(q.limit * 8, 160)) else @max(40, q.limit * 2);
    const r = try R.recall.recall(&c, a, q.text, .{ .scope = .{ .names = q.scopes }, .list = true, .keep = q.limit, .k_each = k_each, .rerank_n = k_each, .row_filter = f.rowFilter(), .subjects = try subjectsFor(a, who, q.text, q.narrow) });
    const out = try a.alloc(Hit, r.list.len);
    for (r.list, out) |x, *h| h.* = .{ .kind = .atoms, .id = x.id, .scope = x.scope, .subject = x.subject, .type = x.type, .text = x.text, .score = x.score, .valid_from = x.date };
    return out;
}

pub const Recalled = struct { block: []const u8, ids: []const i64, rows: usize, rerank: []const u8 };

/// /recall: the full phase-3 path (rerank, floors, keep, fact-fill, dedup, the escaped block, firewall, strict stamp)
/// over the household-gated candidates.
pub fn recallBlock(e: *Engine, a: std.mem.Allocator, rd: *store.Store, slot: usize, who: *const Who, text: []const u8, scopes: []const []const u8, narrow: ?[]const u8, keep: usize) !Recalled {
    if (scopes.len == 0) return .{ .block = "", .ids = &.{}, .rows = 0, .rerank = "off" };
    var c = e.ctx(slot, rd);
    var f: Filter = .{ .rd = rd, .who = who, .query = text, .narrow = narrow };
    const r = try R.recall.recall(&c, a, text, .{ .scope = .{ .names = scopes }, .keep = keep, .min_rerank = e.cfg.min_rerank, .row_filter = f.rowFilter(), .subjects = try subjectsFor(a, who, text, narrow) });
    return .{ .block = r.block, .ids = r.ids, .rows = r.rows, .rerank = @tagName(r.used) };
}

/// One row's served text: the phase-3 per-row gates (firewall, strict stamp, escape). Null = a `<private>` tag survived.
pub fn serveText(e: *Engine, a: std.mem.Allocator, slot: usize, text: []const u8, escape: bool) !?[]const u8 {
    if (privacy.private.hasOpen(text, true)) return null;
    const s = &e.slots[slot];
    const t1 = try privacy.ledger.scrub(&s.gates, a, text);
    const t2 = try privacy.strict.stamp(&s.gates, a, t1);
    return if (escape) try s.esc.row(a, t2, null) else t2;
}

/// A row reached by id or listing (get, list, supersede/demote targets, panel): the household gate with the row's own
/// subject as the target (the question is "about" that row) — but only when that subject is a household member; a
/// row about nobody known ("User", an outsider) is judged as a question about the asker — then the phase-3 medical
/// gate on its text.
pub fn gateOne(e: *Engine, a: std.mem.Allocator, rd: *store.Store, slot: usize, who: *const Who, row: hh.house.Row, query: []const u8, narrow_hint: ?[]const u8) !bool {
    if (!who.mayRead(row.scope)) return false;
    if (privacy.private.hasOpen(row.text, true)) return false;
    const narrow: ?[]const u8 = if (narrow_hint) |x| (if (who.L.reg.member(x) != null) x else null) else null;
    const house: hh.House = .{ .st = rd };
    const g = try house.gate(a, who.L, who.actor, query, &.{row}, narrow);
    if (g.rows.len != 1) return false;
    const s = &e.slots[slot];
    const med = try privacy.medscope.gate(&s.gates, a, &.{.{ .text = row.text, .subject = row.subject }}, query, .enforce, true);
    return med.rows.len == 1;
}

/// One conversation turn reached directly (panel: an atom's source turn, the queue) — by-row semantics like gateOne:
/// readable scope, then the household gate with the turn's OWNER as both its subject and the question's target (when
/// the owner is a member), then the phase-3 medical gate on its text.
pub fn gateTurn(e: *Engine, a: std.mem.Allocator, rd: *store.Store, slot: usize, who: *const Who, scope_name: []const u8, text: []const u8) !bool {
    if (!who.mayRead(scope_name)) return false;
    if (privacy.private.hasOpen(text, true)) return false;
    const owner = try a.dupe(u8, access.turnOwner(who.L, scope_name) orelse return false);
    const query = "";
    const narrow: ?[]const u8 = if (who.L.reg.member(owner) != null) owner else null;
    const house: hh.House = .{ .st = rd };
    const g = try house.gate(a, who.L, who.actor, query, &.{.{ .id = -1, .scope = scope_name, .subject = owner, .text = text }}, narrow);
    if (g.rows.len != 1) return false;
    const s = &e.slots[slot];
    const med = try privacy.medscope.gate(&s.gates, a, &.{.{ .text = text, .subject = owner }}, query, .enforce, true);
    return med.rows.len == 1;
}

pub const TurnQuery = struct {
    text: []const u8,
    scopes: []const []const u8,
    narrow: ?[]const u8 = null,
    limit: u32 = 5,
    session: ?[]const u8 = null,
    since_ms: ?i64 = null,
    until_ms: ?i64 = null,
};

fn scopeOfTurns(a: std.mem.Allocator, rd: *store.Store, ids: []const i64) !std.AutoHashMapUnmanaged(i64, []const u8) {
    var m: std.AutoHashMapUnmanaged(i64, []const u8) = .empty;
    if (ids.len == 0) return m;
    var sql: std.ArrayList(u8) = .empty;
    try sql.appendSlice(a, "SELECT id, scope FROM l0 WHERE id IN (");
    for (ids, 0..) |id, i| try sql.print(a, "{s}{d}", .{ if (i == 0) "" else ",", id });
    try sql.appendSlice(a, ")");
    var s = try rd.db.prepare(sql.items);
    defer s.deinit();
    while (try s.step()) try m.put(a, s.int(0), try a.dupe(u8, s.text(1)));
    return m;
}

/// Conversation search: store BM25 over L0 in the search set → owner-based household gate → phase-3 gates.
pub fn turns(e: *Engine, a: std.mem.Allocator, rd: *store.Store, slot: usize, who: *const Who, q: TurnQuery) ![]Hit {
    if (q.scopes.len == 0) return &.{};
    const fetch: u32 = @min(@max(q.limit * 8, 40), 200);
    const hits = try store.l0.search(rd, a, .{ .names = q.scopes }, q.text, .{ .limit = fetch, .since_ms = q.since_ms, .until_ms = q.until_ms });
    var ids: std.ArrayList(i64) = .empty;
    for (hits) |x| try ids.append(a, x.id);
    const scopes = try scopeOfTurns(a, rd, ids.items);
    // candidate rows for the household gate; ids are negative so no atom tag can ever be read for a turn
    var rows: std.ArrayList(hh.house.Row) = .empty;
    var src: std.ArrayList(usize) = .empty;
    for (hits, 0..) |x, i| {
        if (q.session) |s| if (!std.mem.eql(u8, s, x.session_id)) continue;
        const sc = scopes.get(x.id) orelse continue;
        if (!who.mayRead(sc)) continue;
        const owner = access.turnOwner(who.L, sc) orelse continue;
        if (privacy.private.hasOpen(x.text, true)) continue;
        // owner duplicated per row: the medical gate below matches rows by subject pointer
        try rows.append(a, .{ .id = -@as(i64, @intCast(i + 1)), .scope = sc, .subject = try a.dupe(u8, owner), .text = x.text });
        try src.append(a, i);
    }
    const house: hh.House = .{ .st = rd };
    const g = try house.gate(a, who.L, who.actor, q.text, rows.items, q.narrow);
    // phase-3 medical person-scope gate on the kept turns (text + owner column)
    const s = &e.slots[slot];
    const med_in = try a.alloc(privacy.medscope.Row, g.rows.len);
    for (g.rows, med_in) |r, *m| m.* = .{ .text = r.text, .subject = r.subject };
    const med = try privacy.medscope.gate(&s.gates, a, med_in, q.text, .enforce, true);
    var out: std.ArrayList(Hit) = .empty;
    var j: usize = 0;
    for (g.rows) |r| {
        if (out.items.len >= q.limit) break;
        if (j >= med.rows.len or med.rows[j].subject == null or med.rows[j].subject.?.ptr != r.subject.ptr) continue;
        const text = med.rows[j].text;
        j += 1;
        const i: usize = @intCast(-r.id - 1);
        const x = hits[i];
        const served = (try serveText(e, a, slot, text, true)) orelse continue;
        try out.append(a, .{ .kind = .turns, .id = x.id, .scope = r.scope, .role = x.role, .session = x.session_id, .text = served, .score = -x.score, .ts_ms = x.ts_ms });
    }
    return out.items;
}
