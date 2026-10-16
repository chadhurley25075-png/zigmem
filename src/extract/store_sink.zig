//! Sink backed by the phase-1 store (src/store): atoms.insert / supersede / setStatus(retired) / BM25 search.
//! The store's own triggers make atoms non-removable, so this path proves "no hard delete" at the database too.
const std = @import("std");
const store = @import("store");
const sink_mod = @import("sink.zig");

pub const StoreSink = struct {
    st: *store.Store,
    seat: []const u8 = "zigmem-extract",

    pub fn sink(s: *StoreSink) sink_mod.Sink {
        return .{ .ptr = s, .vt = &vt };
    }
    const vt: sink_mod.Sink.VTable = .{ .insert = insertFn, .supersede = supersedeFn, .demote = demoteFn, .findSimilar = findFn };

    fn toNew(s: *StoreSink, r: sink_mod.NewRow, buf: *[200]u8) store.atoms.New {
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

    fn insertFn(ptr: *anyopaque, r: sink_mod.NewRow) anyerror!i64 {
        const s: *StoreSink = @ptrCast(@alignCast(ptr));
        var buf: [200]u8 = undefined;
        return store.atoms.insert(s.st, s.toNew(r, &buf));
    }

    fn supersedeFn(ptr: *anyopaque, old: i64, r: sink_mod.NewRow) anyerror!i64 {
        const s: *StoreSink = @ptrCast(@alignCast(ptr));
        var buf: [200]u8 = undefined;
        return store.atoms.supersede(s.st, old, s.toNew(r, &buf), null);
    }

    fn demoteFn(ptr: *anyopaque, id: i64, by: i64, reason: []const u8) anyerror!void {
        const s: *StoreSink = @ptrCast(@alignCast(ptr));
        try store.atoms.setStatus(s.st, id, .retired, s.seat);
        var b: [400]u8 = undefined;
        const d = std.fmt.bufPrint(&b, "demoted by {d}: {s}", .{ by, reason[0..@min(reason.len, 300)] }) catch "demoted";
        try s.st.audit(s.seat, "demote", "atoms", id, d);
    }

    fn findFn(ptr: *anyopaque, a: std.mem.Allocator, scope: []const u8, subject: []const u8, text: []const u8, limit: usize) anyerror![]sink_mod.Cand {
        const s: *StoreSink = @ptrCast(@alignCast(ptr));
        _ = subject; // the bare store sink (gate tool) has no household policy: this scope only
        const names = [1][]const u8{scope};
        const hits = try store.atoms.search(s.st, a, store.Scope.one(&names), text, .{ .limit = 20 });
        const q = try sink_mod.contentWords(a, text);
        var out: std.ArrayList(sink_mod.Cand) = .empty;
        for (hits) |h| {
            if (out.items.len >= limit) break;
            // Same candidate rule as MemSink: at least two shared content words (BM25 OR-queries match on one).
            if (sink_mod.shared(q, try sink_mod.contentWords(a, h.text)) < 2) continue;
            try out.append(a, .{ .id = h.id, .subject = h.subject, .text = h.text, .scope = h.scope });
        }
        return out.items;
    }
};

fn row(subject: []const u8, text: []const u8) sink_mod.NewRow {
    return .{ .subject = subject, .scope = "syn", .type = "fact", .text = text, .priority = 50, .valid_from = "2026-10-03", .status = .active, .prov = .{ .extractor = "zigmem-extract/t", .model = "m", .prompt_version = "v", .prompt_sha = @splat(3), .src_turn_sha = @splat(4), .run_id = "run-t", .turn_id = 9 } };
}

test "store sink: provenance stamped, supersede/demote keep rows, DELETE refused by the store" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/x.db", .{tmp.sub_path}, 0);
    defer t.allocator.free(path);
    var st = try store.Store.open(t.allocator, t.io, path, .{});
    defer st.close();
    var ss: StoreSink = .{ .st = &st };
    const s = ss.sink();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = try s.insert(row("Leo", "Leo has soccer practice on Wednesdays."));
    const cands = try s.findSimilar(arena.allocator(), "syn", "Leo", "Leo soccer practice Tuesdays", 5);
    try t.expectEqual(@as(usize, 1), cands.len);
    const b = try s.supersede(a, row("Leo", "Leo has soccer practice on Tuesdays."));
    const c = try s.insert(row("Morgan", "Morgan's car needs new tires."));
    const d = try s.insert(row("Alex", "Alex's truck needs new tires."));
    try s.demote(c, d, "corrected");
    try t.expectEqual(@as(?i64, 4), try st.db.oneInt("SELECT count(*) FROM atoms", .{}));
    try t.expectEqual(@as(?i64, b), try st.db.oneInt("SELECT superseded_by FROM atoms WHERE id = ?1", .{a}));
    try t.expectEqual(@as(?i64, 1), try st.db.oneInt("SELECT count(*) FROM atoms WHERE status = 'retired'", .{}));
    try t.expectEqual(@as(?i64, 4), try st.db.oneInt("SELECT count(*) FROM atoms WHERE prompt_sha IS NOT NULL AND run_id = 'run-t' AND src_l0 LIKE 'turn=9 sha=%' AND extractor LIKE 'zigmem-extract/t|m|p:v'", .{}));
    try t.expectError(error.CrossSubject, s.supersede(b, row("Morgan", "Morgan has soccer practice on Tuesdays.")));
    try t.expect(std.meta.isError(st.db.exec("DELETE" ++ " FROM atoms WHERE id = 1")));
}
