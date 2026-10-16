//! Panel text plumbing: HTML escaping (every dynamic value goes through `esc`), URL percent-coding, query/form
//! parsing, cookie reading, and the page shell (strict nonce CSP; CSS and JS embedded, nothing loaded from anywhere).
const std = @import("std");

pub const css = @embedFile("assets/panel.css");
pub const js = @embedFile("assets/panel.js");

pub const Buf = std.ArrayList(u8);

/// HTML-escape for text AND double-quoted attribute values. Invalid UTF-8 → U+FFFD; C0 controls (but \t \n \r) dropped.
pub fn esc(a: std.mem.Allocator, b: *Buf, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const ch = s[i];
        if (ch < 0x80) {
            switch (ch) {
                '&' => try b.appendSlice(a, "&amp;"),
                '<' => try b.appendSlice(a, "&lt;"),
                '>' => try b.appendSlice(a, "&gt;"),
                '"' => try b.appendSlice(a, "&quot;"),
                '\'' => try b.appendSlice(a, "&#39;"),
                '`' => try b.appendSlice(a, "&#96;"),
                '\t', '\n', '\r' => try b.append(a, ch),
                0...8, 11, 12, 14...0x1f, 0x7f => {},
                else => try b.append(a, ch),
            }
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(ch) catch 0;
        if (n == 0 or i + n > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + n])) {
            try b.appendSlice(a, "\u{FFFD}");
            i += 1;
            continue;
        }
        try b.appendSlice(a, s[i .. i + n]);
        i += n;
    }
}

/// `esc` of at most `max` bytes, cut on a UTF-8 boundary, with an ellipsis when cut.
pub fn escCut(a: std.mem.Allocator, b: *Buf, s: []const u8, max: usize) !void {
    if (s.len <= max) return esc(a, b, s);
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    try esc(a, b, s[0..n]);
    try b.appendSlice(a, "…");
}

/// Percent-encode for a query value (unreserved bytes kept). The result is also HTML-safe.
pub fn urlEnc(a: std.mem.Allocator, b: *Buf, s: []const u8) !void {
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try b.append(a, ch);
        } else try b.print(a, "%{X:0>2}", .{ch});
    }
}

fn hexVal(c: u8) ?u8 {
    return std.fmt.charToDigit(c, 16) catch null;
}

/// Decode application/x-www-form-urlencoded (`+` = space). Bad escapes → error.
pub fn urlDec(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try a.alloc(u8, s.len);
    var o: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (o += 1) {
        switch (s[i]) {
            '+' => {
                out[o] = ' ';
                i += 1;
            },
            '%' => {
                if (i + 2 >= s.len) return error.BadForm;
                const hi = hexVal(s[i + 1]) orelse return error.BadForm;
                const lo = hexVal(s[i + 2]) orelse return error.BadForm;
                out[o] = hi * 16 + lo;
                i += 3;
            },
            else => {
                out[o] = s[i];
                i += 1;
            },
        }
    }
    return out[0..o];
}

pub const Field = struct { k: []const u8, v: []const u8 };

/// A parsed query string or form body. First value wins for duplicate keys. At most 32 fields.
pub const Form = struct {
    fields: []const Field = &.{},

    pub fn parse(a: std.mem.Allocator, s: []const u8) !Form {
        var list: std.ArrayList(Field) = .empty;
        var it = std.mem.splitScalar(u8, s, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            if (list.items.len >= 32) return error.BadForm;
            const eq = std.mem.indexOfScalar(u8, pair, '=');
            const k = try urlDec(a, pair[0 .. eq orelse pair.len]);
            const v = if (eq) |e| try urlDec(a, pair[e + 1 ..]) else "";
            try list.append(a, .{ .k = k, .v = v });
        }
        return .{ .fields = list.items };
    }

    pub fn get(f: Form, k: []const u8) ?[]const u8 {
        for (f.fields) |x| if (std.mem.eql(u8, x.k, k)) return x.v;
        return null;
    }

    /// Present and non-empty.
    pub fn val(f: Form, k: []const u8) ?[]const u8 {
        const v = f.get(k) orelse return null;
        return if (v.len == 0) null else v;
    }

    pub fn int(f: Form, k: []const u8) ?i64 {
        const v = f.val(k) orelse return null;
        return std.fmt.parseInt(i64, v, 10) catch null;
    }
};

/// The value of cookie `name` from a Cookie header ("a=b; c=d").
pub fn cookie(header: ?[]const u8, name: []const u8) ?[]const u8 {
    const h = header orelse return null;
    var it = std.mem.splitScalar(u8, h, ';');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
        if (std.mem.eql(u8, p[0..eq], name)) return p[eq + 1 ..];
    }
    return null;
}

pub const Nav = enum { none, atoms, review, queue, health, seats };

pub const Shell = struct {
    title: []const u8,
    nav: Nav = .none,
    seat: ?[]const u8 = null,
    csrf: ?[]const u8 = null,
    nonce: []const u8,
};

/// Opens the page (doctype … <main>). Every page closes with `end`.
pub fn begin(a: std.mem.Allocator, b: *Buf, s: Shell) !void {
    try b.appendSlice(a, "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
        "<meta name=\"color-scheme\" content=\"light dark\"><meta name=\"referrer\" content=\"same-origin\"><title>");
    try esc(a, b, s.title);
    try b.appendSlice(a, " · zigmem</title><style nonce=\"");
    try b.appendSlice(a, s.nonce);
    try b.appendSlice(a, "\">" ++ css ++ "</style></head><body><header class=\"top\"><a class=\"brand\" href=\"/panel/atoms\">zigmem</a>");
    if (s.seat) |seat| {
        try b.appendSlice(a, "<nav>");
        const items = [_]struct { n: Nav, href: []const u8, label: []const u8 }{
            .{ .n = .atoms, .href = "/panel/atoms", .label = "Memories" },
            .{ .n = .review, .href = "/panel/atoms?status=pending_review", .label = "Review" },
            .{ .n = .queue, .href = "/panel/queue", .label = "Queue" },
            .{ .n = .health, .href = "/panel/health", .label = "Health" },
            .{ .n = .seats, .href = "/panel/seats", .label = "Seats" },
        };
        for (items) |it| {
            try b.print(a, "<a href=\"{s}\"{s}>{s}</a>", .{ it.href, if (it.n == s.nav) " aria-current=\"page\"" else "", it.label });
        }
        try b.appendSlice(a, "</nav><form class=\"who\" method=\"post\" action=\"/panel/logout\"><span>");
        try esc(a, b, seat);
        try b.appendSlice(a, "</span>");
        try csrfField(a, b, s.csrf orelse "");
        try b.appendSlice(a, "<button type=\"submit\" class=\"link\">Log out</button></form>");
    }
    try b.appendSlice(a, "</header><main>");
}

pub fn end(a: std.mem.Allocator, b: *Buf, nonce: []const u8) !void {
    try b.appendSlice(a, "</main><script nonce=\"");
    try b.appendSlice(a, nonce);
    try b.appendSlice(a, "\">" ++ js ++ "</script></body></html>");
}

pub fn csrfField(a: std.mem.Allocator, b: *Buf, csrf: []const u8) !void {
    try b.appendSlice(a, "<input type=\"hidden\" name=\"csrf\" value=\"");
    try esc(a, b, csrf);
    try b.appendSlice(a, "\">");
}

/// Milliseconds since the epoch → "YYYY-MM-DD HH:MM UTC".
pub fn when(a: std.mem.Allocator, b: *Buf, ms: i64) !void {
    if (ms <= 0) return b.appendSlice(a, "—");
    const secs: u64 = @intCast(@divTrunc(ms, 1000));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    try b.print(a, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{ day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour() });
}

test "esc neutralises markup, quotes, controls and bad UTF-8" {
    const a = std.testing.allocator;
    var b: Buf = .empty;
    defer b.deinit(a);
    try esc(a, &b, "<script>alert('x')</script>\"`&\x01\xff é");
    try std.testing.expectEqualStrings("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;&quot;&#96;&amp;\u{FFFD} é", b.items);
}

test "form parsing and url coding round trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Form.parse(a, "q=a+b%3Cc&id=7&q=second&empty=&flag");
    try std.testing.expectEqualStrings("a b<c", f.get("q").?);
    try std.testing.expectEqual(@as(?i64, 7), f.int("id"));
    try std.testing.expect(f.val("empty") == null);
    try std.testing.expectEqualStrings("", f.get("flag").?);
    try std.testing.expectError(error.BadForm, Form.parse(a, "x=%zz"));
    try std.testing.expectError(error.BadForm, Form.parse(a, "x=%4"));
    var b: Buf = .empty;
    try urlEnc(a, &b, "a b\"<>&é");
    try std.testing.expectEqualStrings("a%20b%22%3C%3E%26%C3%A9", b.items);
    try std.testing.expectEqualStrings("v1", cookie("x=1; zm_sess=v1;y=2", "zm_sess").?);
    try std.testing.expect(cookie("zm_sessx=1", "zm_sess") == null);
}
