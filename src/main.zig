//! zigmem: CLI entry. Phase 0 runs the proxy with one frozen memory file; phase 4 adds `serve | token | people`.
const std = @import("std");
const proxy = @import("proxy.zig");
const api = @import("api");
const panel = @import("panel");
const connect = @import("adapters/connect.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

const usage = "usage: zigmem proxy --upstream http://IP:PORT [--port 18140] [--memory FILE]\n";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len >= 2) for ([_][]const u8{ "serve", "token", "people", "household" }) |c| if (std.mem.eql(u8, args[1], c))
        return api.cli.main(init, args, .{ .start = startProxy, .message = proxy.memoryMessage, .panel = panel.wrap });
    if (args.len >= 2 and std.mem.eql(u8, args[1], "connect")) return connect.main(init, args);
    if (args.len < 2 or !std.mem.eql(u8, args[1], "proxy")) fail(usage ++ api.cli.usage ++ connect.usage, .{});
    var port: u16 = 18140;
    var upstream: ?std.Io.net.IpAddress = null;
    var upstream_host: []const u8 = "";
    var memory_path: ?[]const u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        const a: []const u8 = args[i];
        if (i + 1 >= args.len) fail("missing value for {s}\n" ++ usage, .{a});
        const v: []const u8 = args[i + 1];
        if (std.mem.eql(u8, a, "--port")) {
            port = std.fmt.parseInt(u16, v, 10) catch fail("bad --port\n", .{});
        } else if (std.mem.eql(u8, a, "--upstream")) {
            const hp = if (std.mem.startsWith(u8, v, "http://")) v[7..] else fail("--upstream must be http://IP:PORT\n", .{});
            upstream_host = std.mem.trimEnd(u8, hp, "/");
            const colon = std.mem.lastIndexOfScalar(u8, upstream_host, ':') orelse fail("--upstream needs a port\n", .{});
            const up_port = std.fmt.parseInt(u16, upstream_host[colon + 1 ..], 10) catch fail("bad upstream port\n", .{});
            upstream = std.Io.net.IpAddress.parse(upstream_host[0..colon], up_port) catch fail("--upstream host must be an IP literal\n", .{});
        } else if (std.mem.eql(u8, a, "--memory")) {
            memory_path = v;
        } else fail("unknown flag {s}\n" ++ usage, .{a});
    }
    const frozen = try arena.create(proxy.Frozen);
    frozen.* = .{ .message = "" };
    if (memory_path) |p| {
        const raw = std.Io.Dir.cwd().readFileAlloc(init.io, p, arena, .limited(1 << 24)) catch |e| fail("cannot read --memory: {s}\n", .{@errorName(e)});
        frozen.message = try proxy.memoryMessage(arena, raw);
        var d: [32]u8 = undefined;
        Sha256.hash(raw, &d, .{});
        var d2: [32]u8 = undefined;
        Sha256.hash(frozen.message, &d2, .{});
        std.debug.print("memory frozen: file={d}B sha256={x} message={d}B sha256={x}{s}\n", .{ raw.len, d, frozen.message.len, d2, if (frozen.message.len == 0) " (empty = exact passthrough)" else "" });
    } else std.debug.print("no --memory: exact passthrough\n", .{});
    try proxy.serve(init.gpa, .{ .port = port, .upstream = upstream orelse fail(usage, .{}), .upstream_host = upstream_host, .memory = frozen.source() });
}

/// Phase 4: run the phase-0 proxy beside the hub, its block coming from the store (one frozen block per session).
fn startProxy(gpa: std.mem.Allocator, port: u16, upstream: []const u8, ctx: *const anyopaque, blockFn: *const fn (*const anyopaque, []const u8) []const u8, authBlockFn: *const fn (*const anyopaque, []const u8, []const u8) ?[]const u8) anyerror!void {
    const hp = if (std.mem.startsWith(u8, upstream, "http://")) std.mem.trimEnd(u8, upstream[7..], "/") else return error.UpstreamMustBeHttpIpPort;
    const colon = std.mem.lastIndexOfScalar(u8, hp, ':') orelse return error.UpstreamMustBeHttpIpPort;
    const up_port = try std.fmt.parseInt(u16, hp[colon + 1 ..], 10);
    const addr = try std.Io.net.IpAddress.parse(hp[0..colon], up_port);
    const t = try std.Thread.spawn(.{}, serveProxy, .{ gpa, proxy.Config{ .port = port, .upstream = addr, .upstream_host = hp, .memory = .{ .ctx = ctx, .blockFn = blockFn, .authBlockFn = authBlockFn } } });
    t.detach();
}

fn serveProxy(gpa: std.mem.Allocator, cfg: proxy.Config) void {
    proxy.serve(gpa, cfg) catch |e| std.debug.print("zigmem proxy: stopped: {s}\n", .{@errorName(e)});
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zigmem: " ++ fmt, args);
    std.process.exit(2);
}

test {
    _ = proxy;
    _ = connect;
}
