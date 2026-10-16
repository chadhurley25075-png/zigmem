//! The only two hosts extraction may ever talk to: the primary engine GLM-5.3-Flash and the secondary door. Hard-coded, IP literals.
const std = @import("std");

pub const Engine = enum { primary, secondary };

pub const Endpoint = struct {
    engine: Engine,
    ip: [4]u8,
    port: u16,
    model: []const u8,
    /// the primary engine: chat_template_kwargs.enable_thinking=false (fast, clean JSON). secondary: send nothing extra
    /// (her template key must not change; never reasoning_effort), so she thinks and we read `content` only.
    thinking_off: bool,
    max_tokens: u32,
    timeout_s: u32,

    pub fn hostHeader(e: Endpoint, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}:{d}", .{ e.ip[0], e.ip[1], e.ip[2], e.ip[3], e.port }) catch unreachable;
    }
};

pub const primary: Endpoint = .{ .engine = .primary, .ip = .{ 127, 0, 0, 1 }, .port = 18080, .model = "glm-5.3-flash", .thinking_off = true, .max_tokens = 1500, .timeout_s = 120 };
pub const secondary: Endpoint = .{ .engine = .secondary, .ip = .{ 127, 0, 0, 1 }, .port = 18033, .model = "glm-5.3", .thinking_off = false, .max_tokens = 4096, .timeout_s = 420 };

const list = [_]Endpoint{ primary, secondary };

/// True only for an exact (ip, port) pair on the list. Checked again right before every connect().
pub fn permitted(ip: [4]u8, port: u16) bool {
    for (list) |e| if (std.mem.eql(u8, &e.ip, &ip) and e.port == port) return true;
    return false;
}

/// "primary" | "secondary" | "http://IP:PORT" → the allowlisted endpoint, or error.NotAllowed. No DNS, ever.
pub fn resolve(spec: []const u8) error{NotAllowed}!Endpoint {
    if (std.mem.eql(u8, spec, "primary")) return primary;
    if (std.mem.eql(u8, spec, "secondary")) return secondary;
    const hp = if (std.mem.startsWith(u8, spec, "http://")) std.mem.trimEnd(u8, spec[7..], "/") else return error.NotAllowed;
    const colon = std.mem.lastIndexOfScalar(u8, hp, ':') orelse return error.NotAllowed;
    const port = std.fmt.parseInt(u16, hp[colon + 1 ..], 10) catch return error.NotAllowed;
    var ip: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, hp[0..colon], '.');
    var n: usize = 0;
    while (it.next()) |p| : (n += 1) {
        if (n == 4) return error.NotAllowed;
        ip[n] = std.fmt.parseInt(u8, p, 10) catch return error.NotAllowed;
    }
    if (n != 4) return error.NotAllowed;
    for (list) |e| if (std.mem.eql(u8, &e.ip, &ip) and e.port == port) return e;
    return error.NotAllowed;
}

test "allowlist: only the two local engines resolve" {
    try std.testing.expectEqual(Engine.primary, (try resolve("primary")).engine);
    try std.testing.expectEqual(Engine.secondary, (try resolve("secondary")).engine);
    // Built from the constants, so editing the allowlist (README: "edit it to point at your own engines") keeps this test green.
    var hb: [2][24]u8 = undefined;
    var ub: [2][40]u8 = undefined;
    const purl = try std.fmt.bufPrint(&ub[0], "http://{s}", .{primary.hostHeader(&hb[0])});
    const surl = try std.fmt.bufPrint(&ub[1], "http://{s}/", .{secondary.hostHeader(&hb[1])});
    try std.testing.expectEqual(Engine.primary, (try resolve(purl)).engine);
    try std.testing.expectEqual(Engine.secondary, (try resolve(surl)).engine);
    const refused = [_][]const u8{
        "https://api.openai.com/v1",   "http://api.openai.com:80",    "http://8.8.8.8:443",     "http://192.0.2.2:18080", // production engine: not granted
        "http://127.0.0.1:8889",   "http://127.0.0.1:18034",      "http://127.0.0.1:1",      "http://192.0.2.3:11600", // the Mac box
        "http://100.100.1.1:18033", "http://127.0.0.1",        "http://1.2.3.4.5:80",    "http://localhost:18033",
        "engine",                       "http://[::1]:18033",          "ftp://127.0.0.1:18033",  "",
        "http://api.anthropic.com:443", "http://127.0.0.1:18080@evil.example:80",
    };
    for (refused) |r| try std.testing.expectError(error.NotAllowed, resolve(r));
    try std.testing.expect(!permitted(.{ 192, 0, 2, 2 }, 18080));
    try std.testing.expect(!permitted(primary.ip, primary.port +% 1));
    try std.testing.expect(permitted(secondary.ip, secondary.port));
}
