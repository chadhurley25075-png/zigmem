//! Minimal HTTP/1.1 POST client for loopback/LAN services (embedder, reranker): IPv4 literal hosts only, a connect leash
//! (non-blocking connect + poll) and a read leash (SO_RCVTIMEO), Content-Length or chunked replies. Linux only.
const std = @import("std");
const linux = std.os.linux;

pub const Error = error{ BadUrl, ConnectFailed, ConnectTimeout, WriteFailed, ReadFailed, Timeout, BadResponse, HttpStatus, TooLarge };

pub const Url = struct { ip: [4]u8, port: u16, path: []const u8, host: []const u8 };

pub fn parseUrl(url: []const u8) Error!Url {
    const rest = if (std.mem.startsWith(u8, url, "http://")) url[7..] else return error.BadUrl;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const hostport = rest[0..slash];
    const colon = std.mem.lastIndexOfScalar(u8, hostport, ':');
    const host = if (colon) |c| hostport[0..c] else hostport;
    const port = if (colon) |c| std.fmt.parseInt(u16, hostport[c + 1 ..], 10) catch return error.BadUrl else 80;
    var ip: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, host, '.');
    for (&ip) |*b| b.* = std.fmt.parseInt(u8, it.next() orelse return error.BadUrl, 10) catch return error.BadUrl;
    if (it.next() != null) return error.BadUrl;
    return .{ .ip = ip, .port = port, .path = if (slash < rest.len) rest[slash..] else "/", .host = hostport };
}

pub const Leash = struct { connect_ms: u32 = 500, read_ms: u32 = 3000 };

fn setTimeout(fd: i32, ms: u32) void {
    const tv: linux.timeval = .{ .sec = @intCast(ms / 1000), .usec = @intCast((ms % 1000) * 1000) };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
}

/// Blocking socket; Linux bounds connect() by SO_SNDTIMEO, so the connect leash is just a send timeout set first.
fn connect(u: Url, leash: Leash) Error!i32 {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.ConnectFailed;
    const fd: i32 = @intCast(rc);
    errdefer _ = linux.close(fd);
    setTimeout(fd, leash.connect_ms);
    var sa: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, u.port), .addr = @bitCast(u.ip) };
    while (true) {
        const c = linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
        switch (linux.errno(c)) {
            .SUCCESS => break,
            .INTR => continue,
            .INPROGRESS, .AGAIN, .TIMEDOUT => return error.ConnectTimeout,
            else => return error.ConnectFailed,
        }
    }
    setTimeout(fd, leash.read_ms);
    return fd;
}

fn sendAll(fd: i32, data: []const u8) Error!void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = linux.sendto(fd, data[off..].ptr, data.len - off, linux.MSG.NOSIGNAL, null, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => {},
            .AGAIN => return error.Timeout,
            else => return error.WriteFailed,
        }
    }
}

/// POST `body` (JSON) and return the response body (owned by `a`). Non-2xx → error.HttpStatus.
pub fn postJson(a: std.mem.Allocator, url: []const u8, body: []const u8, leash: Leash, max: usize) ![]u8 {
    const u = try parseUrl(url);
    const fd = try connect(u, leash);
    defer _ = linux.close(fd);
    var head: std.ArrayList(u8) = .empty;
    try head.print(a, "POST {s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ u.path, u.host, body.len });
    try sendAll(fd, head.items);
    try sendAll(fd, body);
    var resp: std.ArrayList(u8) = .empty;
    var buf: [1 << 16]u8 = undefined;
    while (true) {
        const rc = linux.read(fd, &buf, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) break;
                try resp.appendSlice(a, buf[0..rc]);
                if (resp.items.len > max) return error.TooLarge;
                if (complete(resp.items)) break;
            },
            .INTR => {},
            .AGAIN => return error.Timeout,
            else => return error.ReadFailed,
        }
    }
    return decode(a, resp.items);
}

fn headerEnd(r: []const u8) ?usize {
    return if (std.mem.indexOf(u8, r, "\r\n\r\n")) |p| p + 4 else null;
}

fn contentLength(head: []const u8) ?usize {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    while (it.next()) |l| {
        const c = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, l[0..c], " "), "content-length"))
            return std.fmt.parseInt(usize, std.mem.trim(u8, l[c + 1 ..], " \t"), 10) catch null;
    }
    return null;
}

fn complete(r: []const u8) bool {
    const he = headerEnd(r) orelse return false;
    if (contentLength(r[0..he])) |n| return r.len - he >= n;
    return std.mem.endsWith(u8, r, "\r\n0\r\n\r\n");
}

fn decode(a: std.mem.Allocator, r: []const u8) ![]u8 {
    const he = headerEnd(r) orelse return error.BadResponse;
    const head = r[0..he];
    if (head.len < 12 or !std.mem.startsWith(u8, head, "HTTP/1.")) return error.BadResponse;
    const status = std.fmt.parseInt(u16, head[9..12], 10) catch return error.BadResponse;
    if (status < 200 or status >= 300) return error.HttpStatus;
    const body = r[he..];
    if (contentLength(head)) |n| return a.dupe(u8, body[0..@min(n, body.len)]);
    const lower_head = try a.alloc(u8, head.len);
    _ = std.ascii.lowerString(lower_head, head);
    if (std.mem.indexOf(u8, lower_head, "transfer-encoding: chunked") == null) return a.dupe(u8, body);
    var out: std.ArrayList(u8) = .empty;
    var p: usize = 0;
    while (p < body.len) {
        const le = std.mem.indexOfPos(u8, body, p, "\r\n") orelse return error.BadResponse;
        const sz_txt = std.mem.trim(u8, body[p..le], " ");
        const semi = std.mem.indexOfScalar(u8, sz_txt, ';') orelse sz_txt.len;
        const sz = std.fmt.parseInt(usize, sz_txt[0..semi], 16) catch return error.BadResponse;
        p = le + 2;
        if (sz == 0) break;
        if (p + sz > body.len) return error.BadResponse;
        try out.appendSlice(a, body[p .. p + sz]);
        p += sz + 2;
    }
    return out.items;
}

test "url" {
    const u = try parseUrl("http://192.0.2.10:18098/rerank");
    try std.testing.expectEqual(@as(u16, 18098), u.port);
    try std.testing.expectEqualStrings("/rerank", u.path);
    try std.testing.expectError(error.BadUrl, parseUrl("http://x86box:18098/rerank"));
}
