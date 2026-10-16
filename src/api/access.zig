//! Integration: the one place a request's identity becomes permissions. The seat comes ONLY from the verified token
//! (auth.zig); the household registry (phase 5) is read live from the store on every request, so a revoked seat or
//! member stops working on its next call. Effective read scopes = what household policy allows the seat's member
//! INTERSECTED with the token's own scope list (a token can narrow, never widen; `*` = no narrowing). Writes need the
//! token's `w` flag, the token's scope list and household policy; admin needs the token's `a` flag AND a principal.
const std = @import("std");
const store = @import("store");
const hh = @import("household");
const auth = @import("auth.zig");

pub const policy = hh.policy;

pub const Who = struct {
    seat: *const auth.Seat,
    L: hh.house.Loaded,
    actor: policy.Actor,
    /// Every scope this request may read (stable order: household, persons, seats).
    read: []const []const u8,

    pub fn scope(w: Who) store.Scope {
        return .{ .names = w.read };
    }
    pub fn mayRead(w: Who, s: []const u8) bool {
        for (w.read) |x| if (std.mem.eql(u8, x, s)) return true;
        return false;
    }
    pub fn mayWrite(w: Who, s: []const u8) bool {
        return w.seat.writes and tokenAllows(w.seat, s) and policy.mayWrite(w.actor, s);
    }
    pub fn admin(w: Who) bool {
        return w.seat.admin and policy.mayAdmin(w.actor);
    }
    pub fn principal(w: Who) bool {
        return policy.mayApprovePromotion(w.actor);
    }
    /// The one scope a write lands in when the request names none: the member's own person scope, else the seat's.
    pub fn defaultWriteScope(w: Who, a: std.mem.Allocator) ![]const u8 {
        if (w.actor.member) |m| {
            const ps = try std.fmt.allocPrint(a, "person:{s}", .{m});
            if (w.mayWrite(ps)) return ps;
        }
        return std.fmt.allocPrint(a, "seat:{s}", .{w.actor.seat});
    }
};

/// The token's own scope list allows `s` (`*` = every scope household policy allows).
pub fn tokenAllows(seat: *const auth.Seat, s: []const u8) bool {
    for (seat.scopes) |x| if (std.mem.eql(u8, x, "*") or std.mem.eql(u8, x, s)) return true;
    return false;
}

pub const Resolved = union(enum) { ok: Who, denied: []const u8 };

/// Verified seat → household actor → effective scopes, from the registry as it is in `rd` right now.
pub fn resolve(a: std.mem.Allocator, rd: *store.Store, seat: *const auth.Seat) !Resolved {
    const house: hh.House = .{ .st = rd };
    const L = try house.load(a);
    const actor = policy.actorFor(L.reg, seat.name) catch |e| return .{ .denied = switch (e) {
        error.UnknownSeat => "seat is not bound to the household",
        error.SeatRevoked => "seat revoked in the household",
        error.MemberRevoked => "member revoked in the household",
        error.MemberMissing => "seat's member is missing",
    } };
    var read: std.ArrayList([]const u8) = .empty;
    for (try policy.readScopes(a, L.reg, actor)) |s| if (tokenAllows(seat, s)) try read.append(a, s);
    return .{ .ok = .{ .seat = seat, .L = L, .actor = actor, .read = read.items } };
}

/// Requested scopes (each must be readable) → the search set; absent/empty → everything readable.
/// Returns null when any requested scope is not readable (the caller answers 403 and audits a denial).
pub fn narrowTo(w: Who, want: []const []const u8) ?[]const []const u8 {
    if (want.len == 0) return w.read;
    for (want) |s| if (!w.mayRead(s)) return null;
    return want;
}

/// The one person a request narrowed to (a single `person:<id>` scope), for the row gate's default target.
pub fn narrowPerson(want: []const []const u8) ?[]const u8 {
    if (want.len != 1) return null;
    return switch (policy.kind(want[0])) {
        .person => |p| p,
        else => null,
    };
}

/// 8 hex characters of sha256(query): the only trace of a question the audit ever keeps.
pub fn qhash(q: []const u8) [8]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(q, &d, .{});
    var out: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{d[0..4]}) catch unreachable;
    return out;
}

/// Writer-thread op: a denial (household layer), never the request text.
pub fn denyOp(st: *store.Store, seat: []const u8, why: []const u8) !void {
    try st.audit(seat, "deny", "household", null, why[0..@min(why.len, 160)]);
}

/// Writer-thread op: supersede through the household write rule (the new version's status + its medical tag).
/// Shared by the REST route and the panel.
pub fn supersedeOp(st: *store.Store, a: std.mem.Allocator, old: i64, n0: store.atoms.New, valid_to: ?[]const u8, medical_hint: ?bool) !i64 {
    const house: hh.House = .{ .st = st };
    const L = try house.load(a);
    const rule = try hh.House.writeRule(a, L, .{ .scope = n0.scope, .subject = n0.subject, .type = n0.type, .text = n0.text, .medical = medical_hint });
    var n = n0;
    n.status = rule.status;
    const id = try store.atoms.supersede(st, old, n, valid_to);
    try st.db.run("INSERT INTO hh_tags(atom_id, medical) VALUES (?1, ?2)", .{ id, rule.med });
    return id;
}

/// Owner of a conversation turn by its scope: person:<id> → id, seat:<name> → that seat's member (a shared seat →
/// "household"), household → "household"; anything else → null (unreadable).
pub fn turnOwner(L: hh.house.Loaded, scope_name: []const u8) ?[]const u8 {
    return switch (policy.kind(scope_name)) {
        .household => "household",
        .person => |p| p,
        .seat => |s| if (L.reg.seat(s)) |x| (x.member orelse "household") else null,
        .other => null,
    };
}

test "token narrowing never widens" {
    const seat: auth.Seat = .{ .name = "rowan-phone", .hash = @splat(0), .scopes = &.{ "household", "person:morgan" }, .writes = true, .trusted = false, .admin = true, .person = null, .created_ms = 0, .revoked_ms = null };
    try std.testing.expect(tokenAllows(&seat, "household"));
    try std.testing.expect(tokenAllows(&seat, "person:morgan")); // allowed by the token…
    const star: auth.Seat = .{ .name = "x", .hash = @splat(0), .scopes = &.{"*"}, .writes = false, .trusted = false, .admin = false, .person = null, .created_ms = 0, .revoked_ms = null };
    try std.testing.expect(tokenAllows(&star, "person:anyone"));
    // …but a child's actor can never write or read it: policy is the other half (see resolve()).
    const kid: policy.Actor = .{ .seat = "rowan-phone", .member = "rowan", .role = .child };
    try std.testing.expect(!policy.mayRead(kid, "person:morgan"));
    const w: Who = .{ .seat = &seat, .L = undefined, .actor = kid, .read = &.{"household"} };
    try std.testing.expect(!w.mayWrite("person:morgan"));
    try std.testing.expect(!w.admin()); // token admin flag alone is not enough
    try std.testing.expect(narrowTo(w, &.{"person:morgan"}) == null);
    try std.testing.expectEqualStrings("morgan", narrowPerson(&.{"person:morgan"}).?);
}
