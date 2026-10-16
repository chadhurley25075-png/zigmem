//! zigmem-household-gate: the phase-5 gate on a throwaway SYNTHETIC database. (1) adversarial questions from every
//! seat, twice: the real scoped search, and a scope-blind candidate list (every row in the file) to prove the row gate
//! alone holds; (2) the permission matrix against oracle.zig's literal table; (3) promotion/admin flows; (4) live
//! revocation, then (1)+(2) again; (5) audit: one row per cross-scope read, no query text. Exit 1 on any failure.
const std = @import("std");
const store = @import("store");
const House = @import("house.zig").House;
const Row = @import("house.zig").Row;
const fixture = @import("fixture.zig");
const oracle = @import("oracle.zig");

const Truth = fixture.Truth;

const G = struct {
    a: std.mem.Allocator,
    h: House,
    truths: std.ArrayList(Truth) = .empty,
    revoked: std.ArrayList([]const u8) = .empty,
    fails: std.ArrayList([]const u8) = .empty,
    queries: usize = 0,
    checks_rows: usize = 0,
    leaks: usize = 0,
    forbidden_ok: usize = 0,
    revoked_denied: usize = 0,
    misses: usize = 0,
    expected_hits: usize = 0,
    overblock: usize = 0,
    errors: usize = 0,
    xread_expected: i64 = 0,
    matrix_cells: usize = 0,
    matrix_fail: usize = 0,
    flows: usize = 0,
    flow_fail: usize = 0,
    medical_served: usize = 0,

    fn fail(g: *G, comptime fmt: []const u8, args: anytype) void {
        if (g.fails.items.len < 40) g.fails.append(g.a, std.fmt.allocPrint(g.a, fmt, args) catch "oom") catch {};
    }

    fn isRevoked(g: *G, seat: []const u8) bool {
        for (g.revoked.items) |s| if (std.mem.eql(u8, s, seat)) return true;
        return false;
    }

    fn truth(g: *G, id: i64) ?Truth {
        for (g.truths.items) |t| if (t.id == id) return t;
        return null;
    }

    /// The leak oracle for one served row.
    fn judge(g: *G, seat: []const u8, q: oracle.Q, r: Row, mode: []const u8) void {
        g.checks_rows += 1;
        const t = g.truth(r.id) orelse return g.leak(seat, q, r, mode, "row not in the fixture");
        if (g.isRevoked(seat)) return g.leak(seat, q, r, mode, "revoked seat got a row");
        if (!t.active) return g.leak(seat, q, r, mode, "inactive row served");
        if (!oracle.canRead(seat, t.scope)) return g.leak(seat, q, r, mode, "scope not readable by this seat");
        if (!t.med) return;
        g.medical_served += 1;
        const gt = q.gt orelse return g.leak(seat, q, r, mode, "medical row for a question with no single subject");
        if (!std.mem.eql(u8, t.truth, gt)) return g.leak(seat, q, r, mode, "medical row about someone else");
        const ps = std.fmt.allocPrint(g.a, "person:{s}", .{gt}) catch return;
        if (!oracle.canRead(seat, ps)) return g.leak(seat, q, r, mode, "medical row of a person this seat may not read");
    }

    fn leak(g: *G, seat: []const u8, q: oracle.Q, r: Row, mode: []const u8, why: []const u8) void {
        g.leaks += 1;
        g.fail("LEAK [{s}] seat={s} q=\"{s}\" row={d} scope={s} subject={s}: {s}", .{ mode, seat, q.text, r.id, r.scope, r.subject, why });
    }

    fn allRows(g: *G) ![]Row {
        var out: std.ArrayList(Row) = .empty;
        var s = try g.h.st.db.prepare("SELECT id, scope, subject, type, text, status FROM atoms ORDER BY id");
        defer s.deinit();
        while (try s.step()) try out.append(g.a, .{ .id = s.int(0), .scope = try g.a.dupe(u8, s.text(1)), .subject = try g.a.dupe(u8, s.text(2)), .type = try g.a.dupe(u8, s.text(3)), .text = try g.a.dupe(u8, s.text(4)), .status = std.meta.stringToEnum(store.atoms.Status, s.text(5)) orelse .pending_review });
        return out.items;
    }

    fn xreads(g: *G) i64 {
        return (g.h.st.db.oneInt("SELECT count(*) FROM audit WHERE action = 'xread'", .{}) catch null) orelse -1;
    }

    /// Every fixture question from every seat, real search (mode A) + scope-blind rows (mode B).
    fn suite(g: *G, phase: []const u8) !void {
        const every = try g.allRows();
        for (oracle.rules) |rl| {
            const seat = rl.seat;
            const qs = try oracle.questions(g.a, seat);
            for (qs) |q| {
                g.queries += 1;
                // mode A: the real path
                if (g.h.recall(g.a, seat, q.text, .{ .requested = q.requested, .limit = 20 })) |res| {
                    if (q.expect_forbidden) g.fail("[{s}] seat={s} forged scope {s} was not refused", .{ phase, seat, q.requested.?[0] });
                    if (q.expect_forbidden) g.leaks += 1;
                    for (res.rows) |r| g.judge(seat, q, r, "A");
                    const scopes: []const []const u8 = q.requested orelse &oracle.all_scopes;
                    for (scopes) |s| if (oracle.canRead(seat, s) and oracle.cross(seat, s)) {
                        g.xread_expected += 1;
                    };
                } else |e| switch (e) {
                    error.Forbidden => {
                        if (q.expect_forbidden) g.forbidden_ok += 1 else {
                            g.errors += 1;
                            g.fail("[{s}] seat={s} q=\"{s}\" refused unexpectedly", .{ phase, seat, q.text });
                        }
                    },
                    error.SeatRevoked, error.MemberRevoked => {
                        if (g.isRevoked(seat)) g.revoked_denied += 1 else {
                            g.errors += 1;
                            g.fail("[{s}] seat={s} denied as revoked but is not", .{ phase, seat });
                        }
                    },
                    else => {
                        g.errors += 1;
                        g.fail("[{s}] seat={s} q=\"{s}\" error {s}", .{ phase, seat, q.text, @errorName(e) });
                    },
                }
                if (q.requested != null) continue;
                // mode B: scope-blind candidates (a broken or future retriever) — the row gate alone must hold
                if (g.h.gateFor(g.a, seat, q.text, every)) |res| {
                    for (res.rows) |r| g.judge(seat, q, r, "B");
                    if (!g.isRevoked(seat)) try g.usefulness(seat, q, res.rows, phase);
                } else |e| switch (e) {
                    error.SeatRevoked, error.MemberRevoked => {
                        if (g.isRevoked(seat)) g.revoked_denied += 1 else g.errors += 1;
                    },
                    else => {
                        g.errors += 1;
                        g.fail("[{s}] B seat={s} error {s}", .{ phase, seat, @errorName(e) });
                    },
                }
            }
        }
    }

    /// Mode B serves everything legitimate: every clean medical row of the question's person this seat may read, and
    /// every readable non-medical row (no over-blocking).
    fn usefulness(g: *G, seat: []const u8, q: oracle.Q, served: []const Row, phase: []const u8) !void {
        for (g.truths.items) |t| {
            if (!t.active or !oracle.canRead(seat, t.scope)) continue;
            // personal rows (subject = a household member) answer only questions about that member
            const personal = for (fixture.person_ids) |p| {
                if (std.mem.eql(u8, p, t.subject)) break true;
            } else false;
            const want = if (t.med) blk: {
                const gt = q.gt orelse break :blk false;
                if (!q.medical or !t.clean or !std.mem.eql(u8, t.truth, gt) or !std.mem.eql(u8, t.subject, gt)) break :blk false;
                break :blk oracle.canRead(seat, try std.fmt.allocPrint(g.a, "person:{s}", .{gt}));
            } else if (personal) (q.gt != null and std.mem.eql(u8, q.gt.?, t.subject) and !namesOther(g.a, t.text, t.subject)) else true;
            if (!want) continue;
            g.expected_hits += 1;
            var found = false;
            for (served) |r| if (r.id == t.id) {
                found = true;
            };
            if (!found) {
                if (t.med) g.misses += 1 else g.overblock += 1;
                g.fail("[{s}] MISS seat={s} q=\"{s}\" row={d} \"{s}\"", .{ phase, seat, q.text, t.id, t.text });
            }
        }
    }

    /// Read + write every scope from every seat; compare with the oracle's literal table.
    fn matrix(g: *G, phase: []const u8) !void {
        for (oracle.rules) |rl| for (oracle.all_scopes) |scope| {
            const seat = rl.seat;
            const dead = g.isRevoked(seat);
            const req = try g.a.alloc([]const u8, 1);
            req[0] = scope;
            g.matrix_cells += 1;
            const read_ok = if (g.h.recall(g.a, seat, "matrix probe favorite", .{ .requested = req })) |_| true else |_| false;
            const want_read = !dead and oracle.canRead(seat, scope);
            if (read_ok != want_read) {
                g.matrix_fail += 1;
                g.fail("[{s}] MATRIX read seat={s} scope={s} got={} want={}", .{ phase, seat, scope, read_ok, want_read });
            }
            g.matrix_cells += 1;
            const subject = if (std.mem.startsWith(u8, scope, "person:")) scope[7..] else rl.member orelse "household";
            const text = try std.fmt.allocPrint(g.a, "[SYNTHETIC] matrix probe {s} wrote {s} ({s})", .{ seat, scope, phase });
            const wrote: ?i64 = g.h.write(g.a, seat, .{ .scope = scope, .subject = subject, .text = text }) catch null;
            const want_write = !dead and oracle.canWrite(seat, scope);
            if ((wrote != null) != want_write) {
                g.matrix_fail += 1;
                g.fail("[{s}] MATRIX write seat={s} scope={s} got={} want={}", .{ phase, seat, scope, wrote != null, want_write });
            }
            if (wrote) |id| try g.truths.append(g.a, .{ .id = id, .scope = scope, .subject = subject, .truth = subject, .med = false, .clean = true, .text = text });
        };
        // admin + promotion-decision cells: principals only (and nobody revoked)
        for (oracle.rules) |rl| {
            const seat = rl.seat;
            const want = !g.isRevoked(seat) and oracle.principal(seat);
            g.matrix_cells += 1;
            // the id is invalid on purpose: a seat that passes the admin check fails validation (BadId) and the
            // registry is never changed by the probe; any other seat must be refused before validation
            const got = g.h.addMember(g.a, seat, .{ .id = "Not A Valid Id", .display = "Synthetic Visitor", .role = .guest });
            const passed_admin = if (got) |_| true else |e| e == error.BadId;
            if (passed_admin != want) {
                g.matrix_fail += 1;
                g.fail("[{s}] MATRIX admin seat={s} got={} want={}", .{ phase, seat, passed_admin, want });
            }
            g.matrix_cells += 1;
            const revoke_principal = g.h.revokeMember(g.a, seat, "morgan");
            if (revoke_principal) |_| {
                g.matrix_fail += 1;
                g.fail("[{s}] MATRIX seat={s} revoked a principal", .{ phase, seat });
            } else |_| {}
        }
    }

    fn flow(g: *G, name: []const u8, ok: bool) void {
        g.flows += 1;
        if (!ok) {
            g.flow_fail += 1;
            g.fail("FLOW failed: {s}", .{name});
        }
    }

    fn idOf(g: *G, scope: []const u8, needle: []const u8) i64 {
        for (g.truths.items) |t| if (std.mem.eql(u8, t.scope, scope) and std.mem.indexOf(u8, t.text, needle) != null) return t.id;
        unreachable;
    }

    fn status(g: *G, id: i64) []const u8 {
        var s = g.h.st.db.prepare("SELECT status FROM atoms WHERE id = ?1") catch return "?";
        defer s.deinit();
        s.bind(1, id) catch return "?";
        return if (s.step() catch false) (g.a.dupe(u8, s.text(0)) catch "?") else "?";
    }

    fn flows_(g: *G) !void {
        const h = g.h;
        const a = g.a;
        const color = g.idOf("person:rowan", "favorite color");
        const req = h.promoteRequest(a, "rowan-phone", color) catch -1;
        g.flow("rowan requests promotion of her own plain fact", req > 0);
        g.flow("rowan cannot approve", if (h.promoteDecide(a, "rowan-phone", req, true)) |_| false else |e| e == error.Forbidden);
        g.flow("kitchen cannot approve", if (h.promoteDecide(a, "kitchen", req, true)) |_| false else |e| e == error.Forbidden);
        const pending_before = (try h.st.db.oneInt("SELECT count(*) FROM atoms WHERE scope = 'household' AND text LIKE '%Rowan''s favorite color%'", .{})).?;
        g.flow("nothing reaches household before a decision", pending_before == 0);
        const new_id = (h.promoteDecide(a, "morgan-air", req, true) catch null) orelse -1;
        g.flow("morgan approves → a new household atom", new_id > 0);
        if (new_id > 0) try g.truths.append(a, .{ .id = new_id, .scope = "household", .subject = "rowan", .truth = "rowan", .med = false, .clean = true, .text = "promoted favorite color" });
        g.flow("the decision is one-shot", if (h.promoteDecide(a, "alex-term", req, true)) |_| false else |e| e == error.NotPending);
        const seen = h.recall(a, "taylor-phone", "Rowan favorite color", .{ .requested = &.{"household"} }) catch null;
        var found = false;
        if (seen) |r| for (r.rows) |x| if (x.id == new_id) {
            found = true;
        };
        g.flow("a sister reads the promoted household atom", found);
        g.flow("the guest cannot read household", if (h.recall(a, "guest-phone", "favorite color", .{ .requested = &.{"household"} })) |_| false else |e| e == error.Forbidden);
        const med = g.idOf("person:rowan", "20 mg");
        g.flow("medical never promotes", if (h.promoteRequest(a, "rowan-phone", med)) |_| false else |e| e == error.MedicalNotShareable);
        g.flow("principal medical never promotes either", if (h.promoteRequest(a, "morgan-air", med)) |_| false else |e| e == error.MedicalNotShareable);
        const morgans = g.idOf("person:morgan", "favorite color");
        g.flow("another person's atom is invisible to a child", if (h.promoteRequest(a, "rowan-phone", morgans)) |_| false else |e| e == error.NoSuchAtom);
        const r2 = h.promoteRequest(a, "alex-term", g.idOf("person:alex", "favorite color")) catch -1;
        g.flow("alex refuses his own request → nothing shared", (h.promoteDecide(a, "alex-term", r2, false) catch 1) == null);
        g.flow("household is never written directly, even by a principal", if (h.write(a, "morgan-air", .{ .scope = "household", .subject = "household", .text = "[SYNTHETIC] direct" })) |_| false else |e| e == error.Forbidden);
        const mis = h.write(a, "rowan-phone", .{ .scope = "person:rowan", .subject = "morgan", .text = "[SYNTHETIC] Mom started 5 mg of trivexine." }) catch -1;
        if (mis > 0) try g.truths.append(a, .{ .id = mis, .scope = "person:rowan", .subject = "morgan", .truth = "morgan", .med = true, .clean = false, .active = false, .text = "mis-scoped medical" });
        g.flow("a medical fact about Morgan written into Rowan's scope lands pending_review", mis > 0 and std.mem.eql(u8, g.status(mis), "pending_review"));
        const unk = h.write(a, "alex-term", .{ .scope = "person:alex", .subject = "user", .text = "[SYNTHETIC] User likes pecan pie." }) catch -1;
        if (unk > 0) try g.truths.append(a, .{ .id = unk, .scope = "person:alex", .subject = "user", .truth = "unknown", .med = false, .clean = false, .active = false, .text = "unknown subject" });
        g.flow("an unresolved subject (\"User\") lands pending_review", unk > 0 and std.mem.eql(u8, g.status(unk), "pending_review"));
        g.flow("a child cannot revoke a member", if (h.revokeMember(a, "rowan-phone", "taylor-k")) |_| false else |e| e == error.Forbidden);
        g.flow("alex cannot revoke morgan (both principals)", if (h.revokeMember(a, "alex-term", "morgan")) |_| false else |e| e == error.PrincipalNotRevocable);
        g.flow("morgan cannot revoke alex", if (h.revokeMember(a, "morgan-air", "alex")) |_| false else |e| e == error.PrincipalNotRevocable);
        g.flow("a child cannot revoke another child's seat", if (h.revokeSeat(a, "rowan-phone", "quinn-mac")) |_| false else |e| e == error.Forbidden);
        g.flow("an unknown seat is refused", if (h.recall(a, "nobody-seat", "meds", .{})) |_| false else |e| e == error.UnknownSeat);
        // live revocation (no restart, next call)
        g.flow("morgan revokes the guest member", if (h.revokeMember(a, "morgan-air", "taylor-k")) |_| true else |_| false);
        try g.revoked.append(a, "guest-phone");
        g.flow("quinn revokes her own old seat", if (h.revokeSeat(a, "quinn-mac", "quinn-ipad-old")) |_| true else |_| false);
        try g.revoked.append(a, "quinn-ipad-old");
        g.flow("revocation is permanent at the database", if (h.st.db.run("UPDATE hh_seats SET revoked_ms = NULL WHERE name = 'quinn-ipad-old'", .{})) |_| false else |_| true);
        g.flow("members are never deleted", if (h.st.db.run("DELETE FROM hh_members WHERE id = 'taylor-k'", .{})) |_| false else |_| true);
        g.flow("principals still read the revoked guest's rows (history kept)", blk: {
            const r = h.recall(a, "morgan-air", "Taylor Kessler favorite color", .{ .requested = &.{"person:taylor-k"} }) catch break :blk false;
            break :blk r.rows.len > 0;
        });
    }
};

/// Independent restatement of "a personal line naming someone else is withheld": any other fixture person id
/// appearing in the lowercased text (substring; over-matching only makes the oracle expect less, never more).
fn namesOther(a: std.mem.Allocator, text: []const u8, subject: []const u8) bool {
    const low = std.ascii.allocLowerString(a, text) catch return true;
    for (fixture.person_ids) |p| if (!std.mem.eql(u8, p, subject) and std.mem.indexOf(u8, low, p) != null) return true;
    return false;
}

fn jstr(a: std.mem.Allocator, b: *std.ArrayList(u8), s: []const u8) !void {
    try b.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try b.appendSlice(a, "\\\""),
        '\\' => try b.appendSlice(a, "\\\\"),
        0...0x1f => try b.print(a, "\\u{x:0>4}", .{c}),
        else => try b.append(a, c),
    };
    try b.append(a, '"');
}

fn emit(s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const n = std.c.write(1, s[off..].ptr, s.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3 or !std.mem.eql(u8, args[1], "--db")) {
        std.debug.print("usage: zigmem-household-gate --db NEW_FILE (synthetic, throwaway)\n", .{});
        std.process.exit(2);
    }
    const path = try a.dupeSentinel(u8, args[2], 0);
    var st = try store.Store.open(a, init.io, path, .{});
    defer st.close();
    const h = try House.init(&st);
    var g: G = .{ .a = a, .h = h };
    try g.truths.appendSlice(a, try fixture.load(a, h));
    const x0 = g.xreads();
    try g.suite("p1");
    try g.matrix("p1");
    try g.flows_();
    try g.suite("p2-after-revocation");
    try g.matrix("p2-after-revocation");
    const xread_got = g.xreads() - x0;
    // matrix reads that succeeded are cross-scope reads too: count them from the oracle
    var matrix_x: i64 = 0;
    for ([_]bool{ false, true }) |p2| for (oracle.rules) |rl| for (oracle.all_scopes) |s| {
        const dead = p2 and (std.mem.eql(u8, rl.seat, "guest-phone") or std.mem.eql(u8, rl.seat, "quinn-ipad-old"));
        if (!dead and oracle.canRead(rl.seat, s) and oracle.cross(rl.seat, s)) matrix_x += 1;
    };
    const flows_xread: i64 = 1; // the flows make one cross-scope read: morgan-air → person:taylor-k
    const xread_want = g.xread_expected + matrix_x + flows_xread;
    const leaked_text = (try st.db.oneInt("SELECT count(*) FROM audit WHERE detail LIKE '%meds%' OR detail LIKE '%prescription%' OR detail LIKE '%favorite%'", .{})).?;
    const audit_ok = xread_got == xread_want and leaked_text == 0;
    if (!audit_ok) g.fail("AUDIT xread got={d} want={d}, query text in audit={d}", .{ xread_got, xread_want, leaked_text });
    const pass = g.leaks == 0 and g.matrix_fail == 0 and g.flow_fail == 0 and g.errors == 0 and g.misses == 0 and g.overblock == 0 and audit_ok and g.queries >= 200;
    var b: std.ArrayList(u8) = .empty;
    try b.print(a, "{{\"gate\":\"phase5\",\"pass\":{},\"queries\":{d},\"rows_judged\":{d},\"leaks\":{d},\"medical_rows_served\":{d}," ++
        "\"forged_scope_refused\":{d},\"revoked_denied\":{d},\"legit_expected\":{d},\"legit_missed_medical\":{d},\"overblocked_plain\":{d}," ++
        "\"unexpected_errors\":{d},\"matrix_cells\":{d},\"matrix_fail\":{d},\"flows\":{d},\"flow_fail\":{d}," ++
        "\"xread_audit_rows\":{d},\"xread_expected\":{d},\"query_text_in_audit\":{d},\"fixture_rows\":{d},\"failures\":[", .{
        pass, g.queries, g.checks_rows, g.leaks, g.medical_served, g.forbidden_ok, g.revoked_denied, g.expected_hits, g.misses, g.overblock,
        g.errors, g.matrix_cells, g.matrix_fail, g.flows, g.flow_fail, xread_got, xread_want, leaked_text, g.truths.items.len,
    });
    for (g.fails.items, 0..) |f, i| {
        if (i > 0) try b.append(a, ',');
        try jstr(a, &b, f);
    }
    try b.appendSlice(a, "]}\n");
    emit(b.items);
    std.process.exit(if (pass) 0 else 1);
}
