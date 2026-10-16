//! One conversation turn → candidate memories: private strip (fail-closed) → chunk → extract → validate (+1 repair)
//! → attribute → candidates (this scope + the subject's own atoms in scopes the writer may see) → dedup decision
//! (targets ⊆ candidates) → insert / supersede (into the target's scope) / demote. Never deletes.
const std = @import("std");
const private = @import("store").private;
const allow = @import("allow.zig");
const llm = @import("llm.zig");
const parse = @import("parse.zig");
const prompts = @import("prompts.zig");
const chunk = @import("chunk.zig");
const people_mod = @import("people.zig");
const sink_mod = @import("sink.zig");
const Sink = sink_mod.Sink;
const Status = sink_mod.Status;

pub const Turn = struct { id: i64, session: []const u8, speaker: []const u8, role: []const u8, date: []const u8, text: []const u8 };

pub const Config = struct {
    extractor: allow.Endpoint,
    /// Dedup judge. null → rows with candidates go to pending_review (never a blind active write).
    judge: ?allow.Endpoint,
    scope: []const u8,
    people: people_mod.People,
    today: []const u8,
    run_id: []const u8,
    extractor_id: []const u8 = "zigmem-extract/" ++ prompts.version,
    private_tags: bool = true,
    background: usize = 5,
    max_chunk: usize = 6000,
    priority_floor: i64 = 10,
    /// Assistant turns are context only (SPEC §1.2: a prompt-only rule lets the model extract its own output, which self-reinforces).
    user_only: bool = true,
};

pub const Call = struct { kind: []const u8, engine: allow.Engine, ms: f64, valid: bool, prompt_tokens: i64, completion_tokens: i64, reasoning_bytes: usize };
pub const Applied = struct { action: []const u8, id: ?i64 = null, target: ?i64 = null, subject: []const u8, status: Status, text: []const u8, reason: ?[]const u8 = null };

pub const TurnLog = struct {
    turn_id: i64,
    skipped: ?[]const u8 = null,
    private_changed: bool = false,
    chunks: usize = 0,
    /// Extraction reply valid on the first try / after at most one repair (AND over chunks). null = no model call.
    valid_first: ?bool = null,
    valid_final: ?bool = null,
    first_errors: []const []const u8 = &.{},
    judge_valid: ?bool = null,
    calls: std.ArrayList(Call) = .empty,
    applied: std.ArrayList(Applied) = .empty,
    total_ms: f64 = 0,
};

const Hist = struct { id: i64, date: []const u8, speaker: []const u8, text: []const u8 };

pub const Pipeline = struct {
    cfg: Config,
    client: *llm.Client,
    sink: Sink,
    /// Stripped text of earlier turns per session (BACKGROUND context). Owned by `keep`.
    keep: std.heap.ArenaAllocator,
    hist: std.StringHashMapUnmanaged(std.ArrayList(Hist)) = .empty,
    prompt_sha: [32]u8,

    pub fn init(gpa: std.mem.Allocator, cfg: Config, client: *llm.Client, sink: Sink) Pipeline {
        return .{ .cfg = cfg, .client = client, .sink = sink, .keep = .init(gpa), .prompt_sha = prompts.sha() };
    }
    pub fn deinit(p: *Pipeline) void {
        p.keep.deinit();
    }

    fn remember(p: *Pipeline, t: Turn, stripped: []const u8) !void {
        const k = p.keep.allocator();
        const gop = try p.hist.getOrPut(k, t.session);
        if (!gop.found_existing) {
            gop.key_ptr.* = try k.dupe(u8, t.session);
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(k, .{ .id = t.id, .date = try k.dupe(u8, t.date), .speaker = try k.dupe(u8, t.speaker), .text = try k.dupe(u8, stripped) });
    }

    /// Process one turn. All per-turn memory lives in `a` (an arena the caller resets).
    pub fn process(p: *Pipeline, a: std.mem.Allocator, t: Turn) !TurnLog {
        const t0 = llm.nowNs();
        var log = try p.processInner(a, t);
        log.total_ms = @as(f64, @floatFromInt(llm.nowNs() - t0)) / 1e6;
        return log;
    }

    fn processInner(p: *Pipeline, a: std.mem.Allocator, t: Turn) !TurnLog {
        var log: TurnLog = .{ .turn_id = t.id };
        // 1. <private> first, fail-closed: if the filter cannot run, the turn is dropped whole (not even kept as context).
        const st = private.strip(a, t.text, p.cfg.private_tags) catch {
            log.skipped = "private filter failed: dropped";
            return log;
        };
        if (private.hasOpen(st.text, p.cfg.private_tags)) {
            log.skipped = "private tag survived strip: dropped";
            return log;
        }
        log.private_changed = st.changed;
        const text = st.text;
        const bg = if (p.hist.get(t.session)) |h| h.items[h.items.len -| p.cfg.background..] else &[_]Hist{};
        defer p.remember(t, text) catch {};
        if (p.cfg.user_only and !std.mem.eql(u8, t.role, "user")) {
            log.skipped = "not a user turn";
            return log;
        }
        const meaningful = std.mem.trim(u8, std.mem.replaceOwned(u8, a, text, private.mark, "") catch text, " \t\r\n.,;:!?");
        if (meaningful.len == 0) {
            log.skipped = "nothing left after private strip";
            return log;
        }
        var src_sha: [32]u8 = undefined;
        {
            var h = std.crypto.hash.sha2.Sha256.init(.{});
            var idb: [24]u8 = undefined;
            h.update(t.session);
            h.update("\x00");
            h.update(std.fmt.bufPrint(&idb, "{d}", .{t.id}) catch unreachable);
            h.update("\x00");
            h.update(text);
            h.final(&src_sha);
        }
        const people_lines = try p.cfg.people.render(a);
        const pieces = try chunk.split(a, text, p.cfg.max_chunk, 300);
        log.chunks = pieces.len;
        var mems: std.ArrayList(Got) = .empty;
        var all_valid = true;
        var first_ok = true;
        for (pieces) |piece| {
            var views: std.ArrayList(prompts.TurnView) = .empty;
            for (bg) |b| try views.append(a, .{ .id = b.id, .new = false, .date = b.date, .speaker = b.speaker, .text = b.text });
            try views.append(a, .{ .id = t.id, .new = true, .date = t.date, .speaker = t.speaker, .text = piece });
            const user = try prompts.renderExtract(a, people_lines, p.cfg.today, views.items);
            const ids = [_]i64{t.id};
            var msgs = [_]llm.Msg{ .{ .role = "system", .content = prompts.extract_system }, .{ .role = "user", .content = user }, .{ .role = "assistant", .content = "" }, .{ .role = "user", .content = "" } };
            const r1 = try p.client.chat(a, p.cfg.extractor, msgs[0..2]);
            var res = try parse.memories(a, r1.content, &ids);
            try log.calls.append(a, .{ .kind = "extract", .engine = p.cfg.extractor.engine, .ms = r1.ms, .valid = res.ok(), .prompt_tokens = r1.prompt_tokens, .completion_tokens = r1.completion_tokens, .reasoning_bytes = r1.reasoning_bytes });
            if (!res.ok()) {
                first_ok = false;
                log.first_errors = res.errors;
                var eb: std.ArrayList(u8) = .empty;
                for (res.errors[0..@min(res.errors.len, 8)]) |e| try eb.print(a, "- {s}\n", .{e});
                msgs[2].content = if (r1.content.len > 0) r1.content else "(empty reply)";
                msgs[3].content = try std.fmt.allocPrint(a, prompts.repair_user, .{eb.items});
                const r2 = try p.client.chat(a, p.cfg.extractor, &msgs);
                res = try parse.memories(a, r2.content, &ids);
                try log.calls.append(a, .{ .kind = "repair", .engine = p.cfg.extractor.engine, .ms = r2.ms, .valid = res.ok(), .prompt_tokens = r2.prompt_tokens, .completion_tokens = r2.completion_tokens, .reasoning_bytes = r2.reasoning_bytes });
            }
            if (!res.ok()) all_valid = false;
            // Individually valid items of a failed reply are kept, but only as pending_review (marked below).
            for (res.mems) |m| try mems.append(a, .{ .m = m, .invalid_batch = !res.ok() });
        }
        log.valid_first = first_ok;
        log.valid_final = all_valid;
        try p.decideAndApply(a, &log, t, mems.items, src_sha);
        return log;
    }

    /// The reviewer's path: one memory whose subject code already settled (a member id or "household"), from the
    /// turn it came from, through the same candidates → judge → insert / supersede / demote steps as extraction. No
    /// extraction call, no history update.
    pub fn applyReviewed(p: *Pipeline, a: std.mem.Allocator, t: Turn, m: parse.Mem) !TurnLog {
        var log: TurnLog = .{ .turn_id = t.id };
        var src_sha: [32]u8 = undefined;
        {
            var h = std.crypto.hash.sha2.Sha256.init(.{});
            var idb: [24]u8 = undefined;
            h.update(t.session);
            h.update("\x00");
            h.update(std.fmt.bufPrint(&idb, "{d}", .{t.id}) catch unreachable);
            h.update("\x00");
            h.update(t.text);
            h.final(&src_sha);
        }
        const got = [_]Got{.{ .m = m, .invalid_batch = false, .verdict = .{ .subject = m.subject, .status = .active, .reason = null } }};
        try p.decideAndApply(a, &log, t, &got, src_sha);
        return log;
    }

    fn norm(a: std.mem.Allocator, s: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (s) |c| if (std.ascii.isAlphanumeric(c)) try out.append(a, std.ascii.toLower(c));
        return out.items;
    }

    const Got = struct { m: parse.Mem, invalid_batch: bool, verdict: ?people_mod.Verdict = null };
    const Pending = struct { m: parse.Mem, v: people_mod.Verdict, cands: []const sink_mod.Cand, row: sink_mod.NewRow };

    fn decideAndApply(p: *Pipeline, a: std.mem.Allocator, log: *TurnLog, t: Turn, mems: []const Got, src_sha: [32]u8) !void {
        var todo: std.ArrayList(Pending) = .empty;
        var seen: std.ArrayList([]const u8) = .empty;
        outer: for (mems) |g| {
            const m = g.m;
            if (m.priority < p.cfg.priority_floor) {
                try log.applied.append(a, .{ .action = "drop", .subject = m.subject, .status = .pending_review, .text = m.text, .reason = "below priority floor" });
                continue;
            }
            const n = try norm(a, m.text);
            for (seen.items) |s| if (std.mem.eql(u8, s, n)) continue :outer;
            try seen.append(a, n);
            var v = g.verdict orelse p.cfg.people.attribute(m.subject, m.text);
            if (g.invalid_batch) v = .{ .subject = v.subject, .status = .pending_review, .reason = "reply failed validation" };
            const row: sink_mod.NewRow = .{
                .subject = v.subject,
                .scope = p.cfg.scope,
                .type = m.type,
                .text = m.text,
                .priority = m.priority,
                .valid_from = m.valid_from orelse t.date,
                .status = v.status,
                .note = v.reason,
                .prov = .{ .extractor = p.cfg.extractor_id, .model = p.cfg.extractor.model, .prompt_version = prompts.version, .prompt_sha = p.prompt_sha, .src_turn_sha = src_sha, .run_id = p.cfg.run_id, .turn_id = t.id },
            };
            const q = try std.fmt.allocPrint(a, "{s} {s}", .{ v.subject, m.text });
            const cands = try p.sink.findSimilar(a, p.cfg.scope, v.subject, q, 5);
            // Exact duplicate of an active row for the same subject: skip in code, no model call.
            for (cands) |c| if (std.mem.eql(u8, c.subject, v.subject) and std.mem.eql(u8, try norm(a, c.text), n)) {
                try log.applied.append(a, .{ .action = "skip", .target = c.id, .subject = v.subject, .status = v.status, .text = m.text, .reason = "exact duplicate" });
                continue :outer;
            };
            try todo.append(a, .{ .m = m, .v = v, .cands = cands, .row = row });
        }
        // Batch judge call for everything that has candidates.
        var judged: std.ArrayList(usize) = .empty;
        for (todo.items, 0..) |x, i| if (x.cands.len > 0) try judged.append(a, i);
        var dec: ?[]const parse.Decision = null;
        if (judged.items.len > 0) if (p.cfg.judge) |jep| {
            var views = try a.alloc(prompts.NewView, judged.items.len);
            var ids = try a.alloc([]const i64, judged.items.len);
            for (judged.items, 0..) |ti, k| {
                const x = todo.items[ti];
                const cv = try a.alloc(prompts.CandView, x.cands.len);
                const ci = try a.alloc(i64, x.cands.len);
                for (x.cands, 0..) |c, j| {
                    cv[j] = .{ .id = c.id, .subject = c.subject, .text = c.text };
                    ci[j] = c.id;
                }
                views[k] = .{ .subject = x.v.subject, .text = x.m.text, .corrects = x.m.corrects, .cands = cv };
                ids[k] = ci;
            }
            const user = try prompts.renderDedup(a, views);
            var msgs = [_]llm.Msg{ .{ .role = "system", .content = prompts.dedup_system }, .{ .role = "user", .content = user }, .{ .role = "assistant", .content = "" }, .{ .role = "user", .content = "" } };
            const r1 = try p.client.chat(a, jep, msgs[0..2]);
            var res = try parse.decisions(a, r1.content, ids);
            try log.calls.append(a, .{ .kind = "judge", .engine = jep.engine, .ms = r1.ms, .valid = res.ok(), .prompt_tokens = r1.prompt_tokens, .completion_tokens = r1.completion_tokens, .reasoning_bytes = r1.reasoning_bytes });
            if (!res.ok()) {
                var eb: std.ArrayList(u8) = .empty;
                for (res.errors[0..@min(res.errors.len, 8)]) |e| try eb.print(a, "- {s}\n", .{e});
                msgs[2].content = if (r1.content.len > 0) r1.content else "(empty reply)";
                msgs[3].content = try std.fmt.allocPrint(a, prompts.repair_user, .{eb.items});
                const r2 = try p.client.chat(a, jep, &msgs);
                res = try parse.decisions(a, r2.content, ids);
                try log.calls.append(a, .{ .kind = "judge-repair", .engine = jep.engine, .ms = r2.ms, .valid = res.ok(), .prompt_tokens = r2.prompt_tokens, .completion_tokens = r2.completion_tokens, .reasoning_bytes = r2.reasoning_bytes });
            }
            log.judge_valid = res.ok();
            if (res.ok()) dec = res.decisions;
        };
        for (todo.items, 0..) |x, i| {
            if (x.cands.len == 0) {
                try p.apply(a, log, x, .{ .action = .store, .target = null }, null);
                continue;
            }
            const k = std.mem.indexOfScalar(usize, judged.items, i).?;
            if (dec) |d| try p.apply(a, log, x, d[k], null) else try p.apply(a, log, x, .{ .action = .store, .target = null }, if (p.cfg.judge == null) "no judge configured" else "judge reply invalid");
        }
    }

    fn subjectOf(cands: []const sink_mod.Cand, target: ?i64) ?[]const u8 {
        const tg = target orelse return null;
        for (cands) |c| if (c.id == tg) return c.subject;
        return null;
    }

    fn scopeOf(cands: []const sink_mod.Cand, target: ?i64) ?[]const u8 {
        const tg = target orelse return null;
        for (cands) |c| if (c.id == tg and c.scope.len > 0) return c.scope;
        return null;
    }

    fn apply(p: *Pipeline, a: std.mem.Allocator, log: *TurnLog, x: Pending, d: parse.Decision, force_review: ?[]const u8) !void {
        var row = x.row;
        if (force_review) |why| {
            row.status = .pending_review;
            row.note = why;
        }
        const target_subject = subjectOf(x.cands, d.target);
        switch (d.action) {
            .skip => try log.applied.append(a, .{ .action = "skip", .target = d.target, .subject = row.subject, .status = row.status, .text = row.text, .reason = "judge: duplicate" }),
            .store => {
                const id = try p.sink.insert(row);
                try log.applied.append(a, .{ .action = "insert", .id = id, .subject = row.subject, .status = row.status, .text = row.text, .reason = row.note });
            },
            .supersede, .correct => {
                const same = target_subject != null and std.mem.eql(u8, target_subject.?, row.subject);
                if (row.status != .active) {
                    // An unverified row may never displace an active one; it waits for review, old row untouched.
                    const id = try p.sink.insert(row);
                    try log.applied.append(a, .{ .action = "insert", .id = id, .target = d.target, .subject = row.subject, .status = row.status, .text = row.text, .reason = "unverified: target left untouched" });
                } else if (d.action == .supersede and same) {
                    // the new version lives where the old one did: a parent's update about a child replaces the
                    // child's atom in the child's scope (the sink only offered that candidate because the writer may
                    // write there, and never a medical row)
                    if (scopeOf(x.cands, d.target)) |sc| row.scope = sc;
                    const id = p.sink.supersede(d.target.?, row) catch |e| {
                        const id2 = try p.sink.insert(row);
                        try log.applied.append(a, .{ .action = "insert", .id = id2, .target = d.target, .subject = row.subject, .status = row.status, .text = row.text, .reason = @errorName(e) });
                        return;
                    };
                    try log.applied.append(a, .{ .action = "supersede", .id = id, .target = d.target, .subject = row.subject, .status = row.status, .text = row.text });
                } else {
                    // correct (or supersede across people): new row + old row demoted with a pointer, never removed.
                    const id = try p.sink.insert(row);
                    const why = try std.fmt.allocPrint(a, "corrected by {d}: {s}", .{ id, x.m.corrects orelse "" });
                    p.sink.demote(d.target.?, id, why) catch |e| {
                        try log.applied.append(a, .{ .action = "insert", .id = id, .target = d.target, .subject = row.subject, .status = row.status, .text = row.text, .reason = @errorName(e) });
                        return;
                    };
                    try log.applied.append(a, .{ .action = "correct", .id = id, .target = d.target, .subject = row.subject, .status = row.status, .text = row.text });
                }
            },
        }
    }
};
