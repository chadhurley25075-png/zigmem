//! Bench/shadow import: JSONL rows {"src","id","date","cite","text"} (exported read-only from the live engines) → atoms in
//! scope `household` (subject = the one family member a row names, else `household`) + nomic vectors. Resumable: the line
//! count done is kept in meta `import_done:<name>`. Batches of 64 per transaction; `<private>` is stripped at write by the store.
const std = @import("std");
const store = @import("store");
const privacy = @import("privacy");
const Embedder = @import("embed.zig").Embedder;
const Store = store.Store;

pub const Stats = struct { lines: usize = 0, inserted: usize = 0, skipped: usize = 0, embed_fail: usize = 0 };

pub fn subjectOf(gates: *privacy.Gates, a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const t = try privacy.re.Text.init(a, text);
    const n = privacy.medscope.named(gates, t);
    return if (n.count() == 1) privacy.medscope.nameOf(n.first().?) else "household";
}

const Item = struct { src: []const u8, date: ?[]const u8, cite: []const u8, text: []const u8 };

pub fn importJsonl(gpa: std.mem.Allocator, st: *Store, gates: *privacy.Gates, emb: Embedder, name: []const u8, data: []const u8, run_id: []const u8, limit: ?usize) !Stats {
    var stats: Stats = .{};
    var key_buf: [128]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "import_done:{s}", .{name});
    const done: usize = if (try st.getMeta(gpa, key)) |v| blk: {
        defer gpa.free(v);
        break :blk std.fmt.parseInt(usize, v, 10) catch 0;
    } else 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    var line_no: usize = 0;
    var batch: std.ArrayList(Item) = .empty;
    defer batch.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    while (true) {
        const ln = it.next();
        if (ln) |l| {
            if (l.len == 0) continue;
            line_no += 1;
            if (line_no <= done) continue;
            if (limit) |lim| if (line_no > done + lim) break;
            const a = arena.allocator();
            const v = std.json.parseFromSliceLeaky(std.json.Value, a, l, .{}) catch {
                stats.skipped += 1;
                continue;
            };
            const g = struct {
                fn s(o: std.json.Value, k: []const u8) ?[]const u8 {
                    const x = o.object.get(k) orelse return null;
                    return if (x == .string) x.string else null;
                }
            };
            const text = g.s(v, "text") orelse {
                stats.skipped += 1;
                continue;
            };
            const date = g.s(v, "date");
            try batch.append(gpa, .{ .src = g.s(v, "src") orelse "import", .date = if (date != null and date.?.len > 0) date else null, .cite = g.s(v, "cite") orelse "", .text = text });
        }
        if (batch.items.len == 64 or (ln == null and batch.items.len > 0)) {
            try flush(gpa, arena.allocator(), st, gates, emb, batch.items, run_id, &stats);
            stats.lines += batch.items.len;
            var nb: [24]u8 = undefined;
            try st.setMeta(key, try std.fmt.bufPrint(&nb, "{d}", .{line_no}));
            batch.clearRetainingCapacity();
            _ = arena.reset(.retain_capacity);
            if (stats.lines % 5120 == 0) std.debug.print("import {s}: {d} rows (line {d})\n", .{ name, stats.lines, line_no });
        }
        if (ln == null) break;
    }
    return stats;
}

fn flush(gpa: std.mem.Allocator, a: std.mem.Allocator, st: *Store, gates: *privacy.Gates, emb: Embedder, items: []const Item, run_id: []const u8, stats: *Stats) !void {
    _ = gpa;
    const texts = try a.alloc([]const u8, items.len);
    for (items, 0..) |x, i| {
        var n = @min(x.text.len, 6000);
        while (n > 0 and n < x.text.len and (x.text[n] & 0xC0) == 0x80) n -= 1;
        texts[i] = try std.fmt.allocPrint(a, "search_document: {s}", .{x.text[0..n]});
    }
    var vecs: ?[][]f32 = null;
    var tries: usize = 0;
    while (tries < 3) : (tries += 1) {
        vecs = emb.embed(a, texts) catch null;
        if (vecs != null) break;
    }
    if (vecs == null) stats.embed_fail += items.len;
    try st.db.exec("BEGIN");
    errdefer st.db.exec("ROLLBACK") catch {};
    for (items, 0..) |x, i| {
        var ext: [64]u8 = undefined;
        const id = try store.atoms.insert(st, .{
            .subject = try subjectOf(gates, a, x.text),
            .scope = "household",
            .type = "fact",
            .text = x.text,
            .valid_from = x.date,
            .src_l0 = x.cite,
            .extractor = try std.fmt.bufPrint(&ext, "import:{s}", .{x.src}),
            .run_id = run_id,
            .seat = "import",
        });
        if (vecs) |vs| try store.vec.put(st, .atom, id, vs[i]);
        stats.inserted += 1;
    }
    try st.db.exec("COMMIT");
}
