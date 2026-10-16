//! zigmem-storebench: phase-1 gate tools on synthetic rows — `perf` (latency/throughput), `crashwrite` (child that
//! gets kill -9'd mid-write) and `verify` (integrity + every printed commit present, byte-exact). No network code.
const std = @import("std");
const store = @import("store.zig");
const Store = store.Store;
const Io = std.Io;

const usage = "usage: zigmem-storebench perf DB N | crashwrite DB ROUND ROWS | verify DB ROUND COMMITTED_FILE\n";

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("storebench: " ++ fmt, args);
    std.process.exit(2);
}

// ---- synthetic text: pseudo-words from syllables, Zipf-ish skew; deterministic per seed ----
const syl = [_][]const u8{ "ka", "lo", "mi", "ner", "tu", "sa", "vel", "dor", "pi", "qua", "ren", "zo", "bri", "fen", "gal", "hum" };
const vocab_n = 5000;

fn wordInto(w: *std.ArrayList(u8), gpa: std.mem.Allocator, idx: usize) !void {
    var x = idx + 17;
    for (0..3) |_| {
        try w.appendSlice(gpa, syl[x % syl.len]);
        x /= syl.len;
    }
    try w.print(gpa, "{d}", .{idx % 97});
}

fn pickWord(r: std.Random) usize {
    const u = r.float(f64);
    return @intFromFloat(@as(f64, vocab_n) * u * u * u);
}

fn synText(gpa: std.mem.Allocator, seed: u64, tag: []const u8) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var w: std.ArrayList(u8) = .empty;
    errdefer w.deinit(gpa);
    try w.print(gpa, "syn {s}", .{tag});
    for (0..10 + r.uintLessThan(usize, 7)) |_| {
        try w.append(gpa, ' ');
        try wordInto(&w, gpa, pickWord(r));
    }
    return w.toOwnedSlice(gpa);
}

fn now(io: Io) i96 {
    return Io.Timestamp.now(io, .awake).nanoseconds;
}

fn ms(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn pct(xs: []f64, p: f64) f64 {
    std.mem.sortUnstable(f64, xs, {}, std.sort.asc(f64));
    const i: usize = @intFromFloat(@floor(p * @as(f64, @floatFromInt(xs.len - 1))));
    return xs[i];
}

fn insertSyn(st: *Store, seed: u64, scope: []const u8, run_id: []const u8, tag: []const u8) !i64 {
    const text = try synText(st.gpa, seed, tag);
    defer st.gpa.free(text);
    var a: store.atoms.New = .{ .subject = "syn-subject", .scope = scope, .type = "fact", .text = text };
    a.run_id = run_id;
    return store.atoms.insert(st, a);
}

const Feed = struct { w: *store.writer.Writer, from: usize, to: usize, failed: bool = false };

fn feeder(f: *Feed) void {
    var buf: [32]u8 = undefined;
    for (f.from..f.to) |i| {
        const scope = if (i % 4 == 0) "syn-b" else "syn-a";
        const rid = std.fmt.bufPrint(&buf, "perf-{d}", .{i}) catch unreachable;
        _ = f.w.call(insertSyn, .{ @as(u64, i), scope, rid, "perf" }) catch {
            f.failed = true;
            return;
        };
    }
}

fn perf(gpa: std.mem.Allocator, io: Io, path: [:0]const u8, n: usize) !void {
    var st = try Store.open(gpa, io, path, .{});
    defer st.close();
    var w = store.writer.Writer.init(&st);
    try w.start();
    // (1) one submitter: every op is its own commit — the worst case.
    const single_n = @min(n, 5000);
    var t0 = now(io);
    var f1: Feed = .{ .w = &w, .from = 0, .to = single_n };
    feeder(&f1);
    const single_s = ms(now(io) - t0) / 1000;
    // (2) eight submitters: the writer group-commits.
    t0 = now(io);
    var feeds: [8]Feed = undefined;
    var th: [8]std.Thread = undefined;
    const rest = n - single_n;
    for (&feeds, &th, 0..) |*f, *x, k| {
        f.* = .{ .w = &w, .from = single_n + rest * k / 8, .to = single_n + rest * (k + 1) / 8 };
        x.* = try std.Thread.spawn(.{}, feeder, .{f});
    }
    for (th) |x| x.join();
    const multi_s = ms(now(io) - t0) / 1000;
    w.stop();
    for (feeds) |f| if (f.failed or f1.failed) return error.FeedFailed;
    // (3) 768-d vectors for every atom, batched 1000 per transaction.
    const dims = 768;
    const e = try gpa.alloc(f32, dims);
    defer gpa.free(e);
    var prng = std.Random.DefaultPrng.init(42);
    t0 = now(io);
    var id: i64 = 1;
    while (id <= n) : (id += 1) {
        if (@mod(id, 1000) == 1) try st.db.exec("BEGIN");
        for (e) |*x| x.* = prng.random().floatNorm(f32);
        try store.vec.put(&st, .atom, id, e);
        if (@mod(id, 1000) == 0 or id == n) try st.db.exec("COMMIT");
    }
    const vec_s = ms(now(io) - t0) / 1000;
    try st.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    // (4) reads on a separate read-only connection, like a hub reader thread.
    var rd = try Store.open(gpa, io, path, .{ .read_only = true });
    defer rd.close();
    const one: store.Scope = .{ .names = &.{"syn-a"} };
    const two: store.Scope = .{ .names = &.{ "syn-a", "syn-b" } };
    const nq = 1000;
    var fts_ms = try gpa.alloc(f64, nq);
    defer gpa.free(fts_ms);
    var hits_total: usize = 0;
    var qr = std.Random.DefaultPrng.init(7);
    for (0..nq) |i| {
        var q: std.ArrayList(u8) = .empty;
        defer q.deinit(gpa);
        for (0..2 + qr.random().uintLessThan(usize, 2)) |_| {
            try wordInto(&q, gpa, pickWord(qr.random()));
            try q.append(gpa, ' ');
        }
        const t1 = now(io);
        const r = try store.atoms.search(&rd, gpa, if (i % 2 == 0) one else two, q.items, .{ .limit = 10 });
        fts_ms[i] = ms(now(io) - t1);
        hits_total += r.len;
        store.atoms.freeAll(gpa, r);
    }
    t0 = now(io);
    var ix = try store.vec.Index.load(&rd, gpa, .atom);
    defer ix.deinit(gpa);
    const load_s = ms(now(io) - t0) / 1000;
    const nv = 200;
    var vec_ms = try gpa.alloc(f64, nv);
    defer gpa.free(vec_ms);
    for (0..nv) |i| {
        for (e) |*x| x.* = prng.random().floatNorm(f32);
        const t1 = now(io);
        const h = try ix.topK(gpa, if (i % 2 == 0) one else two, e, 10);
        vec_ms[i] = ms(now(io) - t1);
        if (h.len != 10) return error.ShortTopK;
        gpa.free(h);
    }
    const ok = try st.integrity();
    out("{{\"atoms\":{d},\"insert_single_commit_per_s\":{d:.0},\"insert_grouped_per_s\":{d:.0},\"commits\":{d}," ++
        "\"vec_put_per_s\":{d:.0},\"fts_p50_ms\":{d:.3},\"fts_p95_ms\":{d:.3},\"fts_p99_ms\":{d:.3},\"fts_max_ms\":{d:.3}," ++
        "\"fts_avg_hits\":{d:.2},\"vec_load_s\":{d:.2},\"vec_p50_ms\":{d:.2},\"vec_p95_ms\":{d:.2},\"vec_p99_ms\":{d:.2},\"integrity\":{}}}\n", .{
        n,                                       @as(f64, @floatFromInt(single_n)) / single_s,
        @as(f64, @floatFromInt(rest)) / multi_s, w.commits,
        @as(f64, @floatFromInt(n)) / vec_s,      pct(fts_ms, 0.5),
        pct(fts_ms, 0.95),                       pct(fts_ms, 0.99),
        pct(fts_ms, 1.0),                        @as(f64, @floatFromInt(hits_total)) / nq,
        load_s,                                  pct(vec_ms, 0.5),
        pct(vec_ms, 0.95),                       pct(vec_ms, 0.99),
        ok,
    });
}

// ---- crash: child writes ROWS rows from 4 submitter threads; prints "C <seq>" only after its commit returned ----
const Crash = struct { w: *store.writer.Writer, round: u64, k: usize, rows: usize };

fn crashSeed(round: u64, seq: usize) u64 {
    return round * 1_000_000 + seq;
}

fn crashOp(st: *Store, round: u64, seq: usize) !void {
    var rid: [48]u8 = undefined;
    var tag: [48]u8 = undefined;
    const r = try std.fmt.bufPrint(&rid, "crash-{d}-{d}", .{ round, seq });
    const tg = try std.fmt.bufPrint(&tag, "r{d}s{d}", .{ round, seq });
    _ = try insertSyn(st, crashSeed(round, seq), "syn-a", r, tg);
    const text = try synText(st.gpa, crashSeed(round, seq) ^ 0xabc, tg);
    defer st.gpa.free(text);
    _ = try store.l0.append(st, .{ .session_id = r, .seat = "syn", .scope = "syn-a", .role = "user", .text = text, .ts_ms = @intCast(seq) });
}

fn crashFeeder(c: *Crash) void {
    var seq = c.k;
    while (seq < c.rows) : (seq += 4) {
        c.w.call(crashOp, .{ c.round, seq }) catch |e| fail("op failed: {s}\n", .{@errorName(e)});
        out("C {d}\n", .{seq});
    }
}

fn crashwrite(gpa: std.mem.Allocator, io: Io, path: [:0]const u8, round: u64, rows: usize) !void {
    var st = try Store.open(gpa, io, path, .{});
    var w = store.writer.Writer.init(&st);
    try w.start();
    out("READY\n", .{});
    var cs: [4]Crash = undefined;
    var th: [4]std.Thread = undefined;
    for (&cs, &th, 0..) |*c, *x, k| {
        c.* = .{ .w = &w, .round = round, .k = k, .rows = rows };
        x.* = try std.Thread.spawn(.{}, crashFeeder, .{c});
    }
    for (th) |x| x.join();
    w.stop();
    st.close();
    out("DONE\n", .{});
}

fn verify(gpa: std.mem.Allocator, io: Io, path: [:0]const u8, round: u64, committed_path: []const u8) !void {
    var st = try Store.open(gpa, io, path, .{});
    defer st.close();
    const ok = try st.integrity();
    const raw = try Io.Dir.cwd().readFileAlloc(io, committed_path, gpa, .limited(1 << 26));
    defer gpa.free(raw);
    var printed: usize = 0;
    var missing: usize = 0;
    var mismatch: usize = 0;
    var s = try st.db.prepare("SELECT text FROM atoms WHERE run_id = ?1");
    defer s.deinit();
    var it = std.mem.tokenizeScalar(u8, raw, '\n');
    while (it.next()) |ln| {
        if (!std.mem.startsWith(u8, ln, "C ")) continue;
        const seq = std.fmt.parseInt(usize, ln[2..], 10) catch continue;
        printed += 1;
        var rid: [48]u8 = undefined;
        var tag: [48]u8 = undefined;
        s.reset();
        try s.bind(1, try std.fmt.bufPrint(&rid, "crash-{d}-{d}", .{ round, seq }));
        if (!try s.step()) {
            missing += 1;
            continue;
        }
        const want = try synText(gpa, crashSeed(round, seq), try std.fmt.bufPrint(&tag, "r{d}s{d}", .{ round, seq }));
        defer gpa.free(want);
        if (!std.mem.eql(u8, want, s.text(0))) mismatch += 1;
    }
    var pat: [32]u8 = undefined;
    const in_db = (try st.db.oneInt("SELECT count(*) FROM atoms WHERE run_id LIKE ?1", .{try std.fmt.bufPrint(&pat, "crash-{d}-%", .{round})})).?;
    const total = (try st.db.oneInt("SELECT count(*) FROM atoms", .{})).?;
    const l0n = (try st.db.oneInt("SELECT count(*) FROM l0", .{})).?;
    out("{{\"round\":{d},\"integrity\":{},\"printed_commits\":{d},\"rows_in_db_this_round\":{d},\"missing\":{d}," ++
        "\"text_mismatch\":{d},\"atoms_total\":{d},\"l0_total\":{d}}}\n", .{ round, ok, printed, in_db, missing, mismatch, total, l0n });
    if (!ok or missing != 0 or mismatch != 0) std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) fail(usage, .{});
    const cmd: []const u8 = args[1];
    const path: [:0]const u8 = args[2];
    const num = std.fmt.parseInt(u64, args[3], 10) catch fail(usage, .{});
    if (std.mem.eql(u8, cmd, "perf")) {
        try perf(gpa, init.io, path, num);
    } else if (std.mem.eql(u8, cmd, "crashwrite") and args.len == 5) {
        try crashwrite(gpa, init.io, path, num, std.fmt.parseInt(usize, args[4], 10) catch fail(usage, .{}));
    } else if (std.mem.eql(u8, cmd, "verify") and args.len == 5) {
        try verify(gpa, init.io, path, num, args[4]);
    } else fail(usage, .{});
}
