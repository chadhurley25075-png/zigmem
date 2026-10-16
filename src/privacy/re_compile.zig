//! Compiler half of the sre-compatible engine: pattern → AST (Parser) → backtracking program (Gen). See re.zig.
const std = @import("std");
const max_groups = @import("re.zig").max_groups;


pub const Item = union(enum) { cp: u21, range: [2]u21, cat: u8 };
pub const Class = struct { items: []Item, neg: bool };
pub const AKind = enum { bol, eol, wordb, nonwordb, start, end };

pub const Node = union(enum) {
    empty,
    char: u21,
    any,
    class: usize,
    cat: []usize,
    alt: []usize,
    group: struct { cap: ?u16, body: usize },
    rep: struct { body: usize, min: u32, max: ?u32, greedy: bool },
    assert: AKind,
    look: struct { behind: bool, neg: bool, body: usize },
};

pub const Op = union(enum) {
    char: u21,
    any,
    class: usize,
    assert: AKind,
    split: [2]usize,
    jmp: usize,
    save: u16,
    look: usize,
    match,
};

pub const Look = struct { behind: bool, neg: bool, width: usize, prog: []Op };


pub const Parser = struct {
    a: std.mem.Allocator,
    s: []const u21,
    i: usize = 0,
    nodes: std.ArrayList(Node) = .empty,
    classes: std.ArrayList(Class) = .empty,
    ngroups: u16 = 1,

    fn add(p: *Parser, n: Node) !usize {
        try p.nodes.append(p.a, n);
        return p.nodes.items.len - 1;
    }

    fn peek(p: *Parser) ?u21 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    pub fn parseAlt(p: *Parser) anyerror!usize {
        var alts: std.ArrayList(usize) = .empty;
        try alts.append(p.a, try p.parseCat());
        while (p.peek() == '|') {
            p.i += 1;
            try alts.append(p.a, try p.parseCat());
        }
        if (alts.items.len == 1) return alts.items[0];
        return p.add(.{ .alt = alts.items });
    }

    fn parseCat(p: *Parser) anyerror!usize {
        var items: std.ArrayList(usize) = .empty;
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            var atom = try p.parseAtom();
            while (p.peek()) |q| {
                var min: u32 = 0;
                var max: ?u32 = null;
                if (q == '*') {
                    p.i += 1;
                } else if (q == '+') {
                    p.i += 1;
                    min = 1;
                } else if (q == '?') {
                    p.i += 1;
                    max = 1;
                } else if (q == '{') {
                    const save = p.i;
                    if (p.parseBraces()) |mm| {
                        min = mm[0].?;
                        max = mm[1];
                    } else {
                        p.i = save;
                        break;
                    }
                } else break;
                var greedy = true;
                if (p.peek() == '?') {
                    p.i += 1;
                    greedy = false;
                }
                atom = try p.add(.{ .rep = .{ .body = atom, .min = min, .max = max, .greedy = greedy } });
            }
            try items.append(p.a, atom);
        }
        if (items.items.len == 0) return p.add(.empty);
        if (items.items.len == 1) return items.items[0];
        return p.add(.{ .cat = items.items });
    }

    fn num(p: *Parser) ?u32 {
        var v: ?u32 = null;
        while (p.peek()) |c| {
            if (c < '0' or c > '9') break;
            v = (v orelse 0) * 10 + @as(u32, @intCast(c - '0'));
            p.i += 1;
        }
        return v;
    }

    /// `{m}`, `{m,}`, `{,n}`, `{m,n}`; null = not a quantifier (then `{` is a literal, as in Python).
    fn parseBraces(p: *Parser) ?[2]?u32 {
        p.i += 1;
        const lo = p.num();
        if (p.peek() == '}') {
            p.i += 1;
            const v = lo orelse return null;
            return .{ v, v };
        }
        if (p.peek() != ',') return null;
        p.i += 1;
        const hi = p.num();
        if (p.peek() != '}') return null;
        p.i += 1;
        return .{ lo orelse 0, hi };
    }

    fn escapeCp(c: u21) ?u21 {
        return switch (c) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'f' => 0x0c,
            'v' => 0x0b,
            'a' => 0x07,
            '0' => 0,
            else => if (c < 128 and std.ascii.isAlphanumeric(@intCast(c))) null else c,
        };
    }

    fn hex(p: *Parser, n: usize) !u21 {
        var v: u21 = 0;
        for (0..n) |_| {
            const c = p.peek() orelse return error.BadPattern;
            const d = std.fmt.charToDigit(@intCast(c), 16) catch return error.BadPattern;
            v = v * 16 + d;
            p.i += 1;
        }
        return v;
    }

    fn parseAtom(p: *Parser) anyerror!usize {
        const c = p.s[p.i];
        p.i += 1;
        switch (c) {
            '.' => return p.add(.any),
            '^' => return p.add(.{ .assert = .bol }),
            '$' => return p.add(.{ .assert = .eol }),
            '[' => return p.add(.{ .class = try p.parseClass() }),
            '(' => {
                if (p.peek() == '?') {
                    p.i += 1;
                    const k = p.peek() orelse return error.BadPattern;
                    p.i += 1;
                    if (k == ':') return p.groupBody(null);
                    if (k == '=' or k == '!') return p.lookBody(false, k == '!');
                    if (k == '<') {
                        const k2 = p.peek() orelse return error.BadPattern;
                        p.i += 1;
                        if (k2 == '=' or k2 == '!') return p.lookBody(true, k2 == '!');
                    }
                    return error.BadPattern;
                }
                const g = p.ngroups;
                p.ngroups += 1;
                if (p.ngroups > max_groups) return error.TooManyGroups;
                return p.groupBody(g);
            },
            '\\' => {
                const e = p.peek() orelse return error.BadPattern;
                p.i += 1;
                switch (e) {
                    'd', 'D', 'w', 'W', 's', 'S' => {
                        const items = try p.a.alloc(Item, 1);
                        items[0] = .{ .cat = @intCast(e) };
                        try p.classes.append(p.a, .{ .items = items, .neg = false });
                        return p.add(.{ .class = p.classes.items.len - 1 });
                    },
                    'b' => return p.add(.{ .assert = .wordb }),
                    'B' => return p.add(.{ .assert = .nonwordb }),
                    'A' => return p.add(.{ .assert = .start }),
                    'Z' => return p.add(.{ .assert = .end }),
                    'u' => return p.add(.{ .char = try p.hex(4) }),
                    'x' => return p.add(.{ .char = try p.hex(2) }),
                    else => return p.add(.{ .char = escapeCp(e) orelse return error.BadEscape }),
                }
            },
            else => return p.add(.{ .char = c }),
        }
    }

    fn groupBody(p: *Parser, cap: ?u16) anyerror!usize {
        const body = try p.parseAlt();
        if (p.peek() != ')') return error.BadPattern;
        p.i += 1;
        return p.add(.{ .group = .{ .cap = cap, .body = body } });
    }

    fn lookBody(p: *Parser, behind: bool, neg: bool) anyerror!usize {
        const body = try p.parseAlt();
        if (p.peek() != ')') return error.BadPattern;
        p.i += 1;
        return p.add(.{ .look = .{ .behind = behind, .neg = neg, .body = body } });
    }

    fn classCp(p: *Parser) !Item {
        const c = p.s[p.i];
        p.i += 1;
        if (c != '\\') return .{ .cp = c };
        const e = p.peek() orelse return error.BadPattern;
        p.i += 1;
        return switch (e) {
            'd', 'D', 'w', 'W', 's', 'S' => .{ .cat = @intCast(e) },
            'b' => .{ .cp = 8 },
            'u' => .{ .cp = try p.hex(4) },
            'x' => .{ .cp = try p.hex(2) },
            else => .{ .cp = escapeCp(e) orelse return error.BadEscape },
        };
    }

    fn parseClass(p: *Parser) !usize {
        var items: std.ArrayList(Item) = .empty;
        var neg = false;
        if (p.peek() == '^') {
            p.i += 1;
            neg = true;
        }
        var first = true;
        while (true) {
            const c = p.peek() orelse return error.BadPattern;
            if (c == ']' and !first) {
                p.i += 1;
                break;
            }
            first = false;
            const lo = try p.classCp();
            if (lo == .cp and p.peek() == '-' and p.i + 1 < p.s.len and p.s[p.i + 1] != ']') {
                p.i += 1;
                const hi = try p.classCp();
                if (hi != .cp) return error.BadPattern;
                try items.append(p.a, .{ .range = .{ lo.cp, hi.cp } });
            } else try items.append(p.a, lo);
        }
        try p.classes.append(p.a, .{ .items = items.items, .neg = neg });
        return p.classes.items.len - 1;
    }
};

pub const Gen = struct {
    a: std.mem.Allocator,
    p: *Parser,
    looks: std.ArrayList(Look) = .empty,

    fn nullable(g: *Gen, n: usize) bool {
        return switch (g.p.nodes.items[n]) {
            .empty, .assert, .look => true,
            .char, .any, .class => false,
            .cat => |xs| for (xs) |x| {
                if (!g.nullable(x)) break false;
            } else true,
            .alt => |xs| for (xs) |x| {
                if (g.nullable(x)) break true;
            } else false,
            .group => |gr| g.nullable(gr.body),
            .rep => |r| r.min == 0 or g.nullable(r.body),
        };
    }

    /// Fixed width in code points, or null.
    fn width(g: *Gen, n: usize) ?usize {
        return switch (g.p.nodes.items[n]) {
            .empty, .assert, .look => 0,
            .char, .any, .class => 1,
            .cat => |xs| blk: {
                var w: usize = 0;
                for (xs) |x| w += g.width(x) orelse break :blk null;
                break :blk w;
            },
            .alt => |xs| blk: {
                const w0 = g.width(xs[0]) orelse break :blk null;
                for (xs[1..]) |x| if ((g.width(x) orelse break :blk null) != w0) break :blk null;
                break :blk w0;
            },
            .group => |gr| g.width(gr.body),
            .rep => |r| if (r.max != null and r.max.? == r.min) (if (g.width(r.body)) |w| w * r.min else null) else null,
        };
    }

    pub fn emit(g: *Gen, out: *std.ArrayList(Op), n: usize) anyerror!void {
        switch (g.p.nodes.items[n]) {
            .empty => {},
            .char => |c| try out.append(g.a, .{ .char = c }),
            .any => try out.append(g.a, .any),
            .class => |ci| try out.append(g.a, .{ .class = ci }),
            .assert => |k| try out.append(g.a, .{ .assert = k }),
            .cat => |xs| for (xs) |x| try g.emit(out, x),
            .alt => |xs| {
                var jumps: std.ArrayList(usize) = .empty;
                for (xs, 0..) |x, k| {
                    if (k + 1 < xs.len) {
                        const sp = out.items.len;
                        try out.append(g.a, .{ .split = .{ sp + 1, 0 } });
                        try g.emit(out, x);
                        try jumps.append(g.a, out.items.len);
                        try out.append(g.a, .{ .jmp = 0 });
                        out.items[sp].split[1] = out.items.len;
                    } else try g.emit(out, x);
                }
                for (jumps.items) |j| out.items[j] = .{ .jmp = out.items.len };
            },
            .group => |gr| {
                if (gr.cap) |c| try out.append(g.a, .{ .save = 2 * c });
                try g.emit(out, gr.body);
                if (gr.cap) |c| try out.append(g.a, .{ .save = 2 * c + 1 });
            },
            .rep => |r| {
                for (0..r.min) |_| try g.emit(out, r.body);
                if (r.max) |mx| {
                    // (max-min) nested optionals: x? x? ... with each later copy reachable only after the previous.
                    var holes: std.ArrayList(usize) = .empty;
                    for (r.min..mx) |_| {
                        const sp = out.items.len;
                        try out.append(g.a, .{ .split = .{ 0, 0 } });
                        try holes.append(g.a, sp);
                        try g.emit(out, r.body);
                        out.items[sp].split = if (r.greedy) .{ sp + 1, 0 } else .{ 0, sp + 1 };
                    }
                    const exit = out.items.len;
                    for (holes.items) |h| {
                        if (r.greedy) out.items[h].split[1] = exit else out.items[h].split[0] = exit;
                    }
                } else {
                    if (g.nullable(r.body)) return error.NullableLoop;
                    const sp = out.items.len;
                    try out.append(g.a, .{ .split = .{ 0, 0 } });
                    try g.emit(out, r.body);
                    try out.append(g.a, .{ .jmp = sp });
                    const exit = out.items.len;
                    out.items[sp].split = if (r.greedy) .{ sp + 1, exit } else .{ exit, sp + 1 };
                }
            },
            .look => |lk| {
                var sub: std.ArrayList(Op) = .empty;
                try g.emit(&sub, lk.body);
                try sub.append(g.a, .match);
                var w: usize = 0;
                if (lk.behind) w = g.width(lk.body) orelse return error.LookbehindNotFixed;
                try g.looks.append(g.a, .{ .behind = lk.behind, .neg = lk.neg, .width = w, .prog = sub.items });
                try out.append(g.a, .{ .look = g.looks.items.len - 1 });
            },
        }
    }
};
