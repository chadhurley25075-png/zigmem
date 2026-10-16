//! Privacy gate root: compiled patterns (verbatim from the Python reference) + Python str helpers + the Gates handle.
//! Ports, each held to 100% parity with ~/reference_filters.py: private (store/private.zig), echo, ledger, medscope.
const std = @import("std");
pub const re = @import("re.zig");
pub const pat = @import("patterns.zig");
pub const private = @import("store").private;
pub const ledger = @import("ledger.zig");
pub const medscope = @import("medscope.zig");
pub const echo = @import("echo.zig");
pub const escape = @import("escape.zig");
pub const strict = @import("strict.zig");
const Regex = re.Regex;

/// Code-point string helpers with Python `str` semantics.
pub const U = []const u21;

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) ![]u21 {
    const t = try re.Text.init(gpa, bytes);
    gpa.free(t.off);
    return t.cps;
}

pub fn encode(gpa: std.mem.Allocator, cps: U) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [4]u8 = undefined;
    for (cps) |c| {
        const n = std.unicode.utf8Encode(c, &buf) catch {
            try out.appendSlice(gpa, "\u{FFFD}");
            continue;
        };
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

/// str.lower()
pub fn lowerCps(gpa: std.mem.Allocator, s: U) ![]u21 {
    var out: std.ArrayList(u21) = .empty;
    errdefer out.deinit(gpa);
    for (s) |c| {
        const l = re.lowerFull(c);
        try out.append(gpa, l[0]);
        if (l[1] != 0) try out.append(gpa, l[1]);
    }
    return out.toOwnedSlice(gpa);
}

pub fn lowerBytes(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var ascii = true;
    for (s) |b| if (b >= 0x80) {
        ascii = false;
        break;
    };
    if (ascii) return std.ascii.allocLowerString(gpa, s);
    const c = try decode(gpa, s);
    defer gpa.free(c);
    const l = try lowerCps(gpa, c);
    defer gpa.free(l);
    return encode(gpa, l);
}

/// str.strip() (Unicode whitespace) on bytes.
pub fn strip(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b) {
        const n = std.unicode.utf8ByteSequenceLength(s[a]) catch break;
        if (a + n > b) break;
        const cp = std.unicode.utf8Decode(s[a .. a + n]) catch break;
        if (!re.isSpace(cp)) break;
        a += n;
    }
    while (b > a) {
        var st = b - 1;
        while (st > a and (s[st] & 0xC0) == 0x80) st -= 1;
        const cp = std.unicode.utf8Decode(s[st..b]) catch break;
        if (!re.isSpace(cp)) break;
        b = st;
    }
    return s[a..b];
}

/// `needle in hay` / hay.find(needle, from) on code points.
pub fn findCp(hay: U, needle: U, from: usize) ?usize {
    if (needle.len == 0) return if (from <= hay.len) from else null;
    if (needle.len > hay.len) return null;
    var i = from;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.mem.eql(u21, hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Python slice indices s[a:b] for possibly negative/oversized bounds.
pub fn pySlice(s: U, a: i64, b: i64) U {
    const n: i64 = @intCast(s.len);
    var lo = if (a < 0) @max(0, n + a) else @min(a, n);
    var hi = if (b < 0) @max(0, n + b) else @min(b, n);
    if (hi < lo) hi = lo;
    lo = @max(0, lo);
    return s[@intCast(lo)..@intCast(hi)];
}

pub fn compile(gpa: std.mem.Allocator, p: pat.P) !Regex {
    return Regex.compile(gpa, p.pat, .{ .i = p.i, .s = p.s });
}

/// Every regex the gates use, compiled once.
pub const Rx = struct {
    self_echo: Regex,
    first_person: Regex,
    self_echo_lead: Regex,
    assistant_tag: Regex,
    correction: Regex,
    dated: Regex,
    durable: Regex,
    transcript_prefix: Regex,
    empty_fragment: Regex,
    clock_heading: Regex,
    tool_log: Regex,
    tool_log2: Regex,
    tool_rewrite: Regex,
    tool_rewrite_path: Regex,
    tool_rewrite_at: Regex,
    file_meta: Regex,
    toolu: Regex,
    money: Regex,
    supersession_cue: Regex,
    clause: Regex,
    kw_tok: Regex,
    wd_before: Regex,
    wd_after: Regex,
    wd_ny: Regex,
    line_date: Regex,
    word: Regex,
    med_cue: Regex,
    sent_split: Regex,
    mt_labels: Regex,
    mt_start: Regex,
    mt_ready: Regex,
    mt_session_end: Regex,
    priv_open: Regex,
    // inline patterns in the Python functions (copied by hand, each named after its function)
    full_iso: Regex, // _parse_full_date
    full_slash: Regex,
    full_mon: Regex,
    md_slash: Regex, // _md
    md_mon: Regex,
    mt_split: Regex, // is_machine_traffic: re.split(r"\s+\|\s+", t)
    mt_q: Regex, // re.match(r"^\s*Q\s*:", segs[0], re.I)
    mt_words: Regex, // re.findall(r"[A-Za-z']+", s)
    rel: [pat.rel.len]Regex,
    family: [pat.family.len]Regex,
    alias: [pat.alias.len]Regex,

    pub fn init(gpa: std.mem.Allocator) !Rx {
        var r: Rx = undefined;
        const info = @typeInfo(Rx).@"struct";
        inline for (info.field_names, info.field_types) |name, T| {
            if (comptime T == Regex and @hasDecl(pat, name)) @field(r, name) = try compile(gpa, @field(pat, name));
        }
        r.full_iso = try Regex.compile(gpa, "(20\\d\\d)-(\\d\\d)-(\\d\\d)", .{});
        r.full_slash = try Regex.compile(gpa, "(\\d{1,2})/(\\d{1,2})/((?:20)?\\d\\d)", .{});
        r.full_mon = try Regex.compile(gpa, "([A-Za-z]{3})[a-z]*\\.? (\\d{1,2}),? (20\\d\\d)", .{});
        r.md_slash = try Regex.compile(gpa, "(\\d{1,2})/(\\d{1,2})", .{});
        r.md_mon = try Regex.compile(gpa, "([A-Za-z]{3})[a-z]*\\.? (\\d{1,2})", .{});
        r.mt_split = try Regex.compile(gpa, "\\s+\\|\\s+", .{});
        r.mt_q = try Regex.compile(gpa, "^\\s*Q\\s*:", .{ .i = true });
        r.mt_words = try Regex.compile(gpa, "[A-Za-z']+", .{});
        for (pat.rel, 0..) |x, k| r.rel[k] = try compile(gpa, x.p);
        for (pat.family, 0..) |x, k| r.family[k] = try compile(gpa, x.p);
        for (pat.alias, 0..) |x, k| r.alias[k] = try compile(gpa, x.p);
        return r;
    }

    pub fn deinit(r: *Rx) void {
        const info = @typeInfo(Rx).@"struct";
        inline for (info.field_names, info.field_types) |name, T| {
            if (T == Regex) @field(r, name).deinit();
        }
        for (&r.rel) |*x| x.deinit();
        for (&r.family) |*x| x.deinit();
        for (&r.alias) |*x| x.deinit();
    }
};

/// The config switches is_self_echo & co read (CONFIG in the Python; ~/.claude/injection_thresholds.json).
pub const Config = struct {
    drop_self_echo: bool = true,
    drop_dated_claims: bool = true,
    drop_transcript_dumps: bool = true,
    drop_tool_logs: bool = true,
};

pub const MedMode = enum { enforce, shadow, off };

/// One gate handle per process: compiled patterns + the parsed ledger. `today` drives the year-less calendar note and
/// REVIEW OVERDUE, exactly like date.today() in the Python.
pub const Gates = struct {
    gpa: std.mem.Allocator,
    rx: Rx,
    led: ledger.Ledger,
    cfg: Config = .{},
    today: ledger.Date,
    private_on: bool = true,

    pub fn init(gpa: std.mem.Allocator, ledger_json: ?[]const u8, today: ledger.Date) !Gates {
        var rx = try Rx.init(gpa);
        errdefer rx.deinit();
        const led = try ledger.Ledger.parse(gpa, &rx, ledger_json);
        return .{ .gpa = gpa, .rx = rx, .led = led, .today = today };
    }

    pub fn deinit(g: *Gates) void {
        g.led.deinit();
        g.rx.deinit();
    }
};

test {
    _ = re;
    _ = ledger;
    _ = medscope;
    _ = echo;
    _ = escape;
}
