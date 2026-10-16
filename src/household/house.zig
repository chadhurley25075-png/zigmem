//! The household layer over the store: the seat (from a verified token) is the only identity; membership is read live
//! on every call (a revocation takes effect on the next request); scopes come from policy, never from the request;
//! the medical person-scope rule runs on every row; every cross-scope read and every denial leaves an audit row
//! (scope + a query hash, never the query text). Shared memory arrives only by an approved promotion.
const std = @import("std");
const store = @import("store");
const policy = @import("policy.zig");
const resolve = @import("resolve.zig");
const medical = @import("medical.zig");
const schema = @import("schema.zig");
const Actor = policy.Actor;
const Status = store.atoms.Status;

pub const Error = error{ Forbidden, NoSuchAtom, NotActive, AlreadyShared, MedicalNotShareable, BadId, Exists, PrincipalNotRevocable, NotPending, BootstrapDone };

pub const Loaded = struct { reg: policy.Registry, rel: resolve.Relations };

pub const Row = struct {
    id: i64,
    scope: []const u8,
    subject: []const u8,
    type: []const u8 = "fact",
    text: []const u8,
    status: Status = .active,
    score: f64 = 0,
};

pub const Drops = struct {
    inactive: usize = 0,
    scope: usize = 0,
    medical_no_target: usize = 0,
    medical_other_subject: usize = 0,
    medical_unreadable: usize = 0,
    medical_text_names_other: usize = 0,
    personal_other_subject: usize = 0,
};

pub const Gated = struct { rows: []Row, target: resolve.Target, drops: Drops };

pub const NewAtom = struct {
    scope: []const u8,
    subject: []const u8,
    type: []const u8 = "fact",
    text: []const u8,
    /// A writer may mark a row medical; it can never mark a medical-looking text as not medical.
    medical: ?bool = null,
    priority: i64 = 50,
};

pub const RecallOpts = struct { requested: ?[]const []const u8 = null, limit: u32 = 10, fetch: u32 = 50 };

fn splitList(a: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '|');
    while (it.next()) |x| if (x.len > 0) try out.append(a, try a.dupe(u8, x));
    return out.items;
}

fn qhash(q: []const u8) [8]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(q, &d, .{});
    var out: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{d[0..4]}) catch unreachable;
    return out;
}

pub const House = struct {
    st: *store.Store,

    pub fn init(st: *store.Store) !House {
        try schema.migrate(st);
        return .{ .st = st };
    }

    /// Fresh registry from the database (arena-owned). Called on every request: revocation is live.
    pub fn load(h: House, a: std.mem.Allocator) !Loaded {
        var ms: std.ArrayList(policy.Member) = .empty;
        var rel: resolve.Relations = .{};
        var s = try h.st.db.prepare("SELECT id, display, aliases, role, relation, revoked_ms IS NOT NULL FROM hh_members ORDER BY id");
        defer s.deinit();
        while (try s.step()) {
            const id = try a.dupe(u8, s.text(0));
            const role = std.meta.stringToEnum(policy.Role, s.text(3)) orelse .guest;
            const relation = s.text(4);
            if (role == .principal and std.mem.eql(u8, relation, "mother")) rel.mother = id;
            if (role == .principal and std.mem.eql(u8, relation, "father")) rel.father = id;
            try ms.append(a, .{ .id = id, .display = try a.dupe(u8, s.text(1)), .aliases = try splitList(a, s.text(2)), .role = role, .revoked = s.int(5) != 0 });
        }
        var ss: std.ArrayList(policy.Seat) = .empty;
        var q = try h.st.db.prepare("SELECT name, member, revoked_ms IS NOT NULL FROM hh_seats ORDER BY name");
        defer q.deinit();
        while (try q.step()) try ss.append(a, .{ .name = try a.dupe(u8, q.text(0)), .member = if (q.isNull(1)) null else try a.dupe(u8, q.text(1)), .revoked = q.int(2) != 0 });
        return .{ .reg = .{ .members = ms.items, .seats = ss.items }, .rel = rel };
    }

    fn deny(h: House, seat: []const u8, why: []const u8) void {
        h.st.audit(seat, "deny", "household", null, why) catch {};
    }

    /// The actor for a seat, or the reason it is refused (audited).
    pub fn actor(h: House, L: Loaded, seat: []const u8) !Actor {
        return policy.actorFor(L.reg, seat) catch |e| {
            h.deny(seat, @errorName(e));
            return e;
        };
    }

    pub fn isMedicalRow(h: House, id: i64, text: []const u8) bool {
        if (medical.isMedical(text)) return true;
        const tag = h.st.db.oneInt("SELECT medical FROM hh_tags WHERE atom_id = ?1", .{id}) catch return true;
        return (tag orelse 0) != 0;
    }

    /// The row gate (also run on rows that did not come from a scoped search: defense in depth).
    /// Medical rows (tag or text): only for the ONE person the question is about, from a scope that may read that
    /// person, and never when the line names anyone else. Every other row whose subject is a household member is a
    /// personal row: served when the question is about that member — one named person, or a set (`many`: a group word,
    /// an unresolved relative word, several names) that contains them — so a medical fact the classifier cannot
    /// recognise (a new drug name, no cue word, no tag) still never answers a question about someone else.
    /// `narrow` = the one person scope a request was narrowed to (a question naming nobody is then about them).
    pub fn gate(h: House, a: std.mem.Allocator, L: Loaded, act: Actor, query: []const u8, rows: []const Row, narrow: ?[]const u8) !Gated {
        const tg = resolve.targetOr(L.reg, L.rel, act, query, narrow orelse act.member);
        var out: std.ArrayList(Row) = .empty;
        var d: Drops = .{};
        for (rows) |r| {
            if (r.status != .active) {
                d.inactive += 1;
                continue;
            }
            if (!policy.mayRead(act, r.scope)) {
                d.scope += 1;
                continue;
            }
            if (h.isMedicalRow(r.id, r.text)) {
                const t = switch (tg) {
                    .person => |p| p,
                    .many, .none => {
                        d.medical_no_target += 1;
                        continue;
                    },
                };
                if (!std.mem.eql(u8, r.subject, t)) {
                    d.medical_other_subject += 1;
                    continue;
                }
                const ps = try std.fmt.allocPrint(a, "person:{s}", .{t});
                if (!policy.mayRead(act, ps)) {
                    d.medical_unreadable += 1;
                    continue;
                }
                const nm = resolve.named(L.reg, r.text);
                // a medical line that names anyone else (alone or beside the target) is never served
                if (nm.other(L.reg, t)) {
                    d.medical_text_names_other += 1;
                    continue;
                }
            } else if (L.reg.member(r.subject) != null) {
                const about = switch (tg) {
                    .person => |p| std.mem.eql(u8, p, r.subject),
                    .many => |m| m.has(L.reg, r.subject),
                    .none => false,
                };
                // a personal line that also names someone else may carry their facts: same rule as medical — for a
                // set, everyone the line names must be inside the set
                const names_outside = switch (tg) {
                    .many => |m| !resolve.named(L.reg, r.text).allIn(L.reg, m),
                    else => resolve.named(L.reg, r.text).other(L.reg, r.subject),
                };
                if (!about or names_outside) {
                    d.personal_other_subject += 1;
                    continue;
                }
            }
            try out.append(a, r);
        }
        return .{ .rows = out.items, .target = tg, .drops = d };
    }

    /// Gate arbitrary rows for a seat (used by tests with a deliberately scope-blind candidate list).
    pub fn gateFor(h: House, a: std.mem.Allocator, seat: []const u8, query: []const u8, rows: []const Row) !Gated {
        const L = try h.load(a);
        return h.gate(a, L, try h.actor(L, seat), query, rows, null);
    }

    /// Scoped search + gate. Requested scopes must each be readable (else Forbidden, audited); absent = all readable.
    pub fn recall(h: House, a: std.mem.Allocator, seat: []const u8, query: []const u8, o: RecallOpts) !Gated {
        const L = try h.load(a);
        const act = try h.actor(L, seat);
        const scopes = if (o.requested) |req| blk: {
            if (req.len == 0) break :blk try policy.readScopes(a, L.reg, act);
            for (req) |s| if (!policy.mayRead(act, s)) {
                h.deny(seat, try std.fmt.allocPrint(a, "read {s}", .{s[0..@min(s.len, 80)]}));
                return error.Forbidden;
            };
            break :blk req;
        } else try policy.readScopes(a, L.reg, act);
        const qh = qhash(query);
        for (scopes) |s| if (policy.isCross(act, s))
            try h.st.audit(seat, "xread", "atoms", null, try std.fmt.allocPrint(a, "scope={s} q={s}", .{ s, &qh }));
        var cands: std.ArrayList(Row) = .empty;
        var i: usize = 0;
        while (i < scopes.len) : (i += store.Scope.max) {
            const chunk = scopes[i..@min(scopes.len, i + store.Scope.max)];
            const hits = try store.atoms.search(h.st, a, .{ .names = chunk }, query, .{ .limit = o.fetch });
            for (hits) |x| try cands.append(a, .{ .id = x.id, .scope = x.scope, .subject = x.subject, .type = x.type, .text = x.text, .status = x.status, .score = x.score });
        }
        std.mem.sort(Row, cands.items, {}, struct {
            fn lt(_: void, x: Row, y: Row) bool {
                return x.score < y.score;
            }
        }.lt);
        const narrow: ?[]const u8 = if (o.requested) |req| (if (req.len == 1) switch (policy.kind(req[0])) {
            .person => |p| p,
            else => null,
        } else null) else null;
        var g = try h.gate(a, L, act, query, cands.items, narrow);
        if (g.rows.len > o.limit) g.rows = g.rows[0..o.limit];
        return g;
    }

    fn writeBody(h: House, n: NewAtom, act: Actor, status: Status, med: bool) !i64 {
        const id = try store.atoms.insert(h.st, .{ .subject = n.subject, .scope = n.scope, .type = n.type, .text = n.text, .priority = n.priority, .status = status, .extractor = "household", .seat = act.seat });
        try h.st.db.run("INSERT INTO hh_tags(atom_id, medical) VALUES (?1, ?2)", .{ id, med });
        return id;
    }

    /// Write one atom. `household` is never writable (promotion only). A medical row outside its own person's scope,
    /// or about someone outside the household list, lands as pending_review (never served).
    pub fn write(h: House, a: std.mem.Allocator, seat: []const u8, n: NewAtom) !i64 {
        const L = try h.load(a);
        const act = try h.actor(L, seat);
        if (!policy.mayWrite(act, n.scope)) {
            h.deny(seat, try std.fmt.allocPrint(a, "write {s}", .{n.scope[0..@min(n.scope.len, 80)]}));
            return error.Forbidden;
        }
        const r = try writeRule(a, L, n);
        return h.st.savepoint(writeBody, .{ h, n, act, r.status, r.med });
    }

    pub const Rule = struct { status: Status, med: bool };

    /// The write rule every writer shares (House.write, the hub's API writes, the extraction worker): a medical row
    /// outside its own person's scope (or a seat bound to that person), or a row about someone outside the household
    /// list ("User"), lands pending_review — stored, never served until a person approves it.
    pub fn writeRule(a: std.mem.Allocator, L: Loaded, n: NewAtom) !Rule {
        const med = (n.medical orelse false) or medical.isMedical(n.text);
        const known = L.reg.member(n.subject) != null or std.mem.eql(u8, n.subject, "household") or
            (std.mem.startsWith(u8, n.subject, "ext:") and n.subject.len > 4);
        // a medical row is live only in its own person's scope or the private scope of a seat bound to that person
        const own = std.mem.eql(u8, n.scope, try std.fmt.allocPrint(a, "person:{s}", .{n.subject})) or switch (policy.kind(n.scope)) {
            .seat => |sn| if (L.reg.seat(sn)) |x| (x.member != null and std.mem.eql(u8, x.member.?, n.subject)) else false,
            else => false,
        };
        return .{ .status = if (!known or (med and !own)) .pending_review else .active, .med = med };
    }

    // ---- promotion: personal/seat atom → household, two explicit steps, a principal decides ----

    pub fn promoteRequest(h: House, a: std.mem.Allocator, seat: []const u8, atom_id: i64) !i64 {
        const L = try h.load(a);
        const act = try h.actor(L, seat);
        var s = try h.st.db.prepare("SELECT scope, status, text FROM atoms WHERE id = ?1");
        defer s.deinit();
        try s.bind(1, atom_id);
        if (!try s.step()) return error.NoSuchAtom;
        const scope = try a.dupe(u8, s.text(0));
        if (!policy.mayRead(act, scope)) return error.NoSuchAtom; // invisible, not "forbidden"
        if (!policy.mayWrite(act, scope)) {
            h.deny(seat, "promote: not owner");
            return error.Forbidden;
        }
        if (std.mem.eql(u8, scope, "household")) return error.AlreadyShared;
        if (!std.mem.eql(u8, s.text(1), "active")) return error.NotActive;
        if (h.isMedicalRow(atom_id, s.text(2))) {
            h.deny(seat, "promote: medical stays personal");
            return error.MedicalNotShareable;
        }
        try h.st.db.run("INSERT INTO hh_promotions(atom_id, requested_by, requested_ms, state) VALUES (?1, ?2, ?3, 'pending')", .{ atom_id, seat, h.st.nowMs() });
        const id = h.st.db.lastId();
        try h.st.audit(seat, "promote-request", "hh_promotions", id, null);
        return id;
    }

    fn approveBody(h: House, req: i64, atom_id: i64, seat: []const u8) !i64 {
        var s = try h.st.db.prepare("SELECT subject, type, text, status, priority FROM atoms WHERE id = ?1");
        defer s.deinit();
        try s.bind(1, atom_id);
        if (!try s.step()) return error.NoSuchAtom;
        if (!std.mem.eql(u8, s.text(3), "active")) return error.NotActive;
        if (h.isMedicalRow(atom_id, s.text(2))) return error.MedicalNotShareable;
        const id = try store.atoms.insert(h.st, .{ .subject = s.text(0), .scope = "household", .type = s.text(1), .text = s.text(2), .priority = s.int(4), .extractor = "household-promotion", .seat = seat });
        try h.st.db.run("INSERT INTO hh_tags(atom_id, medical) VALUES (?1, 0)", .{id});
        try h.st.db.run("UPDATE hh_promotions SET state = 'approved', decided_by = ?2, decided_ms = ?3, new_atom_id = ?4 WHERE id = ?1 AND state = 'pending'", .{ req, seat, h.st.nowMs(), id });
        if (h.st.db.changes() != 1) return error.NotPending;
        try h.st.audit(seat, "promote-approve", "hh_promotions", req, null);
        return id;
    }

    /// Principals only. Approve → a new household atom (the personal one stays where it was); refuse → status only.
    pub fn promoteDecide(h: House, a: std.mem.Allocator, seat: []const u8, req: i64, approve: bool) !?i64 {
        const L = try h.load(a);
        const act = try h.actor(L, seat);
        if (!policy.mayApprovePromotion(act)) {
            h.deny(seat, "promote-decide: not a principal");
            return error.Forbidden;
        }
        const atom_id = (try h.st.db.oneInt("SELECT atom_id FROM hh_promotions WHERE id = ?1 AND state = 'pending'", .{req})) orelse return error.NotPending;
        if (!approve) {
            try h.st.db.run("UPDATE hh_promotions SET state = 'refused', decided_by = ?2, decided_ms = ?3 WHERE id = ?1", .{ req, seat, h.st.nowMs() });
            try h.st.audit(seat, "promote-refuse", "hh_promotions", req, null);
            return null;
        }
        return try h.st.savepoint(approveBody, .{ h, req, atom_id, seat });
    }

    // ---- membership (principals only, except a member may revoke their own seat) ----

    pub const MemberIn = struct { id: []const u8, display: []const u8, aliases: []const []const u8 = &.{}, role: policy.Role, relation: []const u8 = "" };

    fn insertMember(h: House, a: std.mem.Allocator, m: MemberIn, by: []const u8) !void {
        if (!policy.validId(m.id) or m.display.len == 0 or m.display.len > 80) return error.BadId;
        if ((try h.st.db.oneInt("SELECT 1 FROM hh_members WHERE id = ?1", .{m.id})) != null) return error.Exists;
        var al: std.ArrayList(u8) = .empty;
        for (m.aliases, 0..) |x, i| {
            if (std.mem.indexOfScalar(u8, x, '|') != null) return error.BadId;
            try al.print(a, "{s}{s}", .{ if (i == 0) "" else "|", x });
        }
        try h.st.db.run("INSERT INTO hh_members(id, display, aliases, role, relation, created_ms, created_by) VALUES (?1,?2,?3,?4,?5,?6,?7)", .{ m.id, m.display, al.items, @tagName(m.role), m.relation, h.st.nowMs(), by });
        try h.st.audit(by, "member-add", "hh_members", null, m.id);
    }

    fn insertSeat(h: House, name: []const u8, member: ?[]const u8, by: []const u8) !void {
        if (!policy.validId(name)) return error.BadId;
        if ((try h.st.db.oneInt("SELECT 1 FROM hh_seats WHERE name = ?1", .{name})) != null) return error.Exists;
        try h.st.db.run("INSERT INTO hh_seats(name, member, created_ms, created_by) VALUES (?1,?2,?3,?4)", .{ name, member, h.st.nowMs(), by });
        try h.st.audit(by, "seat-bind", "hh_seats", null, name);
    }

    /// First run only (no members yet): the operator CLI seeds the household. Afterwards only principals change it.
    pub fn bootstrap(h: House, a: std.mem.Allocator, members: []const MemberIn, seats: []const policy.Seat) !void {
        if ((try h.st.db.oneInt("SELECT count(*) FROM hh_members", .{})).? != 0) return error.BootstrapDone;
        for (members) |m| try h.insertMember(a, m, "bootstrap");
        for (seats) |s| try h.insertSeat(s.name, s.member, "bootstrap");
    }

    fn admin(h: House, a: std.mem.Allocator, seat: []const u8, what: []const u8) !Actor {
        const L = try h.load(a);
        const act = try h.actor(L, seat);
        if (!policy.mayAdmin(act)) {
            h.deny(seat, what);
            return error.Forbidden;
        }
        return act;
    }

    pub fn addMember(h: House, a: std.mem.Allocator, seat: []const u8, m: MemberIn) !void {
        _ = try h.admin(a, seat, "member-add");
        try h.insertMember(a, m, seat);
    }

    pub fn bindSeat(h: House, a: std.mem.Allocator, seat: []const u8, name: []const u8, member: ?[]const u8) !void {
        _ = try h.admin(a, seat, "seat-bind");
        if (member) |m| if ((try h.st.db.oneInt("SELECT 1 FROM hh_members WHERE id = ?1 AND revoked_ms IS NULL", .{m})) == null) return error.BadId;
        try h.insertSeat(name, member, seat);
    }

    pub fn revokeSeat(h: House, a: std.mem.Allocator, seat: []const u8, name: []const u8) !void {
        const L = try h.load(a);
        const act = try h.actor(L, seat);
        const target = L.reg.seat(name) orelse return error.BadId;
        const own = act.member != null and target.member != null and std.mem.eql(u8, act.member.?, target.member.?);
        if (!policy.mayAdmin(act) and !own) {
            h.deny(seat, "seat-revoke");
            return error.Forbidden;
        }
        try h.st.db.run("UPDATE hh_seats SET revoked_ms = ?2, revoked_by = ?3 WHERE name = ?1 AND revoked_ms IS NULL", .{ name, h.st.nowMs(), seat });
        try h.st.audit(seat, "seat-revoke", "hh_seats", null, name);
    }

    /// Principals are never revocable through the API (both hold full authority; neither can lock the other out).
    pub fn revokeMember(h: House, a: std.mem.Allocator, seat: []const u8, id: []const u8) !void {
        _ = try h.admin(a, seat, "member-revoke");
        const L = try h.load(a);
        const m = L.reg.member(id) orelse return error.BadId;
        if (m.role == .principal) {
            h.deny(seat, "member-revoke: principal");
            return error.PrincipalNotRevocable;
        }
        try h.st.db.run("UPDATE hh_members SET revoked_ms = ?2, revoked_by = ?3 WHERE id = ?1 AND revoked_ms IS NULL", .{ id, h.st.nowMs(), seat });
        try h.st.audit(seat, "member-revoke", "hh_members", null, id);
    }

    /// Persona rows the seat may see: readable scopes only; a medical-looking persona only for its own subject.
    pub fn personas(h: House, a: std.mem.Allocator, seat: []const u8) ![]Row {
        const L = try h.load(a);
        const act = try h.actor(L, seat);
        var out: std.ArrayList(Row) = .empty;
        var s = try h.st.db.prepare("SELECT subject, scope, text FROM persona ORDER BY scope, subject");
        defer s.deinit();
        while (try s.step()) {
            const scope = s.text(1);
            if (!policy.mayRead(act, scope)) continue;
            const subject = s.text(0);
            const mine = act.member != null and std.mem.eql(u8, act.member.?, subject);
            if (!mine and medical.isMedical(s.text(2))) continue;
            try out.append(a, .{ .id = 0, .scope = try a.dupe(u8, scope), .subject = try a.dupe(u8, subject), .text = try a.dupe(u8, s.text(2)) });
        }
        return out.items;
    }
};
