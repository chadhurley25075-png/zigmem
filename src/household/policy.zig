//! Household permission policy (pure): who may read / write which scope. Scopes are `household`, `person:<id>`,
//! `seat:<name>`. Principals (Alex, Morgan) have full authority; children and guests see only their own scopes; nobody
//! writes `household` directly (shared memory arrives only by an approved promotion — the the review pipeline law).
const std = @import("std");

pub const Role = enum { principal, child, guest };

pub const Member = struct {
    id: []const u8,
    display: []const u8,
    aliases: []const []const u8 = &.{},
    role: Role,
    revoked: bool = false,
};

pub const Seat = struct {
    name: []const u8,
    /// The member this seat acts for; null = a shared household device (kitchen speaker).
    member: ?[]const u8,
    revoked: bool = false,
};

pub const Registry = struct {
    members: []const Member,
    seats: []const Seat,

    pub fn member(r: Registry, id: []const u8) ?*const Member {
        for (r.members) |*m| if (std.mem.eql(u8, m.id, id)) return m;
        return null;
    }
    pub fn seat(r: Registry, name: []const u8) ?*const Seat {
        for (r.seats) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }
};

/// Who is asking. Built only from a verified seat (token → seat name → this registry), never from a request body.
pub const Actor = struct {
    seat: []const u8,
    member: ?[]const u8,
    /// null = shared seat (acts for no person)
    role: ?Role,

    pub fn principal(a: Actor) bool {
        return a.role == .principal;
    }
};

pub const ActorError = error{ UnknownSeat, SeatRevoked, MemberRevoked, MemberMissing };

/// Seat → actor, refusing revoked seats and seats whose member is revoked or missing.
pub fn actorFor(r: Registry, seat_name: []const u8) ActorError!Actor {
    const s = r.seat(seat_name) orelse return error.UnknownSeat;
    if (s.revoked) return error.SeatRevoked;
    const mid = s.member orelse return .{ .seat = s.name, .member = null, .role = null };
    const m = r.member(mid) orelse return error.MemberMissing;
    if (m.revoked) return error.MemberRevoked;
    return .{ .seat = s.name, .member = m.id, .role = m.role };
}

pub const Kind = union(enum) { household, person: []const u8, seat: []const u8, other };

pub fn kind(scope: []const u8) Kind {
    if (std.mem.eql(u8, scope, "household")) return .household;
    if (std.mem.startsWith(u8, scope, "person:") and scope.len > 7) return .{ .person = scope[7..] };
    if (std.mem.startsWith(u8, scope, "seat:") and scope.len > 5) return .{ .seat = scope[5..] };
    return .other;
}

pub fn mayRead(a: Actor, scope: []const u8) bool {
    return switch (kind(scope)) {
        .household => a.role != .guest,
        .person => |p| a.principal() or (a.member != null and std.mem.eql(u8, a.member.?, p)),
        .seat => |s| a.principal() or std.mem.eql(u8, a.seat, s),
        .other => false,
    };
}

pub fn mayWrite(a: Actor, scope: []const u8) bool {
    return switch (kind(scope)) {
        .household => false,
        .person => |p| a.principal() or (a.member != null and std.mem.eql(u8, a.member.?, p)),
        .seat => |s| a.principal() or std.mem.eql(u8, a.seat, s),
        .other => false,
    };
}

/// A read that leaves the actor's own scopes (own person, own seat, household) — always audited.
pub fn isCross(a: Actor, scope: []const u8) bool {
    return switch (kind(scope)) {
        .household => false,
        .person => |p| a.member == null or !std.mem.eql(u8, a.member.?, p),
        .seat => |s| !std.mem.eql(u8, a.seat, s),
        .other => true,
    };
}

pub fn mayApprovePromotion(a: Actor) bool {
    return a.principal();
}

pub fn mayAdmin(a: Actor) bool {
    return a.principal();
}

/// Every scope this actor may read, in a stable order (household, persons, seats).
pub fn readScopes(alloc: std.mem.Allocator, r: Registry, a: Actor) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (mayRead(a, "household")) try out.append(alloc, "household");
    for (r.members) |m| {
        const s = try std.fmt.allocPrint(alloc, "person:{s}", .{m.id});
        if (mayRead(a, s)) try out.append(alloc, s);
    }
    for (r.seats) |st| {
        const s = try std.fmt.allocPrint(alloc, "seat:{s}", .{st.name});
        if (mayRead(a, s)) try out.append(alloc, s);
    }
    return out.items;
}

/// Ids and seat names become scope suffixes: lowercase letters, digits, '-', '_' only.
pub fn validId(s: []const u8) bool {
    if (s.len == 0 or s.len > 48) return false;
    for (s) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
    return true;
}
