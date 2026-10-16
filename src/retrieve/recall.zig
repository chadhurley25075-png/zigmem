//! Scope- and subject-filtered hybrid recall: FTS5/bm25 ∥ flat nomic vectors → RRF (k=60) → per-engine minimum + fused floor
//! (every path) → medical person-scope gate (text + subject column) → optional rerank (the LAN reranker → the dev box) → dedup, source cap
//! → escape every row → render ≤ budget → window firewall (ledger_scrub). Reranker down: ≤ 2 rows, both engines must agree.
const std = @import("std");
const store = @import("store");
const privacy = @import("privacy");
const rrf = @import("rrf.zig");
const Embedder = @import("embed.zig").Embedder;
const rerank = @import("rerank.zig");
const util = @import("util.zig");
const Store = store.Store;
const Scope = store.Scope;
const Cand = rrf.Cand;

pub const Options = struct {
    scope: Scope,
    k_each: u32 = 40,
    rerank_n: usize = 24,
    keep: usize = 4,
    /// Reranker down: at most this many rows, and only rows both engines found.
    keep_down: usize = 2,
    min_rerank: f32 = 0.30,
    /// Per-engine minimum: a vector-only candidate needs this cosine (nomic query↔document scale).
    min_cos: f32 = 0.45,
    /// Floor on the normalised fused score (see rrf.zig), applied before any rerank.
    min_fused: f64 = 0.30,
    min_cos_down: f32 = 0.60,
    min_fused_down: f64 = 0.60,
    /// Query names exactly one family member → only rows whose subject is that person or `household`.
    subject_filter: bool = true,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
    date_boost: f32 = 0.25,
    budget: usize = 3000,
    rerank_chars: usize = 700,
    src_cap: usize = 3,
    src_cap_min: f32 = 0.85,
    dedup: f64 = 0.6,
    marker: ?[]const u8 = null,
    ledger_first: bool = false,
    /// blend_rerank's HS4 fact-fill: up to N more short fact rows (judge ≥ fill_min, ≤ 400 chars, newest first, no ledger-dead
    /// figure, no near-duplicate) into leftover budget. Only on the judged path.
    fact_fill: usize = 4,
    fill_min: f32 = 0.95,
    fill_src: []const u8 = "import:fact",
    /// zigmem's second stamping pass after the firewall (privacy/strict.zig). Off = exactly the live lane's gates.
    strict_stamp: bool = true,
    /// Integration: an extra per-row gate run on every loaded candidate BEFORE the medical gate and any rerank (the
    /// hub's household row gate). A row it does not keep is never scored, rendered or returned.
    row_filter: ?RowFilter = null,
    /// Integration: the subject allow-list when the caller resolved the question's person itself (the household
    /// resolver knows aliases and the two Taylors; the name-only default does not). Null = the default below.
    subjects: ?[]const []const u8 = null,
    /// Integration: list mode (search routes) — no rerank; the gated candidates in fused order, at most `keep`, each
    /// row text through the window firewall + strict stamp + escape (`Result.list`). The block is left empty.
    list: bool = false,
};

/// One loaded candidate as the row filter sees it.
pub const RowIn = struct { id: i64, scope: []const u8, subject: []const u8, type: []const u8, text: []const u8 };

pub const RowFilter = struct {
    ptr: *anyopaque,
    /// One bool per row: true = keep. Must fail closed (an error drops every row: recall returns the error).
    keep: *const fn (ptr: *anyopaque, a: std.mem.Allocator, rows: []const RowIn) anyerror![]bool,
};

/// A list-mode row: gated, firewalled, stamped and escaped text.
pub const Listed = struct { id: i64, scope: []const u8, subject: []const u8, type: []const u8, text: []const u8, score: f64, date: ?[]const u8 };

pub const Ctx = struct {
    st: *Store,
    index: ?*const store.vec.Index,
    /// Held while the index is read: the hub's worker appends live vectors under the same lock (null = static index).
    index_mu: ?*std.Io.Mutex = null,
    gates: *privacy.Gates,
    esc: *const privacy.escape.Escaper,
    util: *const util.Util,
    embedder: ?Embedder,
    reranker: rerank.Reranker,
    /// Offline tests only: use this query vector instead of calling the embedder.
    qvec_override: ?[]const f32 = null,
};

pub const Result = struct {
    block: []u8,
    rows: usize,
    cands: usize,
    used: rerank.Used,
    dropped_medical: usize,
    embed_ok: bool,
    ids: []i64,
    /// List mode only.
    list: []Listed = &.{},
    /// Rows the row filter withheld.
    dropped_filter: usize = 0,
};

const Row = struct { c: Cand, subject: []const u8, text: []const u8, date: ?[]const u8, cite: []const u8, src: []const u8, score: ?f32 = null, fill: bool = false, scope: []const u8 = "", type: []const u8 = "" };

fn bindStrs(s: store.sqlite.Stmt, first: usize, xs: []const []const u8) !void {
    for (xs, 0..) |x, i| try s.bind(@intCast(first + i), x);
}

/// Shared WHERE tail: active, scope, subject allow-list, date window. Parameters numbered from `first`.
fn filters(a: std.mem.Allocator, sql: *std.ArrayList(u8), o: Options, subjects: []const []const u8, first: usize) !usize {
    var n = first;
    try sql.appendSlice(a, " AND a.status = 'active' AND ");
    try o.scope.sqlIn(a, sql, "a.scope", n);
    n += o.scope.names.len;
    if (subjects.len > 0) {
        try sql.appendSlice(a, " AND a.subject IN (");
        for (subjects, 0..) |_, i| try sql.print(a, "{s}?{d}", .{ if (i == 0) "" else ",", n + i });
        try sql.appendSlice(a, ")");
        n += subjects.len;
    }
    if (o.since != null and o.until != null) {
        try sql.print(a, " AND a.valid_from IS NOT NULL AND substr(a.valid_from,1,10) BETWEEN ?{d} AND ?{d}", .{ n, n + 1 });
        n += 2;
    }
    return n;
}

fn bindFilters(s: store.sqlite.Stmt, o: Options, subjects: []const []const u8, first: usize) !void {
    try o.scope.bind(s, first);
    var n = first + o.scope.names.len;
    try bindStrs(s, n, subjects);
    n += subjects.len;
    if (o.since != null and o.until != null) {
        try s.bind(@intCast(n), o.since.?);
        try s.bind(@intCast(n + 1), o.until.?);
    }
}

fn ftsCands(ctx: *Ctx, a: std.mem.Allocator, o: Options, q: []const u8, subjects: []const []const u8, out: *std.AutoArrayHashMapUnmanaged(i64, Cand)) !void {
    const cleaned = try ctx.util.ftsText(a, q);
    const plan = (try store.ftsPlan(ctx.st, a, "atoms_fts", "atoms", cleaned)) orelse return;
    var sql: std.ArrayList(u8) = .empty;
    try sql.appendSlice(a, "SELECT a.id, bm25(atoms_fts) AS r, a.priority FROM atoms_fts JOIN atoms a ON a.id = atoms_fts.rowid WHERE atoms_fts MATCH ?1");
    _ = try filters(a, &sql, o, subjects, 3);
    try sql.appendSlice(a, if (plan.capped) " ORDER BY atoms_fts.rowid DESC LIMIT ?2" else " ORDER BY r LIMIT ?2");
    var s = try ctx.st.db.prepare(sql.items);
    defer s.deinit();
    try s.bind(1, plan.match);
    try s.bind(2, @as(i64, o.k_each));
    try bindFilters(s, o, subjects, 3);
    var rank: u32 = 0;
    while (try s.step()) {
        rank += 1;
        const mag = @max(0.0, -s.float(1));
        const gop = try out.getOrPut(a, s.int(0));
        if (!gop.found_existing) gop.value_ptr.* = .{ .id = s.int(0) };
        gop.value_ptr.fts_rank = rank;
        gop.value_ptr.bm25n = mag / (1.0 + mag);
        gop.value_ptr.priority = s.int(2);
    }
}

fn vecCands(ctx: *Ctx, a: std.mem.Allocator, o: Options, qv: []const f32, subjects: []const []const u8, out: *std.AutoArrayHashMapUnmanaged(i64, Cand)) !void {
    const ix = ctx.index orelse return;
    if (ctx.index_mu) |m| m.lockUncancelable(ctx.st.io);
    defer if (ctx.index_mu) |m| m.unlock(ctx.st.io);
    const hits = try ix.topK(a, o.scope, qv, o.k_each * 4);
    if (hits.len == 0) return;
    var sql: std.ArrayList(u8) = .empty;
    try sql.appendSlice(a, "SELECT a.id, a.priority FROM atoms a WHERE a.id IN (");
    for (hits, 0..) |h, i| try sql.print(a, "{s}{d}", .{ if (i == 0) "" else ",", h.row_id });
    try sql.appendSlice(a, ")");
    _ = try filters(a, &sql, o, subjects, 1);
    var s = try ctx.st.db.prepare(sql.items);
    defer s.deinit();
    try bindFilters(s, o, subjects, 1);
    var ok: std.AutoHashMapUnmanaged(i64, i64) = .empty;
    while (try s.step()) try ok.put(a, s.int(0), s.int(1));
    var rank: u32 = 0;
    for (hits) |h| {
        const prio = ok.get(h.row_id) orelse continue;
        rank += 1;
        if (rank > o.k_each) break;
        const gop = try out.getOrPut(a, h.row_id);
        if (!gop.found_existing) gop.value_ptr.* = .{ .id = h.row_id };
        gop.value_ptr.vec_rank = rank;
        gop.value_ptr.cos = h.score;
        gop.value_ptr.priority = prio;
    }
}

fn indexCount(ctx: *Ctx) usize {
    const ix = ctx.index orelse return 0;
    if (ctx.index_mu) |m| m.lockUncancelable(ctx.st.io);
    defer if (ctx.index_mu) |m| m.unlock(ctx.st.io);
    return ix.ids.items.len;
}

fn loadRow(ctx: *Ctx, a: std.mem.Allocator, c: Cand) !?Row {
    var s = try ctx.st.db.prepare("SELECT subject, text, valid_from, coalesce(src_l0, ''), coalesce(extractor, ''), scope, type FROM atoms WHERE id = ?1");
    defer s.deinit();
    try s.bind(1, c.id);
    if (!try s.step()) return null;
    return .{
        .c = c,
        .subject = try a.dupe(u8, s.text(0)),
        .text = try a.dupe(u8, s.text(1)),
        .date = if (s.isNull(2)) null else try a.dupe(u8, s.text(2)),
        .cite = try a.dupe(u8, s.text(3)),
        .src = try a.dupe(u8, s.text(4)),
        .scope = try a.dupe(u8, s.text(5)),
        .type = try a.dupe(u8, s.text(6)),
    };
}

/// Recall for one query. Everything allocated in `a` (use an arena per call).
pub fn recall(ctx: *Ctx, a: std.mem.Allocator, query: []const u8, o: Options) !Result {
    try o.scope.check();
    const qt = try privacy.re.Text.init(a, query);
    const named = privacy.medscope.named(ctx.gates, qt);
    var subj_buf: [2][]const u8 = undefined;
    var subjects: []const []const u8 = &.{};
    if (o.subjects) |s| {
        subjects = s;
    } else if (o.subject_filter and named.count() == 1) {
        subj_buf = .{ privacy.medscope.nameOf(named.first().?), "household" };
        subjects = &subj_buf;
    }
    var cands: std.AutoArrayHashMapUnmanaged(i64, Cand) = .empty;
    try ftsCands(ctx, a, o, query, subjects, &cands);
    var embed_ok = false;
    if (ctx.qvec_override) |qv| {
        embed_ok = true;
        try vecCands(ctx, a, o, qv, subjects, &cands);
    } else if (ctx.embedder != null and indexCount(ctx) > 0) blk: {
        // no vectors in this store → no query embedding (nothing to compare it with)
        const e = ctx.embedder.?;
        const qtext = try std.fmt.allocPrint(a, "search_query: {s}", .{query});
        const vs = e.embed(a, &.{qtext}) catch break :blk;
        embed_ok = true;
        try vecCands(ctx, a, o, vs[0], subjects, &cands);
    }
    // per-engine minimum + fused floor (every path)
    var pool: std.ArrayList(Cand) = .empty;
    for (cands.values()) |*c| {
        const vec_ok = c.vec_rank != null and c.cos >= o.min_cos;
        if (!(c.fts_rank != null or vec_ok)) continue;
        c.fused = rrf.withPriority(rrf.fusedOf(c.*), c.priority);
        if (c.fused < o.min_fused) continue;
        try pool.append(a, c.*);
    }
    std.mem.sort(Cand, pool.items, {}, rrf.byFusedDesc);
    const top = pool.items[0..@min(pool.items.len, o.rerank_n)];
    // list mode: the same gates, applied lazily in fused order, chunk by chunk, until `keep` rows survive (every
    // per-row decision is independent of the other rows, so the survivors are exactly the first `keep` of the full pass)
    if (o.list) return listMode(ctx, a, query, top, o, embed_ok);
    const g = try gateChunk(ctx, a, query, top, o);
    const gated = g.rows;
    const med_dropped = g.dropped_medical;
    const dropped_filter = g.dropped_filter;
    const win = try ctx.util.dateWindow(a, query, ctx.gates.today);
    var used: rerank.Used = .off;
    var picked: std.ArrayList(Row) = .empty;
    if (gated.items.len > 0) {
        const docs = try a.alloc([]const u8, gated.items.len);
        for (gated.items, 0..) |r, i| docs[i] = try ctx.util.focus(a, query, r.text, o.rerank_chars);
        const res = try ctx.reranker.score(a, query, docs);
        used = res.used;
        if (res.scores) |sc| {
            for (gated.items, sc) |*r, s| {
                var v = s;
                if (win) |w| if (r.date) |d| if (d.len >= 10 and std.mem.order(u8, d[0..10], &w[0]) != .lt and std.mem.order(u8, d[0..10], &w[1]) != .gt) {
                    v = @min(1.0, v + o.date_boost);
                };
                r.score = v;
            }
            std.mem.sort(Row, gated.items, {}, struct {
                fn lt(_: void, x: Row, y: Row) bool {
                    return x.score.? > y.score.?;
                }
            }.lt);
            var ok: std.ArrayList(Row) = .empty;
            for (gated.items) |r| {
                if (r.score.? < o.min_rerank) continue;
                if (o.dedup > 0) {
                    var dup = false;
                    for (ok.items) |k| if (try ctx.util.nearDup(a, r.text, k.text, o.dedup)) {
                        dup = true;
                        break;
                    };
                    if (dup) continue;
                }
                try ok.append(a, r);
            }
            for (ok.items, 0..) |r, i| {
                if (picked.items.len >= o.keep) break;
                var n_src: usize = 0;
                for (picked.items) |p| if (std.mem.eql(u8, p.src, r.src)) {
                    n_src += 1;
                };
                if (n_src >= o.src_cap) {
                    var alt = false;
                    for (ok.items[i + 1 ..]) |x| if (!std.mem.eql(u8, x.src, r.src) and x.score.? >= o.src_cap_min) {
                        alt = true;
                    };
                    if (alt) continue;
                }
                try picked.append(a, r);
            }
            if (o.fact_fill > 0 and picked.items.len > 0) try factFill(ctx, a, &picked, ok.items, o);
        } else {
            // lower-injection path: no judge → only rows BOTH engines found, strong cosine, high fused rank; ≤ keep_down
            for (gated.items) |r| {
                if (picked.items.len >= o.keep_down) break;
                if (r.c.fts_rank == null or r.c.vec_rank == null) continue;
                if (r.c.cos < o.min_cos_down or r.c.fused < o.min_fused_down) continue;
                try picked.append(a, r);
            }
        }
    }
    const block = try render(ctx, a, query, picked.items, gated.items.len, used, o);
    const ids = try a.alloc(i64, picked.items.len);
    for (picked.items, 0..) |r, i| ids[i] = r.c.id;
    return .{ .block = block, .rows = picked.items.len, .cands = gated.items.len, .used = used, .dropped_medical = med_dropped, .embed_ok = embed_ok, .ids = ids, .dropped_filter = dropped_filter };
}

const Gated = struct { rows: std.ArrayList(Row), dropped_filter: usize, dropped_medical: usize };

/// Load + gate candidates: `<private>` survivors dropped, the caller's row filter (household), the medical person-scope
/// gate (text rule + subject column). Order kept.
fn gateChunk(ctx: *Ctx, a: std.mem.Allocator, query: []const u8, cands: []const Cand, o: Options) !Gated {
    var loaded: std.ArrayList(Row) = .empty;
    for (cands) |c| if (try loadRow(ctx, a, c)) |r| {
        if (privacy.private.hasOpen(r.text, true)) continue; // stripped at write; never serve a tag that survived
        try loaded.append(a, r);
    };
    var rows: std.ArrayList(Row) = .empty;
    var dropped_filter: usize = 0;
    if (o.row_filter) |f| {
        const ins = try a.alloc(RowIn, loaded.items.len);
        for (loaded.items, ins) |r, *x| x.* = .{ .id = r.c.id, .scope = r.scope, .subject = r.subject, .type = r.type, .text = r.text };
        const keep = try f.keep(f.ptr, a, ins);
        if (keep.len != ins.len) return error.RowFilterMismatch;
        for (loaded.items, keep) |r, k| {
            if (k) try rows.append(a, r) else dropped_filter += 1;
        }
    } else rows = loaded;
    // medical person-scope gate: the Python text rule + the subject column
    var med_in = try a.alloc(privacy.medscope.Row, rows.items.len);
    for (rows.items, 0..) |r, i| med_in[i] = .{ .text = r.text, .subject = r.subject };
    const med = try privacy.medscope.gate(ctx.gates, a, med_in, query, .enforce, true);
    var gated: std.ArrayList(Row) = .empty;
    var j: usize = 0;
    for (rows.items) |r| {
        if (j < med.rows.len and med.rows[j].subject != null and med.rows[j].subject.?.ptr == r.subject.ptr) {
            var r2 = r;
            r2.text = med.rows[j].text;
            try gated.append(a, r2);
            j += 1;
        }
    }
    return .{ .rows = gated, .dropped_filter = dropped_filter, .dropped_medical = med.dropped };
}

/// List mode (search routes): fused order, <= keep rows, every text through the window firewall, the strict stamp and
/// the escaper — the same per-row gates the block gets, applied row by row. No rerank.
fn listMode(ctx: *Ctx, a: std.mem.Allocator, query: []const u8, top: []const Cand, o: Options, embed_ok: bool) !Result {
    var out: std.ArrayList(Listed) = .empty;
    var dropped_filter: usize = 0;
    var dropped_medical: usize = 0;
    var seen: usize = 0;
    const step = @max(o.keep + o.keep / 2, 6);
    var i: usize = 0;
    while (i < top.len and out.items.len < o.keep) {
        const chunk = top[i..@min(top.len, i + step)];
        i += chunk.len;
        const g = try gateChunk(ctx, a, query, chunk, o);
        dropped_filter += g.dropped_filter;
        dropped_medical += g.dropped_medical;
        seen += g.rows.items.len;
        for (g.rows.items) |r| {
            if (out.items.len >= o.keep) break;
            const t1 = try privacy.ledger.scrub(ctx.gates, a, r.text);
            const t2 = if (o.strict_stamp) try privacy.strict.stamp(ctx.gates, a, t1) else t1;
            const t3 = try ctx.esc.row(a, t2, o.marker);
            try out.append(a, .{ .id = r.c.id, .scope = r.scope, .subject = r.subject, .type = r.type, .text = t3, .score = r.c.fused, .date = r.date });
        }
    }
    const ids = try a.alloc(i64, out.items.len);
    for (out.items, 0..) |x, k| ids[k] = x.id;
    return .{ .block = &.{}, .rows = out.items.len, .cands = seen, .used = .off, .dropped_medical = dropped_medical, .embed_ok = embed_ok, .ids = ids, .list = out.items, .dropped_filter = dropped_filter };
}

fn line(ctx: *Ctx, a: std.mem.Allocator, out: *std.ArrayList(u8), r: Row, body: []const u8, today: privacy.ledger.Date, o: Options) !void {
    const safe = try ctx.esc.row(a, body, o.marker);
    const cite = try ctx.util.aged(a, if (r.cite.len > 0) r.cite else "zigmem", today);
    if (r.score) |s| try out.print(a, "\n- [{s} · {d:.2}] {s}", .{ cite, s, safe }) else try out.print(a, "\n- [{s}] {s}", .{ cite, safe });
}

fn factFill(ctx: *Ctx, a: std.mem.Allocator, picked: *std.ArrayList(Row), ok: []const Row, o: Options) !void {
    var pool: std.ArrayList(Row) = .empty;
    for (ok) |r| {
        if (!std.mem.eql(u8, r.src, o.fill_src) or r.score.? < o.fill_min or r.text.len > 400) continue;
        var dup = false;
        for (picked.items) |p| if (p.c.id == r.c.id) {
            dup = true;
        };
        if (!dup) try pool.append(a, r);
    }
    std.mem.sort(Row, pool.items, {}, struct {
        fn lt(_: void, x: Row, y: Row) bool {
            return std.mem.order(u8, x.date orelse "", y.date orelse "") == .gt;
        }
    }.lt);
    var added: usize = 0;
    for (pool.items) |r| {
        if (added >= o.fact_fill) break;
        if (try privacy.strict.fillReject(ctx.gates, a, r.text)) continue;
        var near = false;
        for (picked.items) |p| if (std.mem.eql(u8, p.src, o.fill_src) and try ctx.util.nearDup(a, r.text, p.text, if (o.dedup > 0) o.dedup else 0.6)) {
            near = true;
            break;
        };
        if (near) continue;
        var f = r;
        f.fill = true;
        try picked.append(a, f);
        added += 1;
    }
}

fn render(ctx: *Ctx, a: std.mem.Allocator, query: []const u8, rows: []const Row, ncands: usize, used: rerank.Used, o: Options) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    if (o.ledger_first) {
        const ll = try privacy.ledger.lines(ctx.gates, a, query);
        try out.appendSlice(a, ll);
    }
    if (rows.len == 0) {
        if (out.items.len == 0) return out.items;
        return privacy.ledger.scrub(ctx.gates, a, out.items);
    }
    var b: [10]u8 = undefined;
    const today = ctx.gates.today;
    const judge = switch (used) {
        .primary, .fallback => "judged by reranker",
        else => "fused rank only — reranker down",
    };
    try out.print(a, "--- ZIGMEM (best {d} of {d} · {s} · today {s} {s}) ---", .{ rows.len, ncands, judge, today.iso(&b), privacy.pat.wdn[today.weekday()][0..3] });
    const head_len = out.items.len;
    var n_main: usize = 0;
    for (rows) |r| n_main += @intFromBool(!r.fill);
    const per = @max(250, (o.budget -| head_len) / @max(1, n_main) -| 60);
    for (rows) |r| {
        if (r.fill) continue;
        const body = if (try ctx.util.cpLen(r.text) <= per) r.text else try std.fmt.allocPrint(a, "{s}…", .{try ctx.util.focus(a, query, r.text, per)});
        try line(ctx, a, &out, r, body, today, o);
    }
    // fact-fill rows: whole, only into leftover budget (blend_rerank HS4)
    for (rows) |r| {
        if (!r.fill) continue;
        var tmp: std.ArrayList(u8) = .empty;
        try line(ctx, a, &tmp, r, r.text, today, o);
        if (out.items.len + tmp.items.len > o.budget) continue;
        try out.appendSlice(a, tmp.items);
    }
    const capped = out.items[0..ctx.util.capBytes(out.items, o.budget + 200)];
    const scrubbed = try privacy.ledger.scrub(ctx.gates, a, capped);
    return if (o.strict_stamp) privacy.strict.stamp(ctx.gates, a, scrubbed) else scrubbed;
}
