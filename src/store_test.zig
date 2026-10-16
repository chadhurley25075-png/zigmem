//! Phase-1 store tests: `<private>` 11/11 port + Python parity vectors, FTS5, scopes, supersession, append-only
//! guards, jobs, writer thread, and source scans (no DELETE FROM, no network code). Synthetic data only.
const std = @import("std");
const t = std.testing;
const store = @import("store/store.zig");
const P = store.private;
const Store = store.Store;
const Scope = store.Scope;

const mark = P.mark;

fn strip(s: []const u8, on: bool) ![]u8 {
    return (try P.strip(t.allocator, s, on)).text;
}

// ---- (c) the 11 cases of the reference private-tag tests, ported one-to-one (names kept) ----

test "private 01 strip closed span" {
    const r = try strip("a <private>secret pw</private> b", true);
    defer t.allocator.free(r);
    try t.expectEqualStrings("a " ++ mark ++ " b", r);
}
test "private 02 strip case/space" {
    const r = try strip("x < PRIVATE >secret</ private > y", true);
    defer t.allocator.free(r);
    try t.expect(std.mem.indexOf(u8, r, "secret") == null);
}
test "private 03 unclosed cuts to end" {
    const r = try strip("keep this <private>secret forever", true);
    defer t.allocator.free(r);
    try t.expectEqualStrings("keep this " ++ mark, r);
}
test "private 04 two spans" {
    const r = try strip("<private>a</private> mid <private>b</private>", true);
    defer t.allocator.free(r);
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, r, mark));
}
test "private 05 no tag untouched" {
    const r = try strip("plain text", true);
    defer t.allocator.free(r);
    try t.expectEqualStrings("plain text", r);
}
test "private 06 door refuses private" {
    try t.expect(P.hasOpen("Syn said <private>syn detail</private> today", true));
}
test "private 07 door passes after strip" {
    const r = try strip("Syn said <private>x</private> today about the swatches", true);
    defer t.allocator.free(r);
    try t.expect(!P.hasOpen(r, true));
}
test "private 08 jsonl stays valid + stripped" {
    const line = "{\"type\": \"user\", \"message\": {\"role\": \"user\", \"content\": " ++
        "\"go ahead <private>syn code 4455\\nand \\\"quoted\\\"</private> thanks\"}}";
    const out = (try P.line(t.allocator, line, true)).text;
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, "4455") == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, out, .{});
    defer parsed.deinit();
    const content = parsed.value.object.get("message").?.object.get("content").?.string;
    try t.expect(std.mem.indexOf(u8, content, mark) != null);
    try t.expect(std.mem.startsWith(u8, content, "go ahead"));
}
test "private 09 jsonl unclosed dropped" {
    const out = (try P.line(t.allocator, "{\"c\": \"a <private>leak\"}", true)).text;
    defer t.allocator.free(out);
    try t.expectEqualStrings("", out);
}
test "private 10 jsonl no tag untouched" {
    const out = (try P.line(t.allocator, "{\"a\": 1}", true)).text;
    defer t.allocator.free(out);
    try t.expectEqualStrings("{\"a\": 1}", out);
}
test "private 11 kill switch" {
    const r = try strip("<private>x</private>", false);
    defer t.allocator.free(r);
    try t.expectEqualStrings("<private>x</private>", r);
    try t.expect(!P.hasOpen("hello there <private>x</private> friend", false));
}

test "private parity vectors vs the Python reference (63 generated cases)" {
    const raw = @embedFile("store/testdata/private_vectors.json");
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, raw, .{});
    defer parsed.deinit();
    try t.expectEqualStrings(mark, parsed.value.object.get("mark").?.string);
    var n: usize = 0;
    var stricter: usize = 0;
    for (parsed.value.object.get("cases").?.array.items) |c| {
        const o = c.object;
        if (o.get("in")) |in| {
            const got = try strip(in.string, true);
            defer t.allocator.free(got);
            try t.expectEqualStrings(o.get("strip").?.string, got);
            try t.expectEqual(o.get("refuse").?.bool, P.hasOpen(in.string, true));
        } else {
            const in = o.get("line").?.string;
            const want = o.get("out").?.string;
            const got = (try P.line(t.allocator, in, true)).text;
            defer t.allocator.free(got);
            // Known reference leak: Python private_line's fast path skips lines without "rivate"/"RIVATE", so a
            // mixed-case tag (<PrIvAtE>) passes through unstripped. The Zig port is stricter here, never looser.
            const py_fast_path = std.mem.indexOf(u8, in, "rivate") == null and std.mem.indexOf(u8, in, "RIVATE") == null;
            if (py_fast_path and std.mem.eql(u8, want, in) and !std.mem.eql(u8, got, in)) {
                stricter += 1;
                try t.expect(!P.hasOpen(got, true));
            } else try t.expectEqualStrings(want, got);
        }
        n += 1;
    }
    try t.expectEqual(@as(usize, 63), n);
    try t.expectEqual(@as(usize, 1), stricter);
}

test "private fail-closed: a filter that cannot allocate writes nothing" {
    var f = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, P.strip(f.allocator(), "x <private>y</private>", true));
}

// ---- store fixtures ----

const Fx = struct {
    tmp: t.TmpDir,
    path: [:0]u8,
    st: Store,

    fn init() !*Fx {
        const fx = try t.allocator.create(Fx);
        fx.tmp = t.tmpDir(.{});
        fx.path = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/z.db", .{fx.tmp.sub_path}, 0);
        fx.st = try Store.open(t.allocator, t.io, fx.path, .{});
        return fx;
    }
    fn deinit(fx: *Fx) void {
        fx.st.close();
        t.allocator.free(fx.path);
        fx.tmp.cleanup();
        t.allocator.destroy(fx);
    }
};

const hh: Scope = .{ .names = &.{"syn-household"} };
const other: Scope = .{ .names = &.{"syn-other"} };

fn atom(subject: []const u8, scope: []const u8, text: []const u8) store.atoms.New {
    return .{ .subject = subject, .scope = scope, .type = "fact", .text = text };
}

test "l0: private stripped at write, canary never reaches the file, idempotent capture, scoped FTS" {
    const fx = try Fx.init();
    defer fx.deinit();
    const turn: store.l0.Turn = .{ .session_id = "s1", .seat = "syn-seat", .scope = "syn-household", .role = "user", .text = "the teal swatch <private>syn-canary-7731</private> dried fast", .ts_ms = 1000 };
    const id = (try store.l0.append(&fx.st, turn)).?;
    try t.expectEqual(@as(?i64, null), try store.l0.append(&fx.st, turn));
    try t.expectEqual(@as(i64, 1), try store.l0.sessionTurns(&fx.st, "s1"));
    try t.expectEqual(@as(?i64, 1), try fx.st.db.oneInt("SELECT private_dropped FROM l0 WHERE id = ?1", .{id}));
    const hits = try store.l0.search(&fx.st, t.allocator, hh, "teal swatch", .{});
    defer store.l0.freeHits(t.allocator, hits);
    try t.expectEqual(@as(usize, 1), hits.len);
    try t.expectEqualStrings("the teal swatch " ++ mark ++ " dried fast", hits[0].text);
    const none = try store.l0.search(&fx.st, t.allocator, other, "teal swatch", .{});
    defer store.l0.freeHits(t.allocator, none);
    try t.expectEqual(@as(usize, 0), none.len);
    try fx.st.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(t.io, fx.path, t.allocator, .limited(1 << 26));
    defer t.allocator.free(bytes);
    try t.expect(std.mem.indexOf(u8, bytes, "syn-canary-7731") == null);
    try t.expect(std.mem.indexOf(u8, bytes, "dried fast") != null);
}

test "atoms: FTS5 search, scope is mandatory and enforced, priority/type validated" {
    const fx = try Fx.init();
    defer fx.deinit();
    _ = try store.atoms.insert(&fx.st, atom("syn-ann", "syn-household", "syn-ann prefers matte topcoat over glossy"));
    _ = try store.atoms.insert(&fx.st, atom("syn-bo", "syn-other", "syn-bo prefers glossy topcoat"));
    const r = try store.atoms.search(&fx.st, t.allocator, hh, "glossy topcoat", .{});
    defer store.atoms.freeAll(t.allocator, r);
    try t.expectEqual(@as(usize, 1), r.len);
    try t.expectEqualStrings("syn-ann", r[0].subject);
    try t.expectError(error.ScopeRequired, store.atoms.search(&fx.st, t.allocator, .{ .names = &.{} }, "glossy", .{}));
    var bad = atom("syn-ann", "syn-household", "x");
    bad.type = "secret_type";
    try t.expectError(error.BadAtomType, store.atoms.insert(&fx.st, bad));
    bad.type = "work_note";
    bad.priority = 101;
    try t.expectError(error.BadPriority, store.atoms.insert(&fx.st, bad));
    // porter stemming: "prefer" finds "prefers"
    const s2 = try store.atoms.search(&fx.st, t.allocator, hh, "prefer", .{});
    defer store.atoms.freeAll(t.allocator, s2);
    try t.expectEqual(@as(usize, 1), s2.len);
}

test "FTS planner: very common terms are dropped from ranking; an all-common query is recency-capped" {
    const fx = try Fx.init();
    defer fx.deinit();
    try fx.st.db.exec("BEGIN");
    var buf: [64]u8 = undefined;
    for (0..1500) |i| _ = try store.atoms.insert(&fx.st, atom("syn-ann", "syn-household", try std.fmt.bufPrint(&buf, "commonword filler{d}", .{i})));
    try fx.st.db.exec("COMMIT");
    const plan = (try store.ftsPlan(&fx.st, t.allocator, "atoms_fts", "atoms", "commonword filler77")).?;
    defer t.allocator.free(plan.match);
    try t.expectEqualStrings("\"filler77\"", plan.match);
    try t.expect(!plan.capped);
    const r = try store.atoms.search(&fx.st, t.allocator, hh, "commonword filler77", .{});
    defer store.atoms.freeAll(t.allocator, r);
    try t.expectEqualStrings("commonword filler77", r[0].text);
    const all = (try store.ftsPlan(&fx.st, t.allocator, "atoms_fts", "atoms", "commonword commonword")).?;
    defer t.allocator.free(all.match);
    try t.expect(all.capped);
    try t.expectEqualStrings("\"commonword\"", all.match);
    const r2 = try store.atoms.search(&fx.st, t.allocator, hh, "commonword", .{ .limit = 5 });
    defer store.atoms.freeAll(t.allocator, r2);
    try t.expectEqual(@as(usize, 5), r2.len);
}

test "atoms: supersession keeps history, bitemporal, no cross-subject merge" {
    const fx = try Fx.init();
    defer fx.deinit();
    var a = atom("syn-ann", "syn-household", "syn-ann drives a blue sedan");
    a.valid_from = "2026-01-01";
    const old = try store.atoms.insert(&fx.st, a);
    var b = atom("syn-ann", "syn-household", "syn-ann drives a red wagon");
    b.valid_from = "2026-06-01";
    const new = try store.atoms.supersede(&fx.st, old, b, null);
    const o = (try store.atoms.get(&fx.st, t.allocator, hh, old)).?;
    defer o.deinit(t.allocator);
    try t.expectEqual(store.atoms.Status.superseded, o.status);
    try t.expectEqual(@as(?i64, new), o.superseded_by);
    try t.expectEqualStrings("2026-06-01", o.valid_to.?);
    const hist = try store.atoms.history(&fx.st, t.allocator, hh, o.lineage);
    defer store.atoms.freeAll(t.allocator, hist);
    try t.expectEqual(@as(usize, 2), hist.len);
    const live = try store.atoms.search(&fx.st, t.allocator, hh, "drives", .{});
    defer store.atoms.freeAll(t.allocator, live);
    try t.expectEqual(@as(usize, 1), live.len);
    try t.expectEqual(new, live[0].id);
    try t.expectError(error.NotActive, store.atoms.supersede(&fx.st, old, b, null));
    try t.expectError(error.CrossSubject, store.atoms.supersede(&fx.st, new, atom("syn-bo", "syn-household", "x"), null));
    try t.expect((try store.atoms.get(&fx.st, t.allocator, other, new)) == null);
    try store.atoms.setStatus(&fx.st, new, .retired, "syn-admin");
    try t.expectError(error.BadTransition, store.atoms.setStatus(&fx.st, new, .active, "syn-admin"));
}

test "(d) append-only: RED — raw DELETE/UPDATE on protected tables is aborted by the database" {
    const fx = try Fx.init();
    defer fx.deinit();
    const id = try store.atoms.insert(&fx.st, atom("syn-ann", "syn-household", "syn row"));
    _ = try store.l0.append(&fx.st, .{ .session_id = "s", .seat = "x", .scope = "syn-household", .role = "user", .text = "hi", .ts_ms = 1 });
    const del = "DE" ++ "LETE FROM ";
    try t.expectError(error.Constraint, fx.st.db.exec(del ++ "atoms"));
    try t.expectError(error.Constraint, fx.st.db.exec(del ++ "l0"));
    try t.expectError(error.Constraint, fx.st.db.exec(del ++ "audit"));
    try t.expectError(error.Constraint, fx.st.db.exec("UPDATE atoms SET text = 'rewritten'"));
    try t.expectError(error.Constraint, fx.st.db.exec("UPDATE l0 SET text = 'rewritten'"));
    try t.expectEqual(@as(?i64, 1), try fx.st.db.oneInt("SELECT count(*) FROM atoms WHERE id = ?1", .{id}));
}

test "(d) append-only: no DELETE FROM in any store source; (e) no network code in the store" {
    const files = [_][]const u8{
        @embedFile("store/store.zig"),   @embedFile("store/sqlite.zig"), @embedFile("store/schema.zig"),
        @embedFile("store/private.zig"), @embedFile("store/l0.zig"),     @embedFile("store/atoms.zig"),
        @embedFile("store/scenes.zig"),  @embedFile("store/vec.zig"),    @embedFile("store/jobs.zig"),
        @embedFile("store/writer.zig"),
    };
    const banned = [_][]const u8{ "DELETE" ++ " FROM", "delete" ++ " from", "'del" ++ "ete'", "Io" ++ ".net", "std" ++ ".http", "std" ++ ".net", "sock" ++ "et(", "con" ++ "nect(", "posix" ++ ".socket" };
    for (files) |src| for (banned) |b| try t.expect(std.mem.indexOf(u8, src, b) == null);
}

test "scenes cap + persona cap enforced in code; persona scoped" {
    const fx = try Fx.init();
    defer fx.deinit();
    var name_buf: [16]u8 = undefined;
    for (0..store.scenes.scene_cap_per_scope) |i| _ = try store.scenes.putScene(&fx.st, .{ .scope = "syn-household", .name = try std.fmt.bufPrint(&name_buf, "scene-{d}", .{i}), .summary = "s", .body = "b" });
    try t.expectError(error.SceneCapReached, store.scenes.putScene(&fx.st, .{ .scope = "syn-household", .name = "one-more", .summary = "s", .body = "b" }));
    _ = try store.scenes.putScene(&fx.st, .{ .scope = "syn-household", .name = "scene-3", .summary = "rewritten", .body = "b2", .heat = 9 });
    const list = try store.scenes.listScenes(&fx.st, t.allocator, hh);
    defer {
        for (list) |s| s.deinit(t.allocator);
        t.allocator.free(list);
    }
    try t.expectEqualStrings("scene-3", list[0].name);
    const long = try t.allocator.alloc(u8, 5000);
    defer t.allocator.free(long);
    for (0..2500) |i| @memcpy(long[2 * i ..][0..2], "é");
    try t.expectEqual(@as(i64, 1), try store.scenes.putPersona(&fx.st, "syn-ann", "syn-household", long, "w"));
    try t.expectEqual(@as(i64, 2), try store.scenes.putPersona(&fx.st, "syn-ann", "syn-household", long, "w"));
    const p = (try store.scenes.getPersona(&fx.st, t.allocator, hh, "syn-ann", "syn-household")).?;
    defer t.allocator.free(p);
    try t.expectEqual(@as(usize, 2000 * 2), p.len);
    try t.expect((try store.scenes.getPersona(&fx.st, t.allocator, other, "syn-ann", "syn-household")) == null);
}

test "vectors: dims pinned, scope-masked top-k, reload from disk matches" {
    const fx = try Fx.init();
    defer fx.deinit();
    var ix: store.vec.Index = .{ .kind = .atom };
    defer ix.deinit(t.allocator);
    var e: [32]f32 = undefined;
    for (0..20) |i| {
        const scope = if (i % 2 == 0) "syn-household" else "syn-other";
        const id = try store.atoms.insert(&fx.st, atom("syn-ann", scope, "v"));
        for (&e, 0..) |*x, j| x.* = @floatFromInt((i * 7 + j * 3) % 11);
        try store.vec.put(&fx.st, .atom, id, &e);
    }
    try t.expectError(error.DimsMismatch, store.vec.put(&fx.st, .atom, 1, e[0..16]));
    var disk = try store.vec.Index.load(&fx.st, t.allocator, .atom);
    defer disk.deinit(t.allocator);
    try t.expectEqual(@as(usize, 20), disk.ids.items.len);
    for (&e, 0..) |*x, j| x.* = @floatFromInt((4 * 7 + j * 3) % 11);
    const hits = try disk.topK(t.allocator, hh, &e, 3);
    defer t.allocator.free(hits);
    try t.expectEqual(@as(usize, 3), hits.len);
    try t.expectEqual(@as(i64, 5), hits[0].row_id); // the 5th insert (i = 4) is the exact match
    try t.expect(hits[0].score > 0.9999 and hits[0].score >= hits[1].score);
    for (hits) |h| try t.expect(@mod(h.row_id, 2) == 1); // only syn-household rows (odd ids)
}

test "jobs survive a restart and dedupe while queued; runs log provenance" {
    const fx = try Fx.init();
    defer fx.deinit();
    try t.expect(try store.jobs.enqueue(&fx.st, "extract", "s1", 0));
    try t.expect(!try store.jobs.enqueue(&fx.st, "extract", "s1", 0));
    const j = (try store.jobs.claim(&fx.st, t.allocator, 10)).?;
    defer j.deinit(t.allocator);
    // simulate a crash: reopen, the running job comes back
    fx.st.close();
    fx.st = try Store.open(t.allocator, t.io, fx.path, .{});
    try t.expectEqual(@as(i64, 1), try store.jobs.recover(&fx.st));
    const j2 = (try store.jobs.claim(&fx.st, t.allocator, 10)).?;
    defer j2.deinit(t.allocator);
    try t.expectEqual(@as(i64, 2), j2.tries);
    try store.jobs.finish(&fx.st, j2.id, null, 0);
    try t.expectEqual(@as(i64, 1), try store.jobs.count(&fx.st, "done"));
    try store.jobs.beginRun(&fx.st, "run-1", "extract", "syn-model", @splat(1), "1,2");
    try store.jobs.endRun(&fx.st, "run-1", "7", "ok");
}

fn insertOne(st: *Store, i: usize) !i64 {
    var buf: [64]u8 = undefined;
    return store.atoms.insert(st, atom("syn-ann", "syn-household", try std.fmt.bufPrint(&buf, "writer row {d}", .{i})));
}

fn hammer(w: *store.writer.Writer, base: usize) void {
    for (0..200) |i| _ = w.call(insertOne, .{base + i}) catch @panic("writer call failed");
}

test "writer thread: 4 submitters × 200 ops group-commit, a failing op rolls back alone" {
    const fx = try Fx.init();
    defer fx.deinit();
    var w = store.writer.Writer.init(&fx.st);
    try w.start();
    var th: [4]std.Thread = undefined;
    for (&th, 0..) |*x, k| x.* = try std.Thread.spawn(.{}, hammer, .{ &w, k * 1000 });
    for (th) |x| x.join();
    const bad = atom("", "syn-household", "no subject");
    try t.expectError(error.ScopeRequired, w.call(store.atoms.insert, .{bad}));
    w.stop();
    try t.expectEqual(@as(?i64, 800), try fx.st.db.oneInt("SELECT count(*) FROM atoms", .{}));
    try t.expect(w.commits < 801);
    try t.expect(try fx.st.integrity());
}
