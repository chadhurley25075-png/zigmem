//! The L2/L3 fold on the live path: code (never the model) folds active atoms into scenes (L2, one per subject and
//! type in a scope, ≤ 15 per scope) and a per-person persona (L3, one per subject and scope), with the store's hard
//! length caps and the prior text kept in the audit row. Runs on the writer thread from the worker's idle path with
//! the cadence of SPEC §1.2: count triggers with a warm-up (1 → 2 → 4 → N turns), an idle trigger, a session
//! end, a minimum spacing between folds and a forced fold when something new has waited too long. Idempotent: a fold
//! that changes nothing writes nothing.
const std = @import("std");
const store = @import("store");
const hh = @import("household");

/// C10/C11 thresholds (milliseconds unless named otherwise).
pub const Cadence = struct {
    /// Fold after this many newly extracted turns: 1, then 2, then 4, then every `every` (warm-up gets day-one facts in early).
    warmup: [3]u32 = .{ 1, 2, 4 },
    every: u32 = 5,
    /// Nothing extracted for this long with new atoms waiting → fold.
    idle_ms: i64 = 600_000,
    /// L2 cadence: a fold is scheduled no earlier than the last one plus this (the first fold runs at once).
    l2_min_ms: i64 = 900_000,
    /// New atoms that have waited this long fold regardless of the other triggers.
    forced_ms: i64 = 3_600_000,

    pub fn threshold(c: Cadence, folds_done: u64) u32 {
        return if (folds_done < c.warmup.len) c.warmup[@intCast(folds_done)] else c.every;
    }
};

pub const Stats = struct { scopes: usize = 0, scenes_written: usize = 0, scenes_retired: usize = 0, personas_written: usize = 0 };

const seat = "zigmem-fold";
const summary_lines = 3;

const Atom = struct { id: i64, subject: []const u8, type: []const u8, text: []const u8, date: ?[]const u8, priority: i64 };
const Group = struct { subject: []const u8, type: []const u8, atoms: std.ArrayList(Atom) = .empty };

fn groupKey(a: std.mem.Allocator, subject: []const u8, typ: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s} · {s}", .{ subject, typ });
}

/// Active atoms of one scope, grouped by (subject, type), newest first inside a group. A medical atom is folded only
/// in its own person's scope (the household write rule, applied again at fold time).
fn loadGroups(st: *store.Store, a: std.mem.Allocator, scope: []const u8) ![]Group {
    var groups: std.ArrayList(Group) = .empty;
    var s = try st.db.prepare("SELECT a.id, a.subject, a.type, a.text, a.valid_from, a.priority, coalesce(t.medical, 0) " ++
        "FROM atoms a LEFT JOIN hh_tags t ON t.atom_id = a.id WHERE a.scope = ?1 AND a.status = 'active' " ++
        "ORDER BY a.subject, a.type, a.recorded_ms DESC, a.id DESC");
    defer s.deinit();
    try s.bind(1, scope);
    while (try s.step()) {
        const subject = try a.dupe(u8, s.text(1));
        const text = try a.dupe(u8, s.text(3));
        const med = s.int(6) != 0 or hh.medical.isMedical(text);
        if (med) {
            const own = try std.fmt.allocPrint(a, "person:{s}", .{subject});
            if (!std.mem.eql(u8, own, scope)) continue;
        }
        const typ = try a.dupe(u8, s.text(2));
        const atom: Atom = .{ .id = s.int(0), .subject = subject, .type = typ, .text = text, .date = if (s.isNull(4)) null else try a.dupe(u8, s.text(4)), .priority = s.int(5) };
        if (groups.items.len > 0) {
            const g = &groups.items[groups.items.len - 1];
            if (std.mem.eql(u8, g.subject, subject) and std.mem.eql(u8, g.type, typ)) {
                try g.atoms.append(a, atom);
                continue;
            }
        }
        var g: Group = .{ .subject = subject, .type = typ };
        try g.atoms.append(a, atom);
        try groups.append(a, g);
    }
    // biggest groups first, so the per-scope cap keeps the scenes with the most behind them (name order breaks ties)
    std.mem.sort(Group, groups.items, {}, struct {
        fn lt(_: void, x: Group, y: Group) bool {
            if (x.atoms.items.len != y.atoms.items.len) return x.atoms.items.len > y.atoms.items.len;
            const c = std.mem.order(u8, x.subject, y.subject);
            if (c != .eq) return c == .lt;
            return std.mem.order(u8, x.type, y.type) == .lt;
        }
    }.lt);
    return groups.items;
}

fn sceneText(a: std.mem.Allocator, g: Group) !struct { summary: []const u8, body: []const u8 } {
    var sm: std.ArrayList(u8) = .empty;
    for (g.atoms.items[0..@min(g.atoms.items.len, summary_lines)], 0..) |x, i| {
        if (i > 0) try sm.append(a, ' ');
        try sm.appendSlice(a, x.text);
    }
    var body: std.ArrayList(u8) = .empty;
    for (g.atoms.items) |x| {
        var line: std.ArrayList(u8) = .empty;
        try line.print(a, "- [{s}] {s}\n", .{ x.date orelse "undated", x.text });
        if (body.items.len + line.items.len > store.scenes.body_cap) break;
        try body.appendSlice(a, line.items);
    }
    return .{ .summary = store.scenes.capChars(sm.items, store.scenes.summary_cap), .body = body.items };
}

fn sceneUnchanged(st: *store.Store, scope: []const u8, name: []const u8, summary: []const u8, body: []const u8) !bool {
    var q = try st.db.prepare("SELECT summary, body FROM scenes WHERE scope = ?1 AND name = ?2 AND status = 'active'");
    defer q.deinit();
    try q.bindAll(.{ scope, name });
    if (!try q.step()) return false;
    return std.mem.eql(u8, q.text(0), summary) and std.mem.eql(u8, q.text(1), body);
}

fn foldScenes(st: *store.Store, a: std.mem.Allocator, scope: []const u8, groups: []const Group, stats: *Stats) !void {
    const n_keep = @min(groups.len, store.scenes.scene_cap_per_scope);
    var keep = try a.alloc([]const u8, n_keep);
    for (groups[0..n_keep], 0..) |g, i| keep[i] = try groupKey(a, g.subject, g.type);
    // first, scenes whose group has no active atom left (or fell outside the cap) retire — never removed — so the
    // per-scope cap has room for this fold's scenes
    var retire: std.ArrayList(i64) = .empty;
    {
        var s = try st.db.prepare("SELECT id, name FROM scenes WHERE scope = ?1 AND status = 'active'");
        defer s.deinit();
        try s.bind(1, scope);
        while (try s.step()) {
            const name = s.text(1);
            var found = false;
            for (keep) |k| if (std.mem.eql(u8, k, name)) {
                found = true;
            };
            if (!found) try retire.append(a, s.int(0));
        }
    }
    for (retire.items) |id| {
        try st.db.run("UPDATE scenes SET status = 'retired', updated_ms = ?2 WHERE id = ?1", .{ id, st.nowMs() });
        try st.audit(seat, "retire", "scenes", id, "no active atoms");
        stats.scenes_retired += 1;
    }
    for (groups[0..n_keep], keep) |g, name| {
        const t = try sceneText(a, g);
        if (try sceneUnchanged(st, scope, name, t.summary, t.body)) continue;
        _ = try store.scenes.putScene(st, .{ .scope = scope, .name = name, .summary = t.summary, .body = t.body, .heat = @floatFromInt(g.atoms.items.len), .seat = seat });
        stats.scenes_written += 1;
    }
}

fn personaText(a: std.mem.Allocator, display: []const u8, groups: []const Group, subject: []const u8) ![]const u8 {
    // every active atom about the subject in this scope, most useful first (priority, then newest), ≤ persona_cap
    var all: std.ArrayList(Atom) = .empty;
    for (groups) |g| if (std.mem.eql(u8, g.subject, subject)) try all.appendSlice(a, g.atoms.items);
    if (all.items.len == 0) return "";
    std.mem.sort(Atom, all.items, {}, struct {
        fn lt(_: void, x: Atom, y: Atom) bool {
            if (x.priority != y.priority) return x.priority > y.priority;
            return x.id > y.id;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{s}: ", .{display});
    for (all.items, 0..) |x, i| {
        const piece = if (i == 0) x.text else try std.fmt.allocPrint(a, " {s}", .{x.text});
        if (out.items.len + piece.len > store.scenes.persona_cap) break;
        try out.appendSlice(a, piece);
    }
    return out.items;
}

fn foldPersonas(st: *store.Store, a: std.mem.Allocator, scope: []const u8, groups: []const Group, stats: *Stats) !void {
    var m = try st.db.prepare("SELECT id, display FROM hh_members WHERE revoked_ms IS NULL ORDER BY id");
    defer m.deinit();
    while (try m.step()) {
        const id = try a.dupe(u8, m.text(0));
        const text = try personaText(a, try a.dupe(u8, m.text(1)), groups, id);
        if (text.len == 0) continue;
        var q = try st.db.prepare("SELECT text FROM persona WHERE subject = ?1 AND scope = ?2");
        defer q.deinit();
        try q.bindAll(.{ id, scope });
        if (try q.step() and std.mem.eql(u8, q.text(0), store.scenes.capChars(text, store.scenes.persona_cap))) continue;
        _ = try store.scenes.putPersona(st, id, scope, text, seat);
        stats.personas_written += 1;
    }
}

/// Writer-thread op: one fold over every scope that has active atoms. Records `fold_last_ms` / `fold_runs` in meta.
pub fn runOp(st: *store.Store, a: std.mem.Allocator) !Stats {
    var stats: Stats = .{};
    var scopes: std.ArrayList([]const u8) = .empty;
    {
        var s = try st.db.prepare("SELECT DISTINCT scope FROM atoms WHERE status = 'active' ORDER BY scope");
        defer s.deinit();
        while (try s.step()) try scopes.append(a, try a.dupe(u8, s.text(0)));
    }
    for (scopes.items) |scope| {
        const groups = try loadGroups(st, a, scope);
        try foldScenes(st, a, scope, groups, &stats);
        try foldPersonas(st, a, scope, groups, &stats);
        stats.scopes += 1;
    }
    var b: [24]u8 = undefined;
    try st.setMeta("fold_last_ms", try std.fmt.bufPrint(&b, "{d}", .{st.nowMs()}));
    const n_runs = if (try st.getMeta(st.gpa, "fold_runs")) |v| blk: {
        defer st.gpa.free(v);
        break :blk (std.fmt.parseInt(u64, v, 10) catch 0) + 1;
    } else 1;
    try st.setMeta("fold_runs", try std.fmt.bufPrint(&b, "{d}", .{n_runs}));
    return stats;
}

pub fn lastMs(st: *store.Store) i64 {
    const v = (st.getMeta(st.gpa, "fold_last_ms") catch return 0) orelse return 0;
    defer st.gpa.free(v);
    return std.fmt.parseInt(i64, v, 10) catch 0;
}

pub fn runs(st: *store.Store) u64 {
    const v = (st.getMeta(st.gpa, "fold_runs") catch return 0) orelse return 0;
    defer st.gpa.free(v);
    return std.fmt.parseInt(u64, v, 10) catch 0;
}

test "cadence: warm-up 1, 2, 4 then every 5" {
    const c: Cadence = .{};
    try std.testing.expectEqual(@as(u32, 1), c.threshold(0));
    try std.testing.expectEqual(@as(u32, 2), c.threshold(1));
    try std.testing.expectEqual(@as(u32, 4), c.threshold(2));
    try std.testing.expectEqual(@as(u32, 5), c.threshold(3));
    try std.testing.expectEqual(@as(u32, 5), c.threshold(40));
}

test "fold: scenes per (subject, type), persona per member, caps, medical only in its own scope, idempotent, retire" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/fold.db", .{tmp.sub_path}, 0);
    defer t.allocator.free(path);
    var st = try store.Store.open(t.allocator, t.io, path, .{});
    defer st.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const house = try hh.House.init(&st);
    try house.bootstrap(a, &.{
        .{ .id = "morgan", .display = "Morgan Harper", .role = .principal, .relation = "mother" },
        .{ .id = "rowan", .display = "Rowan Harper", .role = .child },
    }, &.{ .{ .name = "morgan-air", .member = "morgan" }, .{ .name = "rowan-phone", .member = "rowan" } });
    const ins = struct {
        fn f(s: *store.Store, scope: []const u8, subject: []const u8, typ: []const u8, text: []const u8, prio: i64) !i64 {
            const id = try store.atoms.insert(s, .{ .subject = subject, .scope = scope, .type = typ, .text = text, .priority = prio, .valid_from = "2026-10-01", .seat = "t" });
            try s.db.run("INSERT INTO hh_tags(atom_id, medical) VALUES (?1, ?2)", .{ id, hh.medical.isMedical(text) });
            return id;
        }
    }.f;
    _ = try ins(&st, "person:morgan", "morgan", "fact", "[SYNTHETIC] Morgan works at the harbor office.", 50);
    _ = try ins(&st, "person:morgan", "morgan", "preference", "[SYNTHETIC] Morgan drinks her coffee black.", 50);
    const rowan_fact = try ins(&st, "person:morgan", "rowan", "fact", "[SYNTHETIC] Rowan's piano teacher is Ms. Vale.", 60);
    _ = try ins(&st, "person:morgan", "rowan", "fact", "[SYNTHETIC] Rowan takes 10 mg of ravinoxetine.", 80); // medical, not Rowan's own scope: left out
    _ = try ins(&st, "person:rowan", "rowan", "fact", "[SYNTHETIC] Rowan takes 10 mg of ravinoxetine.", 80); // own scope: folded
    const s1 = try runOp(&st, a);
    try t.expectEqual(@as(usize, 2), s1.scopes);
    try t.expectEqual(@as(usize, 4), s1.scenes_written); // morgan·fact, morgan·preference, rowan·fact (person:morgan), rowan·fact (person:rowan)
    try t.expectEqual(@as(usize, 3), s1.personas_written); // morgan + rowan in person:morgan, rowan in person:rowan
    const body = blk: {
        var q = try st.db.prepare("SELECT body FROM scenes WHERE scope = 'person:morgan' AND name = 'rowan · fact'");
        defer q.deinit();
        try t.expect(try q.step());
        break :blk try a.dupe(u8, q.text(0));
    };
    try t.expect(std.mem.indexOf(u8, body, "Ms. Vale") != null);
    try t.expect(std.mem.indexOf(u8, body, "ravinoxetine") == null);
    const own = blk: {
        var q = try st.db.prepare("SELECT text FROM persona WHERE subject = 'rowan' AND scope = 'person:rowan'");
        defer q.deinit();
        try t.expect(try q.step());
        break :blk try a.dupe(u8, q.text(0));
    };
    try t.expect(std.mem.startsWith(u8, own, "Rowan Harper: ") and std.mem.indexOf(u8, own, "ravinoxetine") != null);
    // idempotent: a second fold writes nothing
    const audits = (try st.db.oneInt("SELECT count(*) FROM audit", .{})).?;
    const s2 = try runOp(&st, a);
    try t.expectEqual(@as(usize, 0), s2.scenes_written + s2.personas_written + s2.scenes_retired);
    try t.expectEqual(audits, (try st.db.oneInt("SELECT count(*) FROM audit", .{})).?);
    // a supersession changes the scene and the persona; the prior text is in the audit row
    _ = try store.atoms.supersede(&st, rowan_fact, .{ .subject = "rowan", .scope = "person:morgan", .type = "fact", .text = "[SYNTHETIC] Rowan's piano teacher is now Mr. Okoro.", .priority = 60, .valid_from = "2026-10-05", .seat = "t" }, null);
    const s3 = try runOp(&st, a);
    try t.expectEqual(@as(usize, 1), s3.scenes_written);
    try t.expectEqual(@as(usize, 1), s3.personas_written);
    try t.expect((try st.db.oneInt("SELECT count(*) FROM audit WHERE table_name = 'scenes' AND action = 'rewrite' AND detail LIKE '%Ms. Vale%'", .{})).? == 1);
    try t.expect((try st.db.oneInt("SELECT count(*) FROM audit WHERE table_name = 'persona' AND detail LIKE 'rev=2 prev=%Ms. Vale%'", .{})).? == 1);
    // retire a whole group: the scene retires (status flip + audit), nothing is removed
    const pref = (try st.db.oneInt("SELECT id FROM atoms WHERE type = 'preference'", .{})).?;
    try store.atoms.setStatus(&st, pref, .retired, "t");
    const s4 = try runOp(&st, a);
    try t.expectEqual(@as(usize, 1), s4.scenes_retired);
    try t.expectEqual(@as(?i64, 1), try st.db.oneInt("SELECT count(*) FROM scenes WHERE status = 'retired'", .{}));
    // the per-scope cap: 20 subjects × fact in one scope → 15 active scenes
    for (0..20) |i| {
        const subj = try std.fmt.allocPrint(a, "guest{d}", .{i});
        _ = try ins(&st, "seat:kitchen", subj, "fact", try std.fmt.allocPrint(a, "[SYNTHETIC] {s} likes the blue mug.", .{subj}), 20);
    }
    _ = try runOp(&st, a);
    try t.expectEqual(@as(?i64, 15), try st.db.oneInt("SELECT count(*) FROM scenes WHERE scope = 'seat:kitchen' AND status = 'active'", .{}));
    try t.expectEqual(@as(u64, 5), runs(&st));
    try t.expect(lastMs(&st) > 0);
}
