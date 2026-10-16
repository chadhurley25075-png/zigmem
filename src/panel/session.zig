//! Panel sessions. Login trades a seat token for a random session id held in an HttpOnly, SameSite=Strict cookie;
//! the server keeps only sha256(session id), the seat's token hash and a per-session CSRF secret — nothing the
//! browser holds can be turned back into a seat token. Every request re-checks the seat against the live token
//! table, so revoking a seat (CLI or panel) ends its panel sessions on their next request.
//! Before login, a short-lived pre-session cookie + HMAC token protects the login form itself (login CSRF).
const std = @import("std");
const api = @import("api");
const auth = api.auth;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const cookie_name = "zm_sess";
pub const pre_name = "zm_pre";
pub const max_sessions = 64;
pub const idle_ms: i64 = 2 * 3600 * 1000;
pub const absolute_ms: i64 = 12 * 3600 * 1000;
pub const pre_ttl_s = 900;

pub const Session = struct {
    used: bool = false,
    id_hash: [32]u8 = @splat(0),
    seat_hash: [32]u8 = @splat(0),
    csrf: [32]u8 = @splat(0),
    created_ms: i64 = 0,
    last_ms: i64 = 0,
};

/// What a request gets after a successful session check (copied out under the lock).
pub const Who = struct {
    seat: *const auth.Seat,
    csrf_hex: [64]u8,
    slot: usize,
};

pub const Store = struct {
    io: std.Io,
    mu: std.Io.Mutex = .init,
    slots: [max_sessions]Session = @splat(.{}),
    /// HMAC key for login-form tokens; random per process.
    secret: [32]u8 = @splat(0),

    pub fn init(io: std.Io) !Store {
        var s: Store = .{ .io = io };
        try io.randomSecure(&s.secret);
        return s;
    }

    pub fn count(s: *Store, now: i64) usize {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        var n: usize = 0;
        for (s.slots) |x| if (x.used and live(x, now)) {
            n += 1;
        };
        return n;
    }

    fn live(x: Session, now: i64) bool {
        return now - x.last_ms < idle_ms and now - x.created_ms < absolute_ms;
    }

    /// New session for the seat whose token hashes to `seat_hash`. Returns the cookie value (64 hex) — the only
    /// copy of the session id; the oldest session is evicted when all slots are taken.
    pub fn create(s: *Store, seat_hash: [32]u8, now: i64) ![64]u8 {
        var id: [32]u8 = undefined;
        try s.io.randomSecure(&id);
        var csrf: [32]u8 = undefined;
        try s.io.randomSecure(&csrf);
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        var pick: usize = 0;
        var oldest: i64 = std.math.maxInt(i64);
        for (s.slots, 0..) |x, i| {
            if (!x.used or !live(x, now)) {
                pick = i;
                break;
            }
            if (x.last_ms < oldest) {
                oldest = x.last_ms;
                pick = i;
            }
        }
        var h: [32]u8 = undefined;
        Sha256.hash(&id, &h, .{});
        s.slots[pick] = .{ .used = true, .id_hash = h, .seat_hash = seat_hash, .csrf = csrf, .created_ms = now, .last_ms = now };
        return std.fmt.bytesToHex(id, .lower);
    }

    /// The session named by a cookie value, if live, and its seat if that seat's token is still active.
    pub fn check(s: *Store, cookie_val: ?[]const u8, table: ?*const auth.Table, now: i64) ?Who {
        const v = cookie_val orelse return null;
        if (v.len != 64) return null;
        var id: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&id, v) catch return null;
        var h: [32]u8 = undefined;
        Sha256.hash(&id, &h, .{});
        const t = table orelse return null;
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        var hit: ?usize = null;
        for (s.slots, 0..) |x, i| {
            if (x.used and std.crypto.timing_safe.eql([32]u8, x.id_hash, h)) hit = i;
        }
        const i = hit orelse return null;
        const x = &s.slots[i];
        if (!live(x.*, now)) {
            x.* = .{};
            return null;
        }
        const seat = seatByHash(t, x.seat_hash) orelse {
            x.* = .{}; // revoked or gone: the session dies with it
            return null;
        };
        x.last_ms = now;
        return .{ .seat = seat, .csrf_hex = std.fmt.bytesToHex(x.csrf, .lower), .slot = i };
    }

    pub fn drop(s: *Store, slot: usize) void {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        s.slots[slot] = .{};
    }

    /// Ends every session of a seat (used when the panel revokes it).
    pub fn dropSeat(s: *Store, seat_hash: [32]u8) void {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        for (&s.slots) |*x| if (x.used and std.mem.eql(u8, &x.seat_hash, &seat_hash)) {
            x.* = .{};
        };
    }

    /// Login-form token for a pre-session value: hex(HMAC(secret, "login\x00" ++ pre)).
    pub fn loginToken(s: *const Store, pre: []const u8) [64]u8 {
        var m: [HmacSha256.mac_length]u8 = undefined;
        var h = HmacSha256.init(&s.secret);
        h.update("login\x00");
        h.update(pre);
        h.final(&m);
        return std.fmt.bytesToHex(m, .lower);
    }

    pub fn newPre(s: *const Store) ![32]u8 {
        var r: [16]u8 = undefined;
        try s.io.randomSecure(&r);
        return std.fmt.bytesToHex(r, .lower);
    }
};

/// Active (not revoked) seat with this token hash.
pub fn seatByHash(t: *const auth.Table, h: [32]u8) ?*const auth.Seat {
    var hit: ?*const auth.Seat = null;
    for (t.seats) |*x| {
        if (std.crypto.timing_safe.eql([32]u8, x.hash, h) and x.revoked_ms == null) hit = x;
    }
    return hit;
}

/// Constant-time equality of two submitted hex tokens of the expected length.
pub fn tokenEq(got: ?[]const u8, want: []const u8) bool {
    const g = got orelse return false;
    if (g.len != want.len or want.len != 64) return false;
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    @memcpy(&a, g);
    @memcpy(&b, want);
    return std.crypto.timing_safe.eql([64]u8, a, b);
}

test "sessions: create, check, csrf, revoke kills, idle expiry" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var s = try Store.init(io);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const seats = [_]auth.Seat{.{ .name = "seat-a", .hash = auth.hashToken("zm_a"), .scopes = &.{"syn-a"}, .writes = true, .trusted = false, .admin = false, .person = null, .created_ms = 1, .revoked_ms = null }};
    var t = try auth.parse(std.testing.allocator, try auth.render(arena.allocator(), &seats));
    defer t.deinit();
    const ck = try s.create(auth.hashToken("zm_a"), 1000);
    const w = s.check(&ck, &t, 2000) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("seat-a", w.seat.name);
    try std.testing.expect(tokenEq(&w.csrf_hex, &w.csrf_hex));
    try std.testing.expect(!tokenEq("00", &w.csrf_hex));
    var bad = ck;
    bad[0] = if (bad[0] == 'a') 'b' else 'a';
    try std.testing.expect(s.check(&bad, &t, 2000) == null);
    try std.testing.expect(s.check(&ck, &t, 2000 + idle_ms) == null); // idle → gone for good
    try std.testing.expect(s.check(&ck, &t, 2001) == null);
    const ck2 = try s.create(auth.hashToken("zm_a"), 5000);
    t.seats[0].revoked_ms = 6000;
    try std.testing.expect(s.check(&ck2, &t, 6001) == null);
    const pre = try s.newPre();
    const lt = s.loginToken(&pre);
    try std.testing.expect(tokenEq(&lt, &s.loginToken(&pre)));
    try std.testing.expect(!tokenEq(&lt, &s.loginToken("other")));
}
