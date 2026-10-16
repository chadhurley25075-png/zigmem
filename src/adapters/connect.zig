//! `zigmem connect <tool> --print` (phase 7): prints the exact commands and snippets a person runs to connect a tool
//! to zigmem. zigmem NEVER edits another tool's files (SPEC §2 B6): this code opens no file, makes no network call,
//! runs no child process, and refuses to run without `--print`. Every value it prints is validated against a strict
//! charset first, so nothing it prints can break out of the shell/JSON/TOML quoting around it.
const std = @import("std");
const linux = std.os.linux;

pub const usage =
    \\  zigmem connect claude-code|pi|openai|codex|openclaw|hermes|all --print [--url http://127.0.0.1:8470]
    \\                 [--seat NAME] [--scopes a,b] [--token-file /abs/path] [--scope local|user|project]
    \\                 [--proxy-port P] [--upstream http://IP:PORT] [--session KEY] [--adapters /abs/dir] [--zigmem /abs/bin]
    \\
;

pub const Tool = enum { @"claude-code", pi, openai, codex, openclaw, hermes };
const all_tools = [_]Tool{ .@"claude-code", .pi, .openai, .codex, .openclaw, .hermes };

pub const Opts = struct {
    url: []const u8 = "http://127.0.0.1:8470",
    seat: []const u8 = "",
    scopes: []const u8 = "shadow",
    token_file: []const u8 = "",
    cc_scope: []const u8 = "local",
    proxy_port: u16 = 18141,
    upstream: []const u8 = "http://127.0.0.1:18080",
    session: []const u8 = "default",
    adapters: []const u8 = "",
    zigmem: []const u8 = "",
};

pub const Error = error{ BadUrl, BadPath, BadName, BadScopes, BadScope, BadUpstream, OutOfMemory };

fn defaultSeat(t: Tool) []const u8 {
    return switch (t) {
        .@"claude-code" => "claude",
        .pi => "pi",
        .openai => "proxy",
        .codex => "codex",
        .openclaw => "openclaw",
        .hermes => "hermes",
    };
}

fn parseIp4(s: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    var n: usize = 0;
    while (it.next()) |p| : (n += 1) {
        if (n >= 4 or p.len == 0 or p.len > 3) return null;
        for (p) |c| if (c < '0' or c > '9') return null;
        out[n] = std.fmt.parseInt(u8, p, 10) catch return null;
    }
    return if (n == 4) out else null;
}

/// `http://IP:PORT`, no path, no trailing slash. `loopback_or_tailnet` = the hub's own bind rule (127.0.0.1 or 100.64/10).
fn checkUrl(u: []const u8, loopback_or_tailnet: bool) bool {
    if (!std.mem.startsWith(u8, u, "http://")) return false;
    const hp = u[7..];
    const colon = std.mem.lastIndexOfScalar(u8, hp, ':') orelse return false;
    const port = std.fmt.parseInt(u16, hp[colon + 1 ..], 10) catch return false;
    if (port == 0) return false;
    const ip = parseIp4(hp[0..colon]) orelse return false;
    if (!loopback_or_tailnet) return true;
    if (ip[0] == 127 and ip[1] == 0 and ip[2] == 0 and ip[3] == 1) return true;
    return ip[0] == 100 and ip[1] >= 64 and ip[1] <= 127;
}

fn checkPath(p: []const u8) bool {
    if (p.len == 0 or p.len > 512 or p[0] != '/') return false;
    if (std.mem.indexOf(u8, p, "..") != null) return false;
    for (p) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '/', '.', '_', '-', '+' => {},
        else => return false,
    };
    return true;
}

fn checkName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

fn checkScopes(s: []const u8) bool {
    if (s.len == 0 or s.len > 512 or s[0] == ',' or s[s.len - 1] == ',') return false;
    for (s) |c| switch (c) {
        'a'...'z', '0'...'9', ':', '_', '-', ',' => {},
        else => return false,
    };
    return std.mem.indexOf(u8, s, ",,") == null;
}

/// Fills defaults that depend on HOME and the tool, then validates every field. Returns the effective options.
pub fn resolve(a: std.mem.Allocator, t: Tool, home: []const u8, in: Opts) Error!Opts {
    var o = in;
    if (o.seat.len == 0) o.seat = defaultSeat(t);
    if (o.token_file.len == 0) o.token_file = try std.fmt.allocPrint(a, "{s}/.config/zigmem/{s}.token", .{ home, o.seat });
    if (o.adapters.len == 0) o.adapters = try std.fmt.allocPrint(a, "{s}/zigmem/adapters", .{home});
    if (o.zigmem.len == 0) o.zigmem = try std.fmt.allocPrint(a, "{s}/zigmem/zig-out/bin/zigmem", .{home});
    if (!checkUrl(o.url, true)) return error.BadUrl;
    if (!checkUrl(o.upstream, false)) return error.BadUpstream;
    if (!checkName(o.seat) or !checkName(o.session)) return error.BadName;
    if (!checkScopes(o.scopes)) return error.BadScopes;
    if (!checkPath(o.token_file) or !checkPath(o.adapters) or !checkPath(o.zigmem)) return error.BadPath;
    const ok_scope = for ([_][]const u8{ "local", "user", "project" }) |s| {
        if (std.mem.eql(u8, s, o.cc_scope)) break true;
    } else false;
    if (!ok_scope) return error.BadScope;
    return o;
}

const Out = struct {
    a: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    fn p(w: *Out, comptime fmt: []const u8, args: anytype) Error!void {
        try w.buf.appendSlice(w.a, try std.fmt.allocPrint(w.a, fmt, args));
    }
};

fn mint(w: *Out, o: Opts, writes: bool) Error!void {
    const slash = std.mem.lastIndexOfScalar(u8, o.token_file, '/') orelse 0;
    const dir = if (slash == 0) "/" else o.token_file[0..slash];
    try w.p(
        \\# 1. Mint a seat token for this tool (printed once; only its sha256 is kept by zigmem) into a 0600 file:
        \\install -d -m 700 {s} && install -m 600 /dev/null {s}
        \\{s} token add --seat {s} --scopes {s}{s} > {s}
        \\
    , .{ dir, o.token_file, o.zigmem, o.seat, o.scopes, if (writes) " --writes" else "", o.token_file });
}

fn claudeCode(w: *Out, o: Opts) Error!void {
    try w.p("# zigmem -> Claude Code: MCP over streamable HTTP at {s}/mcp.\n# zigmem does not touch any Claude Code file. You run these; `claude mcp` writes its own config.\n", .{o.url});
    try mint(w, o, true);
    try w.p(
        \\# 2. Register (recommended): a headersHelper reads the token file at connect time, so no token is stored in
        \\#    ~/.claude.json. User scope, because Claude Code runs a helper from local/project scope only in a TRUSTED
        \\#    workspace (it skips it with "missing_trust" otherwise, e.g. under `claude -p` in an untrusted dir).
        \\claude mcp add-json --scope user zigmem '{{"type":"http","url":"{s}/mcp","headersHelper":"{s}/claude-code/zigmem_headers.sh {s}"}}'
        \\#    undo: claude mcp remove --scope user zigmem
        \\# 2'. Or the plain form, any scope (Claude Code then stores the bearer in clear in ~/.claude.json while registered):
        \\claude mcp add --scope {s} --transport http zigmem {s}/mcp --header "Authorization: Bearer $(cat {s})"
        \\#    undo: claude mcp remove --scope {s} zigmem
        \\# 3. Check: claude mcp get zigmem
        \\# Tools: mcp__zigmem__memory_search, memory_recall, memory_add, memory_get, memory_block. No hooks are added.
        \\
    , .{ o.url, o.adapters, o.token_file, o.cc_scope, o.url, o.token_file, o.cc_scope });
}

fn pi(w: *Out, o: Opts) Error!void {
    try w.p("# zigmem -> pi: a TOOLS-ONLY extension (no pi.on hooks), staged at {s}/pi/zigmem_memory.ts.\n# It is not installed anywhere; zigmem never writes ~/.pi. Load it explicitly per run:\n", .{o.adapters});
    try mint(w, o, true);
    try w.p(
        \\# 2. Run pi with the extension (works with --no-extensions; explicit -e paths still load):
        \\ZIGMEM_URL={s} ZIGMEM_TOKEN_FILE={s} pi -e {s}/pi/zigmem_memory.ts
        \\# If the seat passes --tools as an allowlist, add:
        \\#   zigmem_memory_search,zigmem_memory_recall,zigmem_memory_add,zigmem_memory_get,zigmem_memory_block
        \\
    , .{ o.url, o.token_file, o.adapters });
}

fn openai(w: *Out, o: Opts) Error!void {
    try w.p(
        \\# zigmem -> any OpenAI-compatible client, through proxy mode: the client only changes its base URL, sends the
        \\# seat token as its API key (Authorization: Bearer; consumed by the proxy, never forwarded) and one session
        \\# header. zigmem injects that seat's frozen memory block after the system message; everything else passes
        \\# through byte for byte. No valid seat token → 401, nothing forwarded.
        \\
    , .{});
    try mint(w, o, false);
    try w.p(
        \\# 2. Run the hub with the proxy beside it (upstream must be an IP literal):
        \\{s} serve --port {s} --proxy-upstream {s} --proxy-port {d}
        \\# 3. Point the client at it:
        \\#   base_url = http://127.0.0.1:{d}/v1   api_key = <the seat token>   header  x-zigmem-session: {s}
        \\curl -s http://127.0.0.1:{d}/v1/chat/completions -H 'Content-Type: application/json' -H 'x-zigmem-session: {s}' \
        \\  -H "Authorization: Bearer $(cat {s})" \
        \\  -d '{{"model":"glm-5.3-flash","messages":[{{"role":"system","content":"You are helpful."}},{{"role":"user","content":"hello"}}]}}'
        \\# Python (openai SDK):
        \\#   OpenAI(base_url="http://127.0.0.1:{d}/v1", api_key=open("{s}").read().strip(), default_headers={{"x-zigmem-session": "{s}"}})
        \\# Example client: {s}/openai/zigmem_client.py --token-file {s}
        \\
    , .{ o.zigmem, portOf(o.url), o.upstream, o.proxy_port, o.proxy_port, o.session, o.proxy_port, o.session, o.token_file, o.proxy_port, o.token_file, o.session, o.adapters, o.token_file });
}

fn portOf(u: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, u, ':') orelse return "8470";
    return u[i + 1 ..];
}

fn codex(w: *Out, o: Opts) Error!void {
    try w.p("# zigmem -> Codex: MCP over streamable HTTP. zigmem never writes ~/.codex; you add this yourself.\n", .{});
    try mint(w, o, true);
    try w.p(
        \\# 2. Add to ~/.codex/config.toml (the token stays in your environment, not in the file):
        \\[mcp_servers.zigmem]
        \\url = "{s}/mcp"
        \\bearer_token_env_var = "ZIGMEM_TOKEN"
        \\# (same thing via Codex's own command: codex mcp add zigmem --url {s}/mcp --bearer-token-env-var ZIGMEM_TOKEN)
        \\# 3. Start Codex with the token in its environment:
        \\ZIGMEM_TOKEN="$(cat {s})" codex
        \\# Undo: codex mcp remove zigmem   (or delete the [mcp_servers.zigmem] table)
        \\
    , .{ o.url, o.url, o.token_file });
}

fn openclaw(w: *Out, o: Opts) Error!void {
    try w.p(
        \\# zigmem -> OpenClaw: MCP only, through OpenClaw's own `openclaw mcp set`. OpenClaw is never patched and no
        \\# plugin is installed; zigmem never edits ~/.openclaw/openclaw.json or OpenClaw's dist files.
        \\
    , .{});
    try mint(w, o, true);
    try w.p(
        \\# 2. Save the server in OpenClaw's config with its own command (the bearer is stored in openclaw.json;
        \\#    OpenClaw redacts headers in logs/status):
        \\openclaw mcp set zigmem "{{\"url\":\"{s}/mcp\",\"transport\":\"streamable-http\",\"headers\":{{\"Authorization\":\"Bearer $(cat {s})\"}}}}"
        \\# Check, and undo:
        \\openclaw mcp show zigmem
        \\openclaw mcp unset zigmem
        \\
    , .{ o.url, o.token_file });
}

fn hermes(w: *Out, o: Opts) Error!void {
    try w.p(
        \\# zigmem -> Hermes: two documented routes; zigmem installs nothing into Hermes (no symlinks into its tree,
        \\# no memory.provider edit) and never accepts a `Bearer local` placeholder token.
        \\
    , .{});
    try mint(w, o, true);
    try w.p(
        \\# 2a. MCP: add to ~/.hermes/config.yaml yourself:
        \\# mcp_servers:
        \\#   zigmem:
        \\#     url: "{s}/mcp"
        \\#     headers:
        \\#       Authorization: "Bearer <contents of {s}>"
        \\# 2b. v1 HTTP (the shape Hermes memory plugins call): base URL {s}, routes /v1/recall /v1/capture
        \\#     /v1/search/memories /v1/search/conversations /v1/session/end, header Authorization: Bearer <token>.
        \\curl -s {s}/v1/recall -H "Authorization: Bearer $(cat {s})" -H 'Content-Type: application/json' -d '{{"query":"hello","session_key":"{s}"}}'
        \\
    , .{ o.url, o.token_file, o.url, o.url, o.token_file, o.session });
}

pub fn render(a: std.mem.Allocator, t: Tool, o: Opts) Error![]u8 {
    var w: Out = .{ .a = a };
    switch (t) {
        .@"claude-code" => try claudeCode(&w, o),
        .pi => try pi(&w, o),
        .openai => try openai(&w, o),
        .codex => try codex(&w, o),
        .openclaw => try openclaw(&w, o),
        .hermes => try hermes(&w, o),
    }
    return w.buf.items;
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zigmem connect: " ++ fmt, args);
    std.process.exit(2);
}

fn writeAll(s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const rc = linux.write(1, s[off..].ptr, s.len - off);
        if (linux.errno(rc) != .SUCCESS) return;
        off += rc;
    }
}

pub fn main(init: std.process.Init, args: []const [:0]const u8) !void {
    const a = init.arena.allocator();
    if (args.len < 3) fail("missing tool\nusage:\n{s}", .{usage});
    const which: []const u8 = args[2];
    var print = false;
    var o: Opts = .{};
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const k: []const u8 = args[i];
        if (std.mem.eql(u8, k, "--print")) {
            print = true;
            continue;
        }
        if (i + 1 >= args.len) fail("missing value for {s}\n", .{k});
        i += 1;
        const v: []const u8 = args[i];
        if (std.mem.eql(u8, k, "--url")) o.url = v else if (std.mem.eql(u8, k, "--seat")) o.seat = v else if (std.mem.eql(u8, k, "--scopes")) o.scopes = v else if (std.mem.eql(u8, k, "--token-file")) o.token_file = v else if (std.mem.eql(u8, k, "--scope")) o.cc_scope = v else if (std.mem.eql(u8, k, "--upstream")) o.upstream = v else if (std.mem.eql(u8, k, "--session")) o.session = v else if (std.mem.eql(u8, k, "--adapters")) o.adapters = v else if (std.mem.eql(u8, k, "--zigmem")) o.zigmem = v else if (std.mem.eql(u8, k, "--proxy-port")) {
            o.proxy_port = std.fmt.parseInt(u16, v, 10) catch fail("bad --proxy-port\n", .{});
        } else fail("unknown flag {s}\nusage:\n{s}", .{ k, usage });
    }
    if (!print) fail("refusing: zigmem never edits another tool's config. Re-run with --print and run what it prints yourself.\n", .{});
    const home = init.environ_map.get("HOME") orelse fail("HOME is not set\n", .{});
    const tools: []const Tool = if (std.mem.eql(u8, which, "all"))
        &all_tools
    else
        &[_]Tool{std.meta.stringToEnum(Tool, which) orelse fail("unknown tool {s}\nusage:\n{s}", .{ which, usage })};
    for (tools, 0..) |t, n| {
        const r = resolve(a, t, home, o) catch |e| fail("{s}: {s}\n", .{ @tagName(t), @errorName(e) });
        if (n > 0) writeAll("\n");
        writeAll(try render(a, t, r));
    }
}

// ---- tests ----

const T = std.testing;

test "defaults resolve from HOME and the tool" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const o = try resolve(arena.allocator(), .@"claude-code", "/home/x", .{});
    try T.expectEqualStrings("claude", o.seat);
    try T.expectEqualStrings("/home/x/.config/zigmem/claude.token", o.token_file);
    const txt = try render(arena.allocator(), .@"claude-code", o);
    try T.expect(std.mem.indexOf(u8, txt, "claude mcp add-json --scope user zigmem '{\"type\":\"http\",\"url\":\"http://127.0.0.1:8470/mcp\",\"headersHelper\":\"/home/x/zigmem/adapters/claude-code/zigmem_headers.sh /home/x/.config/zigmem/claude.token\"}'") != null);
    try T.expect(std.mem.indexOf(u8, txt, "claude mcp remove --scope local zigmem") != null);
    try T.expect(std.mem.indexOf(u8, txt, "claude mcp remove --scope user zigmem") != null);
}

test "every tool renders, and no rendered text carries an unfilled placeholder" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    for (all_tools) |t| {
        const o = try resolve(arena.allocator(), t, "/home/x", .{});
        const txt = try render(arena.allocator(), t, o);
        try T.expect(txt.len > 200);
        try T.expect(std.mem.indexOf(u8, txt, "{s}") == null);
        try T.expect(std.mem.indexOf(u8, txt, "/home/x/.config/zigmem/") != null);
    }
}

test "hostile values are refused before anything is printed" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad_urls = [_][]const u8{ "http://0.0.0.0:8470", "http://192.0.2.1:8470", "https://127.0.0.1:8470", "http://127.0.0.1:8470/", "http://127.0.0.1:8470'; rm -rf ~", "http://100.128.0.1:1", "http://127.0.0.1:0" };
    for (bad_urls) |u| try T.expectError(error.BadUrl, resolve(a, .pi, "/home/x", .{ .url = u }));
    try T.expect((try resolve(a, .pi, "/home/x", .{ .url = "http://100.100.1.1:8470" })).url.len > 0);
    const bad_paths = [_][]const u8{ "relative/tok", "/tmp/a b", "/tmp/$(id)", "/tmp/a'b", "/tmp/a\"b", "/tmp/../etc/passwd", "~/tok", "" };
    for (bad_paths) |p| if (p.len > 0) try T.expectError(error.BadPath, resolve(a, .codex, "/home/x", .{ .token_file = p }));
    try T.expectError(error.BadName, resolve(a, .codex, "/home/x", .{ .seat = "a b" }));
    try T.expectError(error.BadName, resolve(a, .openai, "/home/x", .{ .session = "s;id" }));
    try T.expectError(error.BadScopes, resolve(a, .codex, "/home/x", .{ .scopes = "A,b" }));
    try T.expectError(error.BadScopes, resolve(a, .codex, "/home/x", .{ .scopes = "a,,b" }));
    try T.expectError(error.BadScope, resolve(a, .@"claude-code", "/home/x", .{ .cc_scope = "global" }));
    try T.expectError(error.BadUpstream, resolve(a, .openai, "/home/x", .{ .upstream = "http://engine-host:18080" }));
}
