//! Minimal HTTP/1.1 server for the hub: raw Linux sockets (the phase-0 pattern), one thread per connection, a hard
//! connection cap, receive/send timeouts, head and body limits, one request per connection (Connection: close).
//! Bind policy: 127.0.0.1, or this host's tailnet address (100.64.0.0/10) when named explicitly. Nothing else.
const std = @import("std");
const linux = std.os.linux;
const Threaded = std.Io.Threaded;

pub const max_head = 16 << 10;
pub const max_body = 512 << 10;
pub const max_conns = 64;
pub const io_timeout_s = 10;

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    /// Raw query string after '?' (phase 6 panel; "" when absent).
    query: []const u8 = "",
    headers: []const Header,
    body: []const u8,

    pub fn header(r: Request, name: []const u8) ?[]const u8 {
        for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
};

pub const Response = struct {
    status: u16,
    body: []const u8 = "",
    ctype: []const u8 = "application/json",
    /// Extra raw header lines, each ending in \r\n.
    extra: []const u8 = "",
};

pub const Handler = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, a: std.mem.Allocator, req: Request) Response,
};

pub const BindError = error{ Unsafe, BadAddress };

/// "127.0.0.1" or a 100.64.0.0/10 tailnet address. 0.0.0.0, LAN, other loopbacks, IPv6, names: refused.
pub fn parseBind(spec: []const u8) BindError![4]u8 {
    var ip: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, spec, '.');
    var n: usize = 0;
    while (it.next()) |p| : (n += 1) {
        if (n == 4 or p.len == 0 or p.len > 3) return error.BadAddress;
        for (p) |c| if (!std.ascii.isDigit(c)) return error.BadAddress;
        ip[n] = std.fmt.parseInt(u8, p, 10) catch return error.BadAddress;
    }
    if (n != 4) return error.BadAddress;
    if (std.mem.eql(u8, &ip, &[4]u8{ 127, 0, 0, 1 })) return ip;
    if (ip[0] == 100 and ip[1] >= 64 and ip[1] <= 127) return ip;
    return error.Unsafe;
}

pub const Server = struct {
    fd: i32,
    handler: Handler,
    gpa: std.mem.Allocator,
    active: std.atomic.Value(u32) = .init(0),
    served: std.atomic.Value(u64) = .init(0),
    refused_busy: std.atomic.Value(u64) = .init(0),

    pub fn listen(ip: [4]u8, port: u16) !i32 {
        const addr: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = ip, .port = port } };
        var storage: Threaded.PosixAddress = undefined;
        const len = Threaded.addressToPosix(&addr, &storage);
        const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);
        const one: c_int = 1;
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(c_int));
        if (linux.errno(linux.bind(fd, &storage.any, len)) != .SUCCESS) return error.AddressInUse;
        if (linux.errno(linux.listen(fd, 256)) != .SUCCESS) return error.ListenFailed;
        return fd;
    }

    /// Accept forever.
    pub fn run(s: *Server) void {
        while (true) {
            const rc = linux.accept4(s.fd, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(rc) != .SUCCESS) continue;
            const c: i32 = @intCast(rc);
            const tv: linux.timeval = .{ .sec = io_timeout_s, .usec = 0 };
            _ = linux.setsockopt(c, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
            _ = linux.setsockopt(c, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
            const one: c_int = 1;
            _ = linux.setsockopt(c, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(c_int));
            if (s.active.fetchAdd(1, .acq_rel) >= max_conns) {
                _ = s.active.fetchSub(1, .acq_rel);
                _ = s.refused_busy.fetchAdd(1, .monotonic);
                sendStatus(c, 503, "{\"error\":\"busy\"}");
                _ = linux.close(c);
                continue;
            }
            const t = std.Thread.spawn(.{ .stack_size = 1 << 20 }, connection, .{ s, c }) catch {
                _ = s.active.fetchSub(1, .acq_rel);
                _ = linux.close(c);
                continue;
            };
            t.detach();
        }
    }

    fn connection(s: *Server, c: i32) void {
        defer {
            _ = linux.close(c);
            _ = s.active.fetchSub(1, .acq_rel);
        }
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const req = readRequest(a, c) catch |e| {
            const st: u16 = switch (e) {
                error.HeaderTooLarge => 431,
                error.BodyTooLarge => 413,
                error.LengthRequired => 411,
                error.Closed, error.ReadFailed => return,
                else => 400,
            };
            sendStatus(c, st, "{\"error\":\"bad request\"}");
            return;
        };
        const resp = s.handler.f(s.handler.ctx, a, req);
        _ = s.served.fetchAdd(1, .monotonic);
        writeResponse(a, c, resp) catch {};
    }
};

fn recvSome(fd: i32, buf: []u8) !usize {
    while (true) {
        const rc = linux.read(fd, buf.ptr, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => {},
            else => return error.ReadFailed,
        }
    }
}

fn sendAll(fd: i32, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = linux.sendto(fd, data[off..].ptr, data.len - off, linux.MSG.NOSIGNAL, null, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => {},
            else => return error.WriteFailed,
        }
    }
}

fn readRequest(a: std.mem.Allocator, c: i32) !Request {
    var buf = try a.alloc(u8, max_head);
    var have: usize = 0;
    const head_end = while (true) {
        if (std.mem.indexOf(u8, buf[0..have], "\r\n\r\n")) |p| break p + 4;
        if (have == buf.len) return error.HeaderTooLarge;
        const n = try recvSome(c, buf[have..]);
        if (n == 0) return if (have == 0) error.Closed else error.BadRequest;
        have += n;
    };
    const head = buf[0..head_end];
    const line_end = std.mem.indexOf(u8, head, "\r\n").?;
    var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
    const method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    const version = parts.next() orelse return error.BadRequest;
    if (parts.next() != null or !std.mem.startsWith(u8, version, "HTTP/1.")) return error.BadRequest;
    if (method.len == 0 or method.len > 16 or target.len == 0 or target[0] != '/') return error.BadRequest;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    var headers: std.ArrayList(Header) = .empty;
    var content_length: ?usize = null;
    var lines = std.mem.splitSequence(u8, head[line_end + 2 .. head_end - 4], "\r\n");
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse return error.BadRequest;
        const name = std.mem.trim(u8, l[0..colon], " \t");
        const value = std.mem.trim(u8, l[colon + 1 ..], " \t");
        if (name.len == 0) return error.BadRequest;
        if (headers.items.len >= 64) return error.HeaderTooLarge;
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (content_length != null) return error.BadRequest;
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.BadRequest;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) return error.LengthRequired;
        try headers.append(a, .{ .name = name, .value = value });
    }
    const cl = content_length orelse 0;
    if (cl > max_body) return error.BodyTooLarge;
    const body = try a.alloc(u8, cl);
    const pre = have - head_end;
    if (pre > cl) return error.BadRequest;
    @memcpy(body[0..pre], buf[head_end..have]);
    var got = pre;
    while (got < cl) {
        const n = try recvSome(c, body[got..]);
        if (n == 0) return error.BadRequest;
        got += n;
    }
    const query = if (path.len < target.len) target[path.len + 1 ..] else "";
    return .{ .method = method, .path = path, .query = query, .headers = headers.items, .body = body };
}

pub fn reason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        202 => "Accepted",
        303 => "See Other",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        411 => "Length Required",
        413 => "Payload Too Large",
        415 => "Unsupported Media Type",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        else => "Status",
    };
}

fn sendStatus(c: i32, status: u16, body: []const u8) void {
    var buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, reason(status), body.len }) catch return;
    sendAll(c, head) catch return;
    sendAll(c, body) catch {};
}

fn writeResponse(a: std.mem.Allocator, c: i32, r: Response) !void {
    const head = try std.fmt.allocPrint(a, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n{s}\r\n", .{ r.status, reason(r.status), r.ctype, r.body.len, r.extra });
    try sendAll(c, head);
    try sendAll(c, r.body);
}

test "bind policy: loopback and tailnet only" {
    const t = std.testing;
    try t.expectEqual([4]u8{ 127, 0, 0, 1 }, try parseBind("127.0.0.1"));
    try t.expectEqual([4]u8{ 100, 100, 1, 1 }, try parseBind("100.100.1.1"));
    try t.expectEqual([4]u8{ 100, 64, 0, 1 }, try parseBind("100.64.0.1"));
    for ([_][]const u8{ "0.0.0.0", "192.0.2.1", "172.16.0.1", "127.0.0.2", "100.128.0.1", "100.63.255.255", "8.8.8.8", "255.255.255.255" }) |s|
        try t.expectError(error.Unsafe, parseBind(s));
    for ([_][]const u8{ "", "::1", "::", "localhost", "127.0.0.1:80", "1.2.3", "1.2.3.4.5", "256.0.0.1", "01234.0.0.1", "127.0.0.1 " }) |s|
        try t.expectError(error.BadAddress, parseBind(s));
}
