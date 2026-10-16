//! zigmem-recall: `load` (JSONL → store + vectors), `query` (JSONL {"prompt"} → JSONL {"out": block, …}, one process for a
//! whole bench), `block` (the frozen per-session block, twice, to show it is byte-identical), `stats`. Loopback services only.
const std = @import("std");
const store = @import("store");
const privacy = @import("privacy");
const R = @import("retrieve");

const usage =
    \\usage: zigmem-recall load  --db PATH --jsonl FILE --name NAME [--embed-url U] [--embed-fmt proxy|ollama] [--limit N]
    \\       zigmem-recall query --db PATH [--ledger F] [--today YYYY-MM-DD] [--embed-url U|none] [--rerank U|none]
    \\                           [--rerank-fallback U|none] [--no-subject] [--keep N] [--budget N] [--min-fused X] [--min-cos X]
    \\                           [--ledger-first] [--marker M] [--min-rerank X] [--fact-fill N] [--rerank-n N]        (stdin: JSONL {{"prompt": ...}})
    \\       zigmem-recall block --db PATH --session S [--scope a,b] [--ledger F] [--today D]
    \\       zigmem-recall stats --db PATH
    \\
;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zigmem-recall: " ++ fmt, args);
    std.process.exit(2);
}

fn writeAll(s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const n = std.c.write(1, s[off..].ptr, s.len - off);
        if (n <= 0) std.process.exit(3);
        off += @intCast(n);
    }
}

fn readAllStdin(a: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [1 << 16]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &chunk, chunk.len);
        if (n <= 0) break;
        try buf.appendSlice(a, chunk[0..@intCast(n)]);
    }
    return buf.items;
}

fn nowNs() i128 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn parseDate(s: []const u8) ?privacy.ledger.Date {
    if (s.len != 10) return null;
    return privacy.ledger.Date.valid(
        std.fmt.parseInt(i64, s[0..4], 10) catch return null,
        std.fmt.parseInt(i64, s[5..7], 10) catch return null,
        std.fmt.parseInt(i64, s[8..10], 10) catch return null,
    );
}

const Args = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,
    flags: std.StringHashMapUnmanaged(void) = .empty,
    fn get(self: Args, k: []const u8) ?[]const u8 {
        return self.map.get(k);
    }
    fn has(self: Args, k: []const u8) bool {
        return self.flags.contains(k);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    const arena = arena_state.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 2) fail(usage, .{});
    const cmd: []const u8 = argv[1];
    var args: Args = .{};
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const k: []const u8 = argv[i];
        if (std.mem.eql(u8, k, "--no-subject") or std.mem.eql(u8, k, "--ledger-first") or std.mem.eql(u8, k, "--fill-lenient") or std.mem.eql(u8, k, "--no-strict")) {
            try args.flags.put(arena, k, {});
        } else if (i + 1 < argv.len) {
            try args.map.put(arena, k, argv[i + 1]);
            i += 1;
        } else fail("missing value for {s}\n" ++ usage, .{k});
    }
    const db_path = args.get("--db") orelse fail(usage, .{});
    var st = try store.Store.open(gpa, init.io, try arena.dupeSentinel(u8, db_path, 0), .{});
    defer st.close();
    const ledger_json: ?[]const u8 = if (args.get("--ledger")) |p| (std.Io.Dir.cwd().readFileAlloc(init.io, p, arena, .limited(1 << 24)) catch fail("cannot read --ledger\n", .{})) else null;
    const today = if (args.get("--today")) |t| (parseDate(t) orelse fail("bad --today\n", .{})) else privacy.ledger.Date{ .y = 2026, .m = 10, .d = 12 };
    var gates = try privacy.Gates.init(gpa, ledger_json, today);
    defer gates.deinit();
    var esc = try privacy.escape.Escaper.init(gpa);
    defer esc.deinit();
    var util = try R.util.Util.init(gpa);
    defer util.deinit();

    if (std.mem.eql(u8, cmd, "load")) {
        const path = args.get("--jsonl") orelse fail(usage, .{});
        const data = std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(4 << 30)) catch fail("cannot read --jsonl\n", .{});
        var emb: R.embed.Embedder = .{ .leash = .{ .connect_ms = 1000, .read_ms = 120_000 } };
        if (args.get("--embed-url")) |u| emb.url = u;
        if (args.get("--embed-fmt")) |f| emb.fmt = std.meta.stringToEnum(R.embed.Format, f) orelse fail("bad --embed-fmt\n", .{});
        const lim: ?usize = if (args.get("--limit")) |l| std.fmt.parseInt(usize, l, 10) catch fail("bad --limit\n", .{}) else null;
        try st.setMeta("embed_fingerprint", R.embed.Embedder.fingerprint);
        const s = try R.load.importJsonl(gpa, &st, &gates, emb, args.get("--name") orelse "import", data, "import-p3", lim);
        var out: std.ArrayList(u8) = .empty;
        try out.print(arena, "{{\"lines\":{d},\"inserted\":{d},\"skipped\":{d},\"embed_fail\":{d}}}\n", .{ s.lines, s.inserted, s.skipped, s.embed_fail });
        writeAll(out.items);
    } else if (std.mem.eql(u8, cmd, "stats")) {
        var out: std.ArrayList(u8) = .empty;
        try out.print(arena, "{{\"atoms\":{d},\"vectors\":{d},\"subjects\":{{", .{
            (try st.db.oneInt("SELECT count(*) FROM atoms", .{})).?, (try st.db.oneInt("SELECT count(*) FROM vec", .{})).?,
        });
        var s = try st.db.prepare("SELECT subject, count(*) FROM atoms GROUP BY subject ORDER BY 2 DESC");
        defer s.deinit();
        var first = true;
        while (try s.step()) {
            try out.print(arena, "{s}\"{s}\":{d}", .{ if (first) "" else ",", s.text(0), s.int(1) });
            first = false;
        }
        try out.appendSlice(arena, "}}\n");
        writeAll(out.items);
    } else if (std.mem.eql(u8, cmd, "block")) {
        var names: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, args.get("--scope") orelse "household", ',');
        while (it.next()) |n| try names.append(arena, n);
        const scope: store.Scope = .{ .names = names.items };
        var fz = R.block.Frozen.init(gpa, &st, &gates, &esc, scope, rawWrap);
        defer fz.deinit();
        const sess = args.get("--session") orelse fail(usage, .{});
        const t1 = try fz.text(sess);
        const m1 = R.block.Frozen.blockFn(&fz, sess);
        const m2 = R.block.Frozen.blockFn(&fz, sess);
        const h = store.sha256(&.{t1});
        var out: std.ArrayList(u8) = .empty;
        try out.print(arena, "{{\"sha256\":\"{x}\",\"bytes\":{d},\"same_twice\":{any},\"text\":", .{ &h, t1.len, std.mem.eql(u8, m1, m2) and m1.ptr == m2.ptr });
        try R.jsonw.str(arena, &out, t1);
        try out.appendSlice(arena, "}\n");
        writeAll(out.items);
    } else if (std.mem.eql(u8, cmd, "query")) {
        try query(gpa, arena, &st, &gates, &esc, &util, args);
    } else fail(usage, .{});
}

fn rawWrap(a: std.mem.Allocator, raw: []const u8) anyerror![]u8 {
    return a.dupe(u8, raw);
}

fn optUrl(v: ?[]const u8, default: ?[]const u8) ?[]const u8 {
    const x = v orelse return default;
    return if (std.mem.eql(u8, x, "none")) null else x;
}

fn query(gpa: std.mem.Allocator, arena: std.mem.Allocator, st: *store.Store, gates: *privacy.Gates, esc: *privacy.escape.Escaper, util: *R.util.Util, args: Args) !void {
    const t0 = nowNs();
    var index = try store.vec.Index.load(st, gpa, .atom);
    defer index.deinit(gpa);
    const load_ms = @divTrunc(nowNs() - t0, std.time.ns_per_ms);
    std.debug.print("vector index: {d} rows in {d} ms\n", .{ index.ids.items.len, load_ms });
    var emb: ?R.embed.Embedder = .{};
    if (args.get("--embed-url")) |u| emb = if (std.mem.eql(u8, u, "none")) null else R.embed.Embedder{ .url = u };
    var rr: R.rerank.Reranker = .{};
    rr.primary = optUrl(args.get("--rerank"), rr.primary);
    rr.fallback = optUrl(args.get("--rerank-fallback"), rr.fallback);
    var ctx: R.recall.Ctx = .{ .st = st, .index = &index, .gates = gates, .esc = esc, .util = util, .embedder = emb, .reranker = rr };
    const scope_name = [_][]const u8{"household"};
    var o: R.recall.Options = .{ .scope = .{ .names = &scope_name } };
    o.subject_filter = !args.has("--no-subject");
    o.ledger_first = args.has("--ledger-first");
    o.strict_stamp = !(args.has("--fill-lenient") or args.has("--no-strict"));
    o.marker = args.get("--marker");
    if (args.get("--keep")) |v| o.keep = try std.fmt.parseInt(usize, v, 10);
    if (args.get("--budget")) |v| o.budget = try std.fmt.parseInt(usize, v, 10);
    if (args.get("--min-fused")) |v| o.min_fused = try std.fmt.parseFloat(f64, v);
    if (args.get("--min-cos")) |v| o.min_cos = try std.fmt.parseFloat(f32, v);
    if (args.get("--min-rerank")) |v| o.min_rerank = try std.fmt.parseFloat(f32, v);
    if (args.get("--fact-fill")) |v| o.fact_fill = try std.fmt.parseInt(usize, v, 10);
    if (args.get("--rerank-n")) |v| o.rerank_n = try std.fmt.parseInt(usize, v, 10);
    const input = try readAllStdin(arena);
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var ls = std.heap.ArenaAllocator.init(gpa);
        defer ls.deinit();
        const a = ls.allocator();
        var out: std.ArrayList(u8) = .empty;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch {
            writeAll("{\"err\":\"badjson\"}\n");
            continue;
        };
        const p = if (v == .object) v.object.get("prompt") else null;
        const q = if (p != null and p.? == .string) p.?.string else "";
        const ts = nowNs();
        const r = R.recall.recall(&ctx, a, q, o) catch |e| {
            try out.print(a, "{{\"err\":\"{s}\"}}\n", .{@errorName(e)});
            writeAll(out.items);
            continue;
        };
        try out.appendSlice(a, "{\"out\":");
        try R.jsonw.str(a, &out, r.block);
        try out.print(a, ",\"rows\":{d},\"cands\":{d},\"rerank\":\"{s}\",\"embed\":{any},\"medical_dropped\":{d},\"ms\":{d}}}\n", .{
            r.rows, r.cands, @tagName(r.used), r.embed_ok, r.dropped_medical, @divTrunc(nowNs() - ts, std.time.ns_per_ms),
        });
        writeAll(out.items);
    }
}
