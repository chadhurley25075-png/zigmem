//! `<private>` stripping at write time: byte-exact port of strip_private / private_line / has_private (Python reference).
const std = @import("std");

/// Replacement text, identical to the Python PRIVATE_MARK.
pub const mark = "[private — not kept]";

/// Python `\s` on str: ASCII whitespace, \x1c-\x1f, and the Unicode spaces str.isspace() accepts.
fn spaceLen(s: []const u8, i: usize) usize {
    if (i >= s.len) return 0;
    const b = s[i];
    if (b == ' ' or (b >= 0x09 and b <= 0x0d) or (b >= 0x1c and b <= 0x1f)) return 1;
    if (b < 0x80) return 0;
    const n = std.unicode.utf8ByteSequenceLength(b) catch return 0;
    if (i + n > s.len) return 0;
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return 0;
    return switch (cp) {
        0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => n,
        else => 0,
    };
}

fn skipSpace(s: []const u8, start: usize) usize {
    var i = start;
    while (true) {
        const n = spaceLen(s, i);
        if (n == 0) return i;
        i += n;
    }
}

/// Case-insensitive "private" as Python re.IGNORECASE sees it (the `i` also matches U+0130 and U+0131).
fn word(s: []const u8, start: usize) ?usize {
    var i = start;
    for ("private") |ch| {
        if (i >= s.len) return null;
        if (std.ascii.toLower(s[i]) == ch) {
            i += 1;
        } else if (ch == 'i' and i + 1 < s.len and s[i] == 0xc4 and (s[i + 1] == 0xb0 or s[i + 1] == 0xb1)) {
            i += 2;
        } else return null;
    }
    return i;
}

/// `<\s*private\s*>` starting exactly at i; returns the index after `>`.
fn openAt(s: []const u8, i: usize) ?usize {
    if (s[i] != '<') return null;
    var j = word(s, skipSpace(s, i + 1)) orelse return null;
    j = skipSpace(s, j);
    return if (j < s.len and s[j] == '>') j + 1 else null;
}

/// `<\s*/\s*private\s*>` starting exactly at i.
fn closeAt(s: []const u8, i: usize) ?usize {
    if (s[i] != '<') return null;
    var j = skipSpace(s, i + 1);
    if (j >= s.len or s[j] != '/') return null;
    j = word(s, skipSpace(s, j + 1)) orelse return null;
    j = skipSpace(s, j);
    return if (j < s.len and s[j] == '>') j + 1 else null;
}

const Span = struct { start: usize, end: usize };

fn findOpen(s: []const u8, from: usize) ?Span {
    var i = from;
    while (std.mem.indexOfScalarPos(u8, s, i, '<')) |p| : (i = p + 1) {
        if (openAt(s, p)) |e| return .{ .start = p, .end = e };
    }
    return null;
}

fn findClose(s: []const u8, from: usize) ?usize {
    var i = from;
    while (std.mem.indexOfScalarPos(u8, s, i, '<')) |p| : (i = p + 1) {
        if (closeAt(s, p)) |e| return e;
    }
    return null;
}

/// True when the text still carries an opening tag (the "door refuses private" rule). Off switch → false.
pub fn hasOpen(text: []const u8, on: bool) bool {
    return on and text.len > 0 and findOpen(text, 0) != null;
}

pub const Stripped = struct { text: []u8, changed: bool };

/// Replace every closed span with `mark`; an unclosed tag cuts the rest (mark appended), unless `drop_unclosed`,
/// in which case the result is empty (private_line semantics). Always returns an owned copy.
fn rewrite(gpa: std.mem.Allocator, s: []const u8, drop_unclosed: bool) !Stripped {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var pos: usize = 0;
    var changed = false;
    while (findOpen(s, pos)) |o| {
        changed = true;
        try out.appendSlice(gpa, s[pos..o.start]);
        if (findClose(s, o.end)) |ce| {
            try out.appendSlice(gpa, mark);
            pos = ce;
        } else {
            if (drop_unclosed) {
                out.clearRetainingCapacity();
                return .{ .text = try out.toOwnedSlice(gpa), .changed = true };
            }
            try out.appendSlice(gpa, mark);
            return .{ .text = try out.toOwnedSlice(gpa), .changed = true };
        }
    }
    try out.appendSlice(gpa, s[pos..]);
    return .{ .text = try out.toOwnedSlice(gpa), .changed = changed };
}

/// strip_private: text with every private span replaced. Errors propagate; the caller must DROP the text (fail-closed).
pub fn strip(gpa: std.mem.Allocator, text: []const u8, on: bool) !Stripped {
    if (!on or text.len == 0 or findOpen(text, 0) == null) return .{ .text = try gpa.dupe(u8, text), .changed = false };
    return rewrite(gpa, text, false);
}

/// private_line: a raw JSONL line with closed spans replaced; an unclosed tag drops the whole line ("").
pub fn line(gpa: std.mem.Allocator, raw: []const u8, on: bool) !Stripped {
    if (!on or findOpen(raw, 0) == null) return .{ .text = try gpa.dupe(u8, raw), .changed = false };
    return rewrite(gpa, raw, true);
}
