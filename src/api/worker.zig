//! Background work. ≤ 2 threads claim `extract` jobs from the persistent queue (one job = one captured user turn),
//! run the phase-2 pipeline against the allowlisted engine, and write through the one writer thread. Each thread makes
//! one engine call at a time, so at most 2 requests are ever in flight to the primary engine (BOARD law 1).
//! After every job the new atoms are embedded (one batched call to the configured embedder, bounded by its leash)
//! and join the live vector index; an atom whose embedding failed is picked up by the idle sweep.
//! Thread 0's idle path (nothing queued) also runs the reviewer (one engine call per `pending_review` atom, bounded)
//! and the L2/L3 fold on the SPEC §1.2 cadence (fold.zig).
const std = @import("std");
const linux = std.os.linux;
const store = @import("store");
const extract = @import("extract");
const hh = @import("household");
const retrieval = @import("retrieval.zig");
const fold = @import("fold.zig");
const allow = extract.allow;
const sink_mod = extract.sink;
const Writer = store.writer.Writer;

pub const max_threads = 2;

/// Embedding batches: at most this many atoms per embedder call (per job, and per idle sweep).
pub const embed_batch = 32;
/// Reviewer: at most this many pending atoms per idle tick, and no review while anything is queued.
pub const review_per_tick = 3;
/// Reviewer backoff after an engine transport failure (ms).
pub const review_backoff_ms: i64 = 60_000;
/// Idle embed sweep spacing (ms): fast while it succeeds, slow after a failure.
pub const sweep_ms: i64 = 2_000;
pub const sweep_backoff_ms: i64 = 30_000;

/// The phase-2 Sink, but every write goes through the hub's single writer thread; reads use this thread's own
/// read-only connection.
pub const WriterSink = struct {
    w: *Writer,
    rd: *store.Store,
    seat: []const u8 = "zigmem-extract",
    /// The member who spoke the turn being processed (decides which other scopes are candidates for supersession).
    speaker: []const u8 = "unknown",

    pub fn sink(s: *WriterSink) sink_mod.Sink {
        return .{ .ptr = s, .vt = &vt };
    }
    const vt: sink_mod.Sink.VTable = .{ .insert = insertFn, .supersede = supersedeFn, .demote = demoteFn, .findSimilar = findFn };

    fn toNew(s: *WriterSink, r: sink_mod.NewRow, buf: *[200]u8) store.atoms.New {
        const src = std.fmt.bufPrint(buf[0..100], "turn={d} sha={x}", .{ r.prov.turn_id, r.prov.src_turn_sha[0..16] }) catch unreachable;
        const ext = std.fmt.bufPrint(buf[100..], "{s}|{s}|p:{s}", .{ r.prov.extractor, r.prov.model, r.prov.prompt_version }) catch buf[100..100];
        return .{
            .subject = r.subject,
            .scope = r.scope,
            .type = r.type,
            .text = r.text,
            .priority = r.priority,
            .valid_from = r.valid_from,
            .status = std.meta.stringToEnum(store.atoms.Status, @tagName(r.status)).?,
            .src_l0 = src,
            .extractor = ext,
            .prompt_sha = r.prov.prompt_sha,
            .run_id = r.prov.run_id,
            .seat = s.seat,
        };
    }
    /// Writer-thread op: the household write rule on an extracted row (a medical row outside its owner's scope or
    /// about someone outside the household lands pending_review; the medical tag is recorded), then the write.
    pub fn hhWriteOp(st: *store.Store, n0: store.atoms.New, old: ?i64) !i64 {
        var arena: std.heap.ArenaAllocator = .init(st.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const house: hh.House = .{ .st = st };
        const L = try house.load(a);
        const rule = try hh.House.writeRule(a, L, .{ .scope = n0.scope, .subject = n0.subject, .type = n0.type, .text = n0.text });
        var n = n0;
        // never promote: an extractor's own pending/retired verdict stands; the rule can only make a row stricter
        if (n.status == .active) n.status = rule.status;
        const id = if (old) |o| try store.atoms.supersede(st, o, n, null) else try store.atoms.insert(st, n);
        try st.db.run("INSERT INTO hh_tags(atom_id, medical) VALUES (?1, ?2)", .{ id, rule.med });
        return id;
    }
    fn insertFn(ptr: *anyopaque, r: sink_mod.NewRow) anyerror!i64 {
        const s: *WriterSink = @ptrCast(@alignCast(ptr));
        var buf: [200]u8 = undefined;
        return s.w.call(hhWriteOp, .{ s.toNew(r, &buf), @as(?i64, null) });
    }
    fn supersedeFn(ptr: *anyopaque, old: i64, r: sink_mod.NewRow) anyerror!i64 {
        const s: *WriterSink = @ptrCast(@alignCast(ptr));
        var buf: [200]u8 = undefined;
        return s.w.call(hhWriteOp, .{ s.toNew(r, &buf), @as(?i64, old) });
    }
    fn demoteOp(st: *store.Store, id: i64, by: i64, reason: []const u8, seat: []const u8) !void {
        try store.atoms.setStatus(st, id, .retired, seat);
        var b: [400]u8 = undefined;
        const d = std.fmt.bufPrint(&b, "demoted by {d}: {s}", .{ by, reason[0..@min(reason.len, 300)] }) catch "demoted";
        try st.audit(seat, "demote", "atoms", id, d);
    }
    fn demoteFn(ptr: *anyopaque, id: i64, by: i64, reason: []const u8) anyerror!void {
        const s: *WriterSink = @ptrCast(@alignCast(ptr));
        return s.w.call(demoteOp, .{ id, by, reason, s.seat });
    }

    /// May the speaker (a household member) write `scope`? Household policy, with the speaker as the actor.
    fn speakerMayWrite(L: hh.house.Loaded, speaker: []const u8, scope: []const u8) bool {
        const m = L.reg.member(speaker) orelse return false;
        if (m.revoked) return false;
        const act: hh.policy.Actor = .{ .seat = "", .member = m.id, .role = m.role };
        return hh.policy.mayWrite(act, scope);
    }

    /// Candidates: active rows in the turn's scope, plus the subject's own atoms in `person:<subject>` when the speaker
    /// may write there (a parent about a child; never a child about a parent) — same subject only, and never a medical
    /// row from another scope (medical never crosses).
    fn findFn(ptr: *anyopaque, a: std.mem.Allocator, scope: []const u8, subject: []const u8, text: []const u8, limit: usize) anyerror![]sink_mod.Cand {
        const s: *WriterSink = @ptrCast(@alignCast(ptr));
        var names: [2][]const u8 = .{ scope, "" };
        var n: usize = 1;
        var xscope: ?[]const u8 = null;
        const house: hh.House = .{ .st = s.rd };
        const L = try house.load(a);
        if (L.reg.member(subject) != null) {
            const ps = try std.fmt.allocPrint(a, "person:{s}", .{subject});
            if (!std.mem.eql(u8, ps, scope) and speakerMayWrite(L, s.speaker, ps)) {
                names[1] = ps;
                n = 2;
                xscope = ps;
            }
        }
        const hits = try store.atoms.search(s.rd, a, .{ .names = names[0..n] }, text, .{ .limit = 20 });
        const q = try sink_mod.contentWords(a, text);
        var out: std.ArrayList(sink_mod.Cand) = .empty;
        for (hits) |h| {
            if (out.items.len >= limit) break;
            if (sink_mod.shared(q, try sink_mod.contentWords(a, h.text)) < 2) continue;
            if (xscope != null and std.mem.eql(u8, h.scope, xscope.?)) {
                if (!std.mem.eql(u8, h.subject, subject)) continue;
                if (house.isMedicalRow(h.id, h.text)) continue;
            }
            try out.append(a, .{ .id = h.id, .subject = h.subject, .text = h.text, .scope = h.scope });
        }
        return out.items;
    }
};

/// Civil date (UTC) for a unix-ms timestamp, as YYYY-MM-DD.
pub fn dateOf(buf: *[10]u8, ms: i64) []const u8 {
    const z = @divFloor(ms, 86_400_000) + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(y)), @as(u64, @intCast(m)), @as(u64, @intCast(d)) }) catch unreachable;
    return buf;
}

pub const Stats = struct {
    inflight: std.atomic.Value(u32) = .init(0),
    inflight_max: std.atomic.Value(u32) = .init(0),
    done: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(u64) = .init(0),
    connects: std.atomic.Value(u64) = .init(0),
    refused: std.atomic.Value(u64) = .init(0),
    /// atoms embedded on the live path / embedder calls that failed (the atoms wait for the sweep)
    embedded: std.atomic.Value(u64) = .init(0),
    embed_failed: std.atomic.Value(u64) = .init(0),
    /// reviewer: pending atoms re-filed with a subject / retired / engine failures
    reviewed: std.atomic.Value(u64) = .init(0),
    review_retired: std.atomic.Value(u64) = .init(0),
    review_failed: std.atomic.Value(u64) = .init(0),
    /// folds run by this process, and when the last one ran
    folds: std.atomic.Value(u64) = .init(0),
    fold_last_ms: std.atomic.Value(i64) = .init(0),
    /// new atoms (inserted, superseding, re-filed) since the last fold
    new_since_fold: std.atomic.Value(u32) = .init(0),
    /// 0 = no fold scheduled; else the time the next fold is due
    fold_due_ms: std.atomic.Value(i64) = .init(0),
};

pub const PersonOf = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, a: std.mem.Allocator, seat: []const u8) ?[]const u8,
};

pub const Worker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    db_path: [:0]const u8,
    w: *Writer,
    ep: allow.Endpoint,
    threads: u8,
    person_of: PersonOf,
    /// The hub's retrieval engine: its embedder and live vector index (null = no embedding, e.g. tests).
    eng: ?*retrieval.Engine = null,
    cadence: fold.Cadence = .{},
    stats: Stats = .{},
    stop: std.atomic.Value(bool) = .init(false),
    /// last time a job finished (the idle trigger), thread 0's sweep/review timers
    last_job_ms: std.atomic.Value(i64) = .init(0),
    folds_done: u64 = 0,
    next_sweep_ms: i64 = 0,
    next_review_ms: i64 = 0,

    pub fn start(wk: *Worker) !void {
        const n = @min(wk.threads, max_threads);
        for (0..n) |i| {
            const t = try std.Thread.spawn(.{}, loop, .{ wk, i });
            t.detach();
        }
    }

    fn sleepMs(ms: u64) void {
        var ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
        _ = linux.nanosleep(&ts, null);
    }

    fn nowMs(wk: *Worker) i64 {
        return std.Io.Timestamp.now(wk.io, .real).toMilliseconds();
    }

    /// New atoms landed: count them and schedule a fold when the warm-up / every-N threshold is reached.
    pub fn noteNewAtoms(wk: *Worker, n: u32) void {
        if (n == 0) return;
        const total = wk.stats.new_since_fold.fetchAdd(n, .acq_rel) + n;
        if (total >= wk.cadence.threshold(wk.stats.folds.load(.acquire))) wk.scheduleFold(wk.nowMs());
    }

    /// Schedule the next fold at max(now, last + l2_min): the first fold runs at once, later ones keep the L2 cadence.
    pub fn scheduleFold(wk: *Worker, now: i64) void {
        if (wk.stats.fold_due_ms.load(.acquire) != 0) return;
        const last = wk.stats.fold_last_ms.load(.acquire);
        const due = if (last == 0) now else @max(now, last + wk.cadence.l2_min_ms);
        _ = wk.stats.fold_due_ms.cmpxchgStrong(0, due, .acq_rel, .acquire);
    }

    /// A session ended (C10 "shutdown" trigger): fold what is new on the next cadence slot.
    pub fn requestFold(wk: *Worker, now: i64) void {
        if (wk.stats.new_since_fold.load(.acquire) > 0) wk.scheduleFold(now);
    }

    /// The extractor's people list: the phase-1 `people` table plus every household member (display name + aliases).
    fn loadPeople(a: std.mem.Allocator, rd: *store.Store) ![]extract.people.Person {
        var out: std.ArrayList(extract.people.Person) = .empty;
        var s = try rd.db.prepare("SELECT id, aliases FROM people UNION " ++
            "SELECT id, display || ',' || replace(aliases, '|', ',') FROM hh_members WHERE revoked_ms IS NULL AND id NOT IN (SELECT id FROM people) ORDER BY 1");
        defer s.deinit();
        while (try s.step()) {
            var al: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeScalar(u8, s.text(1), ',');
            while (it.next()) |x| try al.append(a, try a.dupe(u8, std.mem.trim(u8, x, " ")));
            try out.append(a, .{ .id = try a.dupe(u8, s.text(0)), .aliases = al.items });
        }
        return out.items;
    }

    fn loop(wk: *Worker, idx: usize) void {
        wk.run(idx) catch |e| std.debug.print("extract worker {d}: stopped: {s}\n", .{ idx, @errorName(e) });
    }

    // ---- embedding (fix 1) ----

    /// Embed these atoms (texts read from `rd`), store the vectors through the writer and add them to the live index.
    /// One embedder call, bounded by its leash; on failure nothing is written and the atoms wait for the sweep.
    fn embedAtoms(wk: *Worker, a: std.mem.Allocator, rd: *store.Store, ids: []const i64) !usize {
        const eng = wk.eng orelse return 0;
        const emb = eng.embedder orelse return 0;
        if (ids.len == 0) return 0;
        var keep: std.ArrayList(i64) = .empty;
        var scopes: std.ArrayList([]const u8) = .empty;
        var texts: std.ArrayList([]const u8) = .empty;
        for (ids) |id| {
            var s = try rd.db.prepare("SELECT scope, text FROM atoms WHERE id = ?1");
            defer s.deinit();
            try s.bind(1, id);
            if (!try s.step()) continue;
            const text = s.text(1);
            var n = @min(text.len, 6000);
            while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) n -= 1;
            try keep.append(a, id);
            try scopes.append(a, try a.dupe(u8, s.text(0)));
            try texts.append(a, try std.fmt.allocPrint(a, "search_document: {s}", .{text[0..n]}));
        }
        if (keep.items.len == 0) return 0;
        const vecs = emb.embed(a, texts.items) catch |e| {
            _ = wk.stats.embed_failed.fetchAdd(1, .monotonic);
            return e;
        };
        var done: usize = 0;
        for (keep.items, scopes.items, vecs) |id, scope, v| {
            wk.w.call(store.vec.put, .{ store.vec.Kind.atom, id, v }) catch |e| {
                // a dims mismatch means a different embedder than the store was built with: never mix, report once
                std.debug.print("zigmem: vector for atom {d} not stored: {s}\n", .{ id, @errorName(e) });
                continue;
            };
            try eng.addVector(id, scope, v);
            done += 1;
        }
        _ = wk.stats.embedded.fetchAdd(done, .monotonic);
        return done;
    }

    /// Ids of the rows a pipeline run wrote (insert / supersede / correct), in order.
    fn writtenIds(a: std.mem.Allocator, log: *const extract.pipeline.TurnLog) ![]i64 {
        var out: std.ArrayList(i64) = .empty;
        for (log.applied.items) |x| if (x.id) |id| {
            if (std.mem.eql(u8, x.action, "insert") or std.mem.eql(u8, x.action, "supersede") or std.mem.eql(u8, x.action, "correct")) try out.append(a, id);
        };
        return out.items;
    }

    /// Idle sweep: active atoms without a vector (an earlier embed failure, a store built before `--embed-url`, rows
    /// added by hand through the API), one batch per tick.
    fn embedSweep(wk: *Worker, a: std.mem.Allocator, rd: *store.Store, now: i64) void {
        if (wk.eng == null or wk.eng.?.embedder == null or now < wk.next_sweep_ms) return;
        var ids: std.ArrayList(i64) = .empty;
        {
            var s = rd.db.prepare("SELECT a.id FROM atoms a LEFT JOIN vec v ON v.kind = 'atom' AND v.row_id = a.id " ++
                "WHERE a.status = 'active' AND v.row_id IS NULL ORDER BY a.id LIMIT ?1") catch return;
            defer s.deinit();
            s.bind(1, @as(i64, embed_batch)) catch return;
            while (s.step() catch false) ids.append(a, s.int(0)) catch return;
        }
        if (ids.items.len == 0) {
            wk.next_sweep_ms = now + sweep_ms;
            return;
        }
        const n = wk.embedAtoms(a, rd, ids.items) catch 0;
        wk.next_sweep_ms = now + (if (n > 0) sweep_ms else sweep_backoff_ms);
    }

    // ---- the reviewer (fix 5) ----

    const Pending = struct { id: i64, subject: []const u8, scope: []const u8, type: []const u8, text: []const u8, priority: i64, valid_from: ?[]const u8, src_l0: ?[]const u8, turn_id: i64 = 0, turn_text: []const u8, speaker: []const u8 };

    /// Writer-thread op: close a reviewed pending row — retired, with an audit row saying what became of it (the
    /// re-filed row, if any, was written by the pipeline's own path just before).
    fn reviewCloseOp(st: *store.Store, id: i64, detail: []const u8) !void {
        const seat = "zigmem-review";
        try store.atoms.setStatus(st, id, .retired, seat);
        try st.audit(seat, "review", "atoms", id, detail[0..@min(detail.len, 200)]);
    }

    /// Writer-thread op: mark the rows a review re-filed, so they are never reviewed again if the write rule parked
    /// them pending (a medical-looking household row, say).
    fn reviewMarkOp(st: *store.Store, ids: []const i64, from: i64) !void {
        var b: [64]u8 = undefined;
        for (ids) |id| try st.audit("zigmem-review", "review", "atoms", id, try std.fmt.bufPrint(&b, "re-filed from {d}", .{from}));
    }

    /// Pending atoms nobody has reviewed yet (no `review` audit row), oldest first.
    fn loadPending(wk: *Worker, a: std.mem.Allocator, rd: *store.Store) ![]Pending {
        var out: std.ArrayList(Pending) = .empty;
        var s = try rd.db.prepare("SELECT id, subject, scope, type, text, priority, valid_from, src_l0 FROM atoms WHERE status = 'pending_review' " ++
            "AND id NOT IN (SELECT row_id FROM audit WHERE table_name = 'atoms' AND action = 'review' AND row_id IS NOT NULL) ORDER BY id LIMIT ?1");
        defer s.deinit();
        try s.bind(1, @as(i64, review_per_tick));
        while (try s.step()) {
            var p: Pending = .{ .id = s.int(0), .subject = try a.dupe(u8, s.text(1)), .scope = try a.dupe(u8, s.text(2)), .type = try a.dupe(u8, s.text(3)), .text = try a.dupe(u8, s.text(4)), .priority = s.int(5), .valid_from = if (s.isNull(6)) null else try a.dupe(u8, s.text(6)), .src_l0 = if (s.isNull(7)) null else try a.dupe(u8, s.text(7)), .turn_text = "", .speaker = "unknown" };
            if (p.src_l0) |src| if (std.mem.startsWith(u8, src, "turn=")) {
                const end = std.mem.indexOfScalar(u8, src, ' ') orelse src.len;
                if (std.fmt.parseInt(i64, src[5..end], 10)) |tid| {
                    var q = try rd.db.prepare("SELECT seat, text FROM l0 WHERE id = ?1");
                    defer q.deinit();
                    try q.bind(1, tid);
                    p.turn_id = tid;
                    if (try q.step()) {
                        p.turn_text = try a.dupe(u8, q.text(1));
                        p.speaker = wk.person_of.f(wk.person_of.ctx, a, try a.dupe(u8, q.text(0))) orelse "unknown";
                    }
                } else |_| {}
            };
            try out.append(a, p);
        }
        return out.items;
    }

    /// One engine call per pending atom (same allowlisted engine, one repair on a malformed reply); a resolved row
    /// then takes the pipeline's own path (candidates → judge → write) and the pending row is closed with an audit row.
    fn reviewSweep(wk: *Worker, a: std.mem.Allocator, rd: *store.Store, client: *extract.llm.Client, pl: *extract.pipeline.Pipeline, ws: *WriterSink, now: i64) !u32 {
        if (now < wk.next_review_ms) return 0;
        const pending = try wk.loadPending(a, rd);
        if (pending.len == 0) {
            wk.next_review_ms = now + sweep_ms;
            return 0;
        }
        const people = pl.cfg.people;
        const lines = try people.render(a);
        var new_atoms: u32 = 0;
        for (pending) |p| {
            const turn_text = if (p.turn_text.len > 0) p.turn_text else "(source turn unavailable)";
            const user = try extract.prompts.renderReview(a, lines, p.speaker, turn_text, p.subject, p.text);
            var msgs = [_]extract.llm.Msg{ .{ .role = "system", .content = extract.prompts.review_system }, .{ .role = "user", .content = user }, .{ .role = "assistant", .content = "" }, .{ .role = "user", .content = "" } };
            const c0 = client.connects;
            const r0 = client.refused;
            defer {
                _ = wk.stats.connects.fetchAdd(client.connects - c0, .monotonic);
                _ = wk.stats.refused.fetchAdd(client.refused - r0, .monotonic);
            }
            const r1 = client.chat(a, wk.ep, msgs[0..2]) catch {
                _ = wk.stats.review_failed.fetchAdd(1, .monotonic);
                wk.next_review_ms = now + review_backoff_ms;
                return new_atoms;
            };
            const verdict = extract.review.decide(a, people, r1.content) catch blk: {
                msgs[2].content = if (r1.content.len > 0) r1.content else "(empty reply)";
                msgs[3].content = try std.fmt.allocPrint(a, extract.prompts.repair_user, .{"- reply must be one JSON object with keep, subject, text\n"});
                const r2 = client.chat(a, wk.ep, &msgs) catch {
                    _ = wk.stats.review_failed.fetchAdd(1, .monotonic);
                    wk.next_review_ms = now + review_backoff_ms;
                    return new_atoms;
                };
                break :blk extract.review.decide(a, people, r2.content) catch extract.review.Verdict{ .retire = "reviewer: reply unreadable twice" };
            };
            switch (verdict) {
                .retire => |why| {
                    try wk.w.call(reviewCloseOp, .{ p.id, why });
                    _ = wk.stats.review_retired.fetchAdd(1, .monotonic);
                },
                .resolve => |r| {
                    // the pipeline's path: candidates in this scope (and the subject's own, if the speaker may write
                    // there) → the judge → insert / supersede / demote, with the same provenance stamps
                    var rid_buf: [48]u8 = undefined;
                    pl.cfg.scope = p.scope;
                    pl.cfg.today = p.valid_from orelse "1970-01-01";
                    pl.cfg.run_id = try std.fmt.bufPrint(&rid_buf, "api-review-{d}", .{p.id});
                    ws.speaker = p.speaker;
                    const turn: extract.pipeline.Turn = .{ .id = p.turn_id, .session = "review", .speaker = p.speaker, .role = "user", .date = pl.cfg.today, .text = turn_text };
                    const mem: extract.parse.Mem = .{ .subject = r.subject, .type = p.type, .text = r.text, .priority = p.priority, .valid_from = p.valid_from, .turns = &.{p.turn_id}, .corrects = null };
                    const lg = pl.applyReviewed(a, turn, mem) catch |e| {
                        _ = wk.stats.review_failed.fetchAdd(1, .monotonic);
                        try wk.w.call(reviewCloseOp, .{ p.id, @errorName(e) });
                        continue;
                    };
                    const ids = try writtenIds(a, &lg);
                    var detail: std.ArrayList(u8) = .empty;
                    try detail.print(a, "resolved subject={s}:", .{r.subject[0..@min(r.subject.len, 48)]});
                    for (lg.applied.items) |x| try detail.print(a, " {s}{s}{d}", .{ x.action, if (x.id != null) "=" else "", x.id orelse x.target orelse 0 });
                    if (ids.len > 0) try wk.w.call(reviewMarkOp, .{ ids, p.id });
                    try wk.w.call(reviewCloseOp, .{ p.id, detail.items });
                    _ = wk.stats.reviewed.fetchAdd(1, .monotonic);
                    for (ids) |id| if ((try rd.db.oneInt("SELECT 1 FROM atoms WHERE id = ?1 AND status = 'active'", .{id})) != null) {
                        new_atoms += 1;
                    };
                    if (ids.len > 0) _ = wk.embedAtoms(a, rd, ids) catch 0;
                },
            }
        }
        wk.next_review_ms = now;
        return new_atoms;
    }

    // ---- the fold (fix 2) ----

    fn maybeFold(wk: *Worker, a: std.mem.Allocator, now: i64, queued: bool) void {
        const new = wk.stats.new_since_fold.load(.acquire);
        if (new > 0) {
            const last = wk.stats.fold_last_ms.load(.acquire);
            const last_job = wk.last_job_ms.load(.acquire);
            // idle trigger: nothing extracted for idle_ms with new atoms waiting
            if (!queued and last_job != 0 and now - last_job >= wk.cadence.idle_ms) wk.scheduleFold(now);
            // forced: new atoms have waited a whole forced_ms since the last fold
            if (last != 0 and now - last >= wk.cadence.forced_ms) wk.stats.fold_due_ms.store(now, .release);
        }
        const due = wk.stats.fold_due_ms.load(.acquire);
        if (due == 0 or now < due) return;
        const st = wk.w.call(fold.runOp, .{a}) catch |e| {
            std.debug.print("zigmem: fold failed: {s}\n", .{@errorName(e)});
            wk.stats.fold_due_ms.store(now + wk.cadence.l2_min_ms, .release);
            return;
        };
        _ = st;
        wk.stats.fold_last_ms.store(now, .release);
        wk.stats.fold_due_ms.store(0, .release);
        wk.stats.new_since_fold.store(0, .release);
        _ = wk.stats.folds.fetchAdd(1, .monotonic);
    }

    fn run(wk: *Worker, idx: usize) !void {
        var rd = try store.Store.open(wk.gpa, wk.io, wk.db_path, .{ .read_only = true });
        defer rd.close();
        var keep: std.heap.ArenaAllocator = .init(wk.gpa);
        defer keep.deinit();
        var client: extract.llm.Client = .{};
        var ws: WriterSink = .{ .w = wk.w, .rd = &rd };
        var pl = extract.pipeline.Pipeline.init(wk.gpa, .{
            .extractor = wk.ep,
            .judge = wk.ep, // the primary engine extracts and judges (PHASE2 verdict); secondary is not wired here.
            .scope = "unset",
            .people = .{ .list = try loadPeople(keep.allocator(), &rd) },
            .today = "1970-01-01",
            .run_id = "unset",
        }, &client, ws.sink());
        defer pl.deinit();
        if (idx == 0) {
            // a store with earlier folds keeps its cadence across restarts, and what landed since the last fold
            // (extracted before a crash or a restart) still counts toward the next one
            const last = fold.lastMs(&rd);
            wk.stats.fold_last_ms.store(last, .release);
            wk.stats.folds.store(fold.runs(&rd), .release);
            const since = (rd.db.oneInt("SELECT count(*) FROM atoms WHERE recorded_ms > ?1", .{last}) catch null) orelse 0;
            wk.noteNewAtoms(@intCast(@min(since, std.math.maxInt(u32))));
        }
        while (!wk.stop.load(.acquire)) {
            var ja: std.heap.ArenaAllocator = .init(wk.gpa);
            defer ja.deinit();
            const a = ja.allocator();
            const now = wk.nowMs();
            if (idx == 0) wk.maybeFold(a, now, true);
            const job = (wk.w.call(store.jobs.claim, .{ a, now }) catch null) orelse {
                if (idx == 0 and wk.stats.inflight.load(.acquire) == 0) {
                    // the idle path: embed what is unembedded, review what is pending, fold what is due
                    wk.embedSweep(a, &rd, now);
                    const n = wk.reviewSweep(a, &rd, &client, &pl, &ws, now) catch 0;
                    wk.noteNewAtoms(n);
                    wk.maybeFold(a, now, false);
                }
                sleepMs(250);
                continue;
            };
            var err: ?[]const u8 = null;
            var written: []i64 = &.{};
            blk: {
                if (!std.mem.eql(u8, job.kind, "extract")) {
                    err = "unknown job kind";
                    break :blk;
                }
                const l0_id = std.fmt.parseInt(i64, job.key, 10) catch {
                    err = "bad key";
                    break :blk;
                };
                var s = try rd.db.prepare("SELECT session_id, seat, scope, role, text, ts_ms FROM l0 WHERE id = ?1");
                defer s.deinit();
                try s.bind(1, l0_id);
                if (!try s.step()) {
                    err = "turn not found";
                    break :blk;
                }
                var date_buf: [10]u8 = undefined;
                var rid_buf: [48]u8 = undefined;
                const seat = try a.dupe(u8, s.text(1));
                const turn: extract.pipeline.Turn = .{
                    .id = l0_id,
                    .session = try a.dupe(u8, s.text(0)),
                    .speaker = wk.person_of.f(wk.person_of.ctx, a, seat) orelse "unknown",
                    .role = try a.dupe(u8, s.text(3)),
                    .date = dateOf(&date_buf, s.int(5)),
                    .text = try a.dupe(u8, s.text(4)),
                };
                pl.cfg.scope = try a.dupe(u8, s.text(2));
                pl.cfg.today = turn.date;
                pl.cfg.run_id = try std.fmt.bufPrint(&rid_buf, "api-w{d}-job{d}", .{ idx, job.id });
                ws.speaker = turn.speaker;
                const c0 = client.connects;
                const r0 = client.refused;
                const n = wk.stats.inflight.fetchAdd(1, .acq_rel) + 1;
                _ = wk.stats.inflight_max.fetchMax(n, .acq_rel);
                const res = pl.process(a, turn);
                _ = wk.stats.inflight.fetchSub(1, .acq_rel);
                _ = wk.stats.connects.fetchAdd(client.connects - c0, .monotonic);
                _ = wk.stats.refused.fetchAdd(client.refused - r0, .monotonic);
                if (res) |log| {
                    written = try writtenIds(a, &log);
                } else |e| {
                    err = @errorName(e);
                }
            }
            wk.w.call(store.jobs.finish, .{ job.id, err, @as(i64, 30_000) }) catch {};
            if (err == null) _ = wk.stats.done.fetchAdd(1, .monotonic) else _ = wk.stats.failed.fetchAdd(1, .monotonic);
            wk.last_job_ms.store(wk.nowMs(), .release);
            if (written.len > 0) {
                // embed this job's rows now (one call, bounded by the embedder's leash); a failure leaves them to the sweep
                var i: usize = 0;
                while (i < written.len) : (i += embed_batch) _ = wk.embedAtoms(a, &rd, written[i..@min(written.len, i + embed_batch)]) catch 0;
                wk.noteNewAtoms(@intCast(written.len));
            }
        }
    }
};

test "dateOf: civil dates" {
    var b: [10]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01", dateOf(&b, 0));
    try std.testing.expectEqualStrings("2026-10-12", dateOf(&b, 1_791_763_200_000 + 3_600_000));
    try std.testing.expectEqualStrings("2000-02-29", dateOf(&b, 951_782_400_000));
}

test "fold scheduling: first fold at once, then the L2 cadence; a session end only schedules when something is new" {
    var wk: Worker = .{ .gpa = std.testing.allocator, .io = std.testing.io, .db_path = "", .w = undefined, .ep = allow.primary, .threads = 1, .person_of = .{ .ctx = undefined, .f = undefined } };
    wk.requestFold(1_000);
    try std.testing.expectEqual(@as(i64, 0), wk.stats.fold_due_ms.load(.acquire)); // nothing new
    wk.noteNewAtoms(1); // warm-up threshold 1 → due now
    try std.testing.expect(wk.stats.fold_due_ms.load(.acquire) != 0);
    wk.stats.fold_due_ms.store(0, .release);
    wk.stats.new_since_fold.store(0, .release);
    const last = wk.nowMs();
    wk.stats.fold_last_ms.store(last, .release);
    _ = wk.stats.folds.fetchAdd(1, .monotonic);
    wk.noteNewAtoms(1); // threshold is now 2
    try std.testing.expectEqual(@as(i64, 0), wk.stats.fold_due_ms.load(.acquire));
    wk.noteNewAtoms(1);
    try std.testing.expectEqual(last + wk.cadence.l2_min_ms, wk.stats.fold_due_ms.load(.acquire)); // not before last + 900 s
    wk.requestFold(last); // already scheduled: unchanged
    try std.testing.expectEqual(last + wk.cadence.l2_min_ms, wk.stats.fold_due_ms.load(.acquire));
}
