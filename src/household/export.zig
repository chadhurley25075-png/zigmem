//! zigmem-hh-fixture (integration test tool, never part of `zigmem`): loads the phase-5 SYNTHETIC household fixture
//! into a NEW hub database (members, seats, rows through House.write + the forced rows) and prints, as one JSON
//! document, everything the API-level gate needs to judge the real HTTP path independently: per-row ground truth,
//! the oracle's literal per-seat read/write table, the question set per seat. Synthetic only.
const std = @import("std");
const store = @import("store");
const House = @import("house.zig").House;
const fixture = @import("fixture.zig");
const oracle = @import("oracle.zig");

fn jstr(a: std.mem.Allocator, b: *std.ArrayList(u8), s: []const u8) !void {
    try b.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try b.appendSlice(a, "\\\""),
        '\\' => try b.appendSlice(a, "\\\\"),
        0...0x1f => try b.print(a, "\\u{x:0>4}", .{c}),
        else => try b.append(a, c),
    };
    try b.append(a, '"');
}

fn jopt(a: std.mem.Allocator, b: *std.ArrayList(u8), s: ?[]const u8) !void {
    if (s) |x| try jstr(a, b, x) else try b.appendSlice(a, "null");
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3 or !std.mem.eql(u8, args[1], "--db")) {
        std.debug.print("usage: zigmem-hh-fixture --db NEW_FILE (synthetic, throwaway)\n", .{});
        std.process.exit(2);
    }
    var st = try store.Store.open(a, init.io, try a.dupeSentinel(u8, args[2], 0), .{});
    defer st.close();
    const h = try House.init(&st);
    const truths = try fixture.load(a, h);
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, "{\"truths\":[");
    for (truths, 0..) |t, i| {
        if (i > 0) try b.append(a, ',');
        try b.print(a, "{{\"id\":{d},\"scope\":", .{t.id});
        try jstr(a, &b, t.scope);
        try b.appendSlice(a, ",\"subject\":");
        try jstr(a, &b, t.subject);
        try b.appendSlice(a, ",\"truth\":");
        try jstr(a, &b, t.truth);
        try b.print(a, ",\"med\":{},\"clean\":{},\"active\":{},\"text\":", .{ t.med, t.clean, t.active });
        try jstr(a, &b, t.text);
        try b.append(a, '}');
    }
    try b.appendSlice(a, "],\"rules\":[");
    for (oracle.rules, 0..) |r, i| {
        if (i > 0) try b.append(a, ',');
        try b.appendSlice(a, "{\"seat\":");
        try jstr(a, &b, r.seat);
        try b.appendSlice(a, ",\"member\":");
        try jopt(a, &b, r.member);
        try b.appendSlice(a, ",\"role\":");
        try jstr(a, &b, r.role);
        try b.appendSlice(a, ",\"read\":[");
        var n: usize = 0;
        for (oracle.all_scopes) |s| if (oracle.canRead(r.seat, s)) {
            if (n > 0) try b.append(a, ',');
            try jstr(a, &b, s);
            n += 1;
        };
        try b.appendSlice(a, "],\"write\":[");
        n = 0;
        for (oracle.all_scopes) |s| if (oracle.canWrite(r.seat, s)) {
            if (n > 0) try b.append(a, ',');
            try jstr(a, &b, s);
            n += 1;
        };
        try b.appendSlice(a, "],\"cross\":[");
        n = 0;
        for (oracle.all_scopes) |s| if (oracle.cross(r.seat, s)) {
            if (n > 0) try b.append(a, ',');
            try jstr(a, &b, s);
            n += 1;
        };
        try b.print(a, "],\"principal\":{},\"questions\":[", .{oracle.principal(r.seat)});
        for (try oracle.questions(a, r.seat), 0..) |q, k| {
            if (k > 0) try b.append(a, ',');
            try b.appendSlice(a, "{\"text\":");
            try jstr(a, &b, q.text);
            try b.appendSlice(a, ",\"gt\":");
            try jopt(a, &b, q.gt);
            try b.print(a, ",\"medical\":{},\"expect_forbidden\":{},\"tag\":", .{ q.medical, q.expect_forbidden });
            try jstr(a, &b, q.tag);
            try b.appendSlice(a, ",\"requested\":");
            if (q.requested) |req| {
                try b.append(a, '[');
                for (req, 0..) |s, j| {
                    if (j > 0) try b.append(a, ',');
                    try jstr(a, &b, s);
                }
                try b.append(a, ']');
            } else try b.appendSlice(a, "null");
            try b.append(a, '}');
        }
        try b.appendSlice(a, "]}");
    }
    try b.appendSlice(a, "],\"all_scopes\":[");
    for (oracle.all_scopes, 0..) |s, i| {
        if (i > 0) try b.append(a, ',');
        try jstr(a, &b, s);
    }
    try b.appendSlice(a, "],\"person_ids\":[");
    for (fixture.person_ids, 0..) |s, i| {
        if (i > 0) try b.append(a, ',');
        try jstr(a, &b, s);
    }
    try b.appendSlice(a, "]}\n");
    var off: usize = 0;
    while (off < b.items.len) {
        const n = std.c.write(1, b.items[off..].ptr, b.items.len - off);
        if (n <= 0) std.process.exit(3);
        off += @intCast(n);
    }
}
