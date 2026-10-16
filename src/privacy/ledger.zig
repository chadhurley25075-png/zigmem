//! The window firewall: ports of ledger_scrub, ledger_reject, ledger_lines, weekday_check, resolve_relative and their helpers
//! (money_tokens_k, _asserted_tokens, _dead_core/_dead_kw_hit/_dead_ctx_ok/_dead_hit). Annotates, never deletes. Fail-open.
//! Python exceptions are modelled as error.Py and caught exactly where the Python catches them.
const std = @import("std");
const g = @import("gates.zig");
const re = g.re;
const Text = re.Text;
const Value = std.json.Value;
const U = g.U;

pub const Py = error{Py};
const cal = @import("calendar.zig");
pub const Date = cal.Date;
pub const weekdayCheck = cal.weekdayCheck;
pub const resolveRelative = cal.resolveRelative;

// ---------------------------------------------------------------- Python value semantics over std.json.Value

fn truthy(v: Value) bool {
    return switch (v) {
        .null => false,
        .bool => |b| b,
        .integer => |i| i != 0,
        .float => |f| f != 0,
        .number_string => true,
        .string => |s| s.len > 0,
        .array => |a| a.items.len > 0,
        .object => |o| o.count() > 0,
    };
}

fn getKey(f: Value, key: []const u8) Py!?Value {
    if (f != .object) return error.Py;
    return f.object.get(key);
}

/// str(v)
pub fn pyStr(a: std.mem.Allocator, v: ?Value) ![]const u8 {
    const x = v orelse return "None";
    return switch (x) {
        .null => "None",
        .bool => |b| if (b) "True" else "False",
        .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
        .number_string => |s| s,
        .string => |s| s,
        else => error.Py,
    };
}

/// Iterate like Python `for x in v` (list items, str characters, dict keys); anything else raises.
fn iterItems(a: std.mem.Allocator, v: Value) ![]Value {
    switch (v) {
        .array => |arr| return arr.items,
        .string => |s| {
            const cps = try g.decode(a, s);
            const out = try a.alloc(Value, cps.len);
            for (cps, 0..) |c, i| out[i] = .{ .string = try g.encode(a, &.{c}) };
            return out;
        },
        .object => |o| {
            const out = try a.alloc(Value, o.count());
            for (o.keys(), 0..) |k, i| out[i] = .{ .string = k };
            return out;
        },
        else => return error.Py,
    }
}

/// `x or []` then iterate.
fn iterOrEmpty(a: std.mem.Allocator, v: ?Value) ![]Value {
    const x = v orelse return &.{};
    if (!truthy(x)) return &.{};
    return iterItems(a, x);
}

/// set(v) for the dead_money_k intersection: numbers (bools count as 0/1); str/None never equal a number; list/dict raise.
fn moneySet(a: std.mem.Allocator, v: ?Value) ![]f64 {
    var out: std.ArrayList(f64) = .empty;
    for (try iterOrEmpty(a, v)) |x| switch (x) {
        .integer => |i| try out.append(a, @floatFromInt(i)),
        .float => |f| try out.append(a, f),
        .bool => |b| try out.append(a, if (b) 1 else 0),
        .array, .object => return error.Py,
        else => {},
    };
    return out.items;
}

fn intersects(xs: []const f64, ys: []const f64) bool {
    for (xs) |x| for (ys) |y| if (x == y) return true;
    return false;
}

fn lowerStr(a: std.mem.Allocator, v: Value) ![]u21 {
    if (v != .string) return error.Py;
    return g.lowerCps(a, try g.decode(a, v.string));
}

// ---------------------------------------------------------------- the ledger

pub const Fact = struct {
    v: Value,
    core: []const U,
    core_err: bool = false,
    /// Memo (integration, performance only): what deadHit derived from `v` on EVERY line — `set(dead_money_k)` and the
    /// lowered `dead_keywords` — computed once at parse with the same exception semantics (see deadKwHit/deadHit).
    money: Memo([]f64) = .err,
    dk: DkMemo = .err,
    /// Prefilter memo (see cannotHit).
    pre: Pre = .{ .never = false },
};

/// What can make this fact stamp an ASCII line: `never` = deadHit always raises first (bad dead_money_k or
/// dead_keywords → the fact is skipped on every line); `dk` = the lowered dead keywords that are pure ASCII (one with
/// a non-ASCII char can never sit inside an ASCII line); `core` = the core words when the core path is reachable and
/// all ASCII (null = that path can never succeed on an ASCII line).
const Pre = struct { never: bool, dk: []const []const u8 = &.{}, core: ?[]const []const u8 = null };

fn asciiOf(a: std.mem.Allocator, cps: []const u21) !?[]const u8 {
    const out = try a.alloc(u8, cps.len);
    for (cps, out) |c, *o| {
        if (c >= 128) return null;
        o.* = @intCast(c);
    }
    return out;
}

fn computePre(a: std.mem.Allocator, f: Fact) !Pre {
    if (f.money == .err) return .{ .never = true };
    var dk: std.ArrayList([]const u8) = .empty;
    var core_reachable = !f.core_err and f.core.len > 0;
    switch (f.dk) {
        .err => return .{ .never = true },
        .absent => {},
        .items => |it| {
            for (it.low) |k| if (try asciiOf(a, k)) |x| try dk.append(a, x);
            if (it.fail) core_reachable = false; // the raise after the items comes before the core check
        },
    }
    var core: ?[]const []const u8 = null;
    if (core_reachable) {
        var cs: std.ArrayList([]const u8) = .empty;
        var ok = true;
        for (f.core) |c| {
            const x = (try asciiOf(a, c)) orelse {
                ok = false;
                break;
            };
            try cs.append(a, x);
        }
        if (ok) core = cs.items;
    }
    return .{ .never = false, .dk = dk.items, .core = core };
}

/// Sound prefilter for scrubInner (integration, performance): true only when NO fact can stamp `line`. A stamp needs
/// a money hit (the money pattern needs a literal '$') or a dead keyword inside the line's asserted words (every
/// space-free piece of the keyword then sits inside one clause, i.e. inside lower(line)) or every core word in its
/// keyword set (each then a substring of lower(line)). ASCII lines only; anything else takes the full path.
fn cannotHit(gs: *g.Gates, a: std.mem.Allocator, line: []const u8) bool {
    for (line) |b| if (b >= 128 or b == '$') return false;
    const low = std.ascii.allocLowerString(a, line) catch return false;
    for (gs.led.facts) |f| {
        if (f.pre.never) continue;
        for (f.pre.dk) |k| {
            var all = true;
            var it = std.mem.splitScalar(u8, k, ' ');
            while (it.next()) |piece| if (std.mem.indexOf(u8, low, piece) == null) {
                all = false;
                break;
            };
            if (all) return false;
        }
        if (f.pre.core) |core| {
            var all = true;
            for (core) |c| if (std.mem.indexOf(u8, low, c) == null) {
                all = false;
                break;
            };
            if (all) return false;
        }
    }
    return true;
}

fn Memo(comptime T: type) type {
    return union(enum) { ok: T, err };
}

/// `.absent` = no dead_keywords key; `.items` = lowered keywords in order, up to the first one whose lowering raises
/// (`fail` = that raise happens after them); `.err` = reading/iterating the key itself raises.
const DkMemo = union(enum) { absent, items: struct { low: []const []u21, fail: bool }, err };

fn memoMoney(a: std.mem.Allocator, f: Value) Memo([]f64) {
    const v = getKey(f, "dead_money_k") catch return .err;
    return .{ .ok = moneySet(a, v) catch return .err };
}

fn memoDk(a: std.mem.Allocator, f: Value) DkMemo {
    const dk = (getKey(f, "dead_keywords") catch return .err) orelse return .absent;
    const items = iterItems(a, dk) catch return .err;
    var low: std.ArrayList([]u21) = .empty;
    for (items) |k| {
        const l = lowerStr(a, k) catch return .{ .items = .{ .low = low.items, .fail = true } };
        low.append(a, l) catch return .err;
    }
    return .{ .items = .{ .low = low.items, .fail = false } };
}

pub const Ledger = struct {
    arena: std.heap.ArenaAllocator,
    facts: []Fact,
    rx: *const g.Rx,

    /// LEDGER = json.load(f).get("facts", []); any failure → [] (the Python fails open to an empty ledger).
    pub fn parse(gpa: std.mem.Allocator, rx: *const g.Rx, json: ?[]const u8) !Ledger {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var facts: std.ArrayList(Fact) = .empty;
        if (json) |j| blk: {
            const root = std.json.parseFromSliceLeaky(Value, a, j, .{}) catch break :blk;
            if (root != .object) break :blk;
            const fs = root.object.get("facts") orelse break :blk;
            if (fs != .array) break :blk;
            for (fs.array.items) |f| {
                // `ks = tuple(...)` and the cache-key hash sit OUTSIDE the Python try: their failure raises in the caller.
                const err = coreKeyFails(a, f);
                var fact: Fact = .{ .v = f, .core = if (err) &.{} else (deadCore(a, rx, f) catch &.{}), .core_err = err, .money = memoMoney(a, f), .dk = memoDk(a, f) };
                fact.pre = try computePre(a, fact);
                try facts.append(a, fact);
            }
        }
        return .{ .arena = arena, .facts = facts.items, .rx = rx };
    }

    pub fn deinit(l: *Ledger) void {
        l.arena.deinit();
    }

    pub fn empty(l: *const Ledger) bool {
        return l.facts.len == 0;
    }
};

fn stripChars(s: U, chars: []const u21) U {
    var a: usize = 0;
    var b = s.len;
    while (a < b and std.mem.indexOfScalar(u21, chars, s[a]) != null) a += 1;
    while (b > a and std.mem.indexOfScalar(u21, chars, s[b - 1]) != null) b -= 1;
    return s[a..b];
}

const strip_punct = [_]u21{ '.', ',', '\'' };

/// {t.strip(".,'") for t in _KW_TOK.findall(s)} as a list of distinct strings.
fn kwSet(a: std.mem.Allocator, rx: *const g.Rx, s: U) ![]U {
    const t: Text = .{ .cps = @constCast(s), .off = try a.alloc(usize, s.len + 1), .bytes = "" };
    @memset(t.off, 0);
    var out: std.ArrayList(U) = .empty;
    for (try rx.kw_tok.findAll(a, t)) |m| {
        const w = stripChars(s[m.start()..m.end()], &strip_punct);
        if (!containsStr(out.items, w)) try out.append(a, w);
    }
    return out.items;
}

fn containsStr(set: []const U, w: U) bool {
    for (set) |x| if (std.mem.eql(u21, x, w)) return true;
    return false;
}

fn coreKeyFails(a: std.mem.Allocator, f: Value) bool {
    if (f != .object) return true;
    const ks = iterOrEmpty(a, f.object.get("dead_keywords")) catch return true;
    for (ks) |k| if (k == .array or k == .object) return true;
    if (f.object.get("key")) |k| if (k == .array or k == .object) return true;
    return false;
}

/// _dead_core(f): explicit dead_core, else the >=3-digit numbers every dead_keywords phrasing shares. Never raises (→ empty).
fn deadCore(a: std.mem.Allocator, rx: *const g.Rx, f: Value) ![]const U {
    if (f != .object) return error.Py; // ks = tuple(f.get(...)) raises outside the try → caller maps to empty
    const ks = try iterOrEmpty(a, f.object.get("dead_keywords"));
    var core: std.ArrayList(U) = .empty;
    const dc = f.object.get("dead_core");
    if (dc != null and truthy(dc.?)) {
        for (try iterItems(a, dc.?)) |t| {
            const s = try g.decode(a, try pyStr(a, t));
            if (g.strip(try g.encode(a, s)).len == 0) continue;
            const l = try g.lowerCps(a, s);
            const st = try g.decode(a, g.strip(try g.encode(a, l)));
            if (!containsStr(core.items, st)) try core.append(a, st);
        }
        return core.items;
    }
    if (ks.len < 2) return &.{};
    var sets: std.ArrayList([]U) = .empty;
    for (ks) |k| {
        const words = try kwSet(a, rx, try lowerStr(a, k));
        var kept: std.ArrayList(U) = .empty;
        for (words) |w| if (!isStop(w)) try kept.append(a, w);
        try sets.append(a, kept.items);
    }
    for (sets.items[0]) |w| {
        var all = true;
        for (sets.items[1..]) |s2| if (!containsStr(s2, w)) {
            all = false;
            break;
        };
        if (!all or w.len < 3) continue;
        for (w) |c| if (c < '0' or c > '9') {
            all = false;
            break;
        };
        if (all) try core.append(a, w);
    }
    return core.items;
}

fn isStop(w: U) bool {
    for (g.pat.kw_stop) |s| {
        if (s.len != w.len) continue;
        var eq = true;
        for (s, w) |b, c| if (b != c) {
            eq = false;
            break;
        };
        if (eq) return true;
    }
    return false;
}

// ---------------------------------------------------------------- money

fn roundHalfEven(x: f64) f64 {
    var y = @round(x);
    if (@abs(x - y) == 0.5) y = 2.0 * @round(x / 2.0);
    return y;
}

/// money_tokens_k(text): every money mention as round($K).
pub fn moneyTokens(a: std.mem.Allocator, rx: *const g.Rx, t: Text) ![]f64 {
    var out: std.ArrayList(f64) = .empty;
    for (try rx.money.findAll(a, t)) |m| {
        var tok: std.ArrayList(u21) = .empty;
        for (t.cps[m.start()..m.end()]) |c| {
            if (c == '$' or c == ',' or c == ' ') continue;
            const l = re.lowerFull(c);
            try tok.append(a, l[0]);
            if (l[1] != 0) try tok.append(a, l[1]);
        }
        var s = tok.items;
        var mult: f64 = 1.0;
        const sufs = [_]struct { s: []const u8, m: f64 }{ .{ .s = "million", .m = 1e6 }, .{ .s = "thousand", .m = 1e3 }, .{ .s = "m", .m = 1e6 }, .{ .s = "k", .m = 1e3 }, .{ .s = "b", .m = 1e9 } };
        for (sufs) |sf| {
            if (s.len >= sf.s.len) {
                var ok = true;
                for (sf.s, s[s.len - sf.s.len ..]) |b, c| if (b != c) {
                    ok = false;
                    break;
                };
                if (ok) {
                    s = s[0 .. s.len - sf.s.len];
                    mult = sf.m;
                    break;
                }
            }
        }
        // float(): Unicode decimals → ASCII, whitespace → ' ', strip, parse; ValueError → token skipped.
        var buf: std.ArrayList(u8) = .empty;
        var bad = false;
        for (s) |c| {
            if (re.digitValue(c)) |dv| try buf.append(a, '0' + dv) else if (re.isSpace(c)) try buf.append(a, ' ') else if (c < 128) try buf.append(a, @intCast(c)) else {
                bad = true;
                break;
            }
        }
        if (bad) continue;
        const num = std.mem.trim(u8, buf.items, " ");
        if (num.len == 0 or std.mem.indexOfAny(u8, num, " ") != null) continue;
        for (num) |b| if (!(std.ascii.isDigit(b) or b == '.')) {
            bad = true;
            break;
        };
        if (bad) continue;
        const x = std.fmt.parseFloat(f64, num) catch continue;
        const v = roundHalfEven(x * mult / 1000.0);
        if (!std.math.isFinite(v)) continue; // round(inf) raises OverflowError → skipped
        if (std.mem.indexOfScalar(f64, out.items, v) == null) try out.append(a, v);
    }
    return out.items;
}

const Asserted = struct { money: []f64, words: []u21 };

/// _asserted_tokens(text): money + lowered words of clauses with no supersession cue.
fn asserted(a: std.mem.Allocator, rx: *const g.Rx, t: Text) !Asserted {
    return assertedInner(a, rx, t) catch |e| switch (e) {
        error.OutOfMemory => e,
        else => .{ .money = try moneyTokens(a, rx, t), .words = try g.lowerCps(a, t.cps) },
    };
}

fn assertedInner(a: std.mem.Allocator, rx: *const g.Rx, t: Text) !Asserted {
    var money: std.ArrayList(f64) = .empty;
    var words: std.ArrayList(u21) = .empty;
    var prev: usize = 0;
    const ms = try rx.clause.findAll(a, t);
    var k: usize = 0;
    while (k <= ms.len) : (k += 1) {
        const end = if (k < ms.len) ms[k].start() else t.cps.len;
        const clause = t.sub(prev, end);
        if (k < ms.len) prev = ms[k].end();
        if (clause.cps.len == 0) continue;
        if ((try rx.supersession_cue.search(clause, 0)) != null) continue;
        for (try moneyTokens(a, rx, clause)) |v| if (std.mem.indexOfScalar(f64, money.items, v) == null) try money.append(a, v);
        try words.append(a, ' ');
        try words.appendSlice(a, try g.lowerCps(a, clause.cps));
    }
    return .{ .money = money.items, .words = words.items };
}

/// `ws`: the line's keyword set, computed at most once per line and shared by every fact (memo, integration).
fn deadKwHit(a: std.mem.Allocator, rx: *const g.Rx, f: Fact, words: U, line: U, ws: *?[]U) !bool {
    // == `for k in (fact.get("dead_keywords") or ...): if k.lower() in words: return True`, from the parse-time memo
    switch (f.dk) {
        .err => return error.Py,
        .absent => {},
        .items => |it| {
            for (it.low) |k| if (g.findCp(words, k, 0) != null) return true;
            if (it.fail) return error.Py;
        },
    }
    if (f.core_err) return error.Py;
    if (f.core.len == 0) return false;
    const wset = if (ws.*) |x| x else blk: {
        const x = try kwSet(a, rx, words);
        ws.* = x;
        break :blk x;
    };
    for (f.core) |c| if (!containsStr(wset, c)) return false;
    const ctx = try g.lowerCps(a, if (line.len > 0) line else words);
    // qk is a full list comprehension in the Python: every element is lowered (and may raise) before any() runs.
    var qk: std.ArrayList([]u21) = .empty;
    for (try iterOrEmpty(a, try getKey(f.v, "query_keywords"))) |q| {
        const ql = try lowerStr(a, q);
        if (!containsStr(f.core, ql)) try qk.append(a, ql);
    }
    if (qk.items.len == 0) return true;
    for (qk.items) |q| if (g.findCp(ctx, q, 0) != null) return true;
    return false;
}

fn pyInt(v: ?Value) !i64 {
    const x = v orelse return 40;
    return switch (x) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f)) @intFromFloat(@trunc(f)) else error.Py,
        .bool => |b| @intFromBool(b),
        .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t\n\r"), 10) catch error.Py,
        else => error.Py,
    };
}

fn deadCtxOk(a: std.mem.Allocator, rx: *const g.Rx, f: Fact, line: Text, money_hit: bool) !bool {
    const dc = (try getKey(f.v, "dead_context")) orelse return true;
    if (!truthy(dc)) return true;
    if (dc != .object) return error.Py;
    var words: std.ArrayList([]u21) = .empty;
    for (try iterOrEmpty(a, dc.object.get("words"))) |w| {
        const s = try pyStr(a, w);
        if (g.strip(s).len == 0) continue;
        try words.append(a, try g.lowerCps(a, try g.decode(a, s)));
    }
    if (words.items.len == 0) return true;
    const win = try pyInt(dc.object.get("window"));
    const low = try g.lowerCps(a, line.cps);
    var spans: std.ArrayList([2]i64) = .empty;
    if (money_hit) {
        const dead = try moneySet(a, try getKey(f.v, "dead_money_k"));
        for (try rx.money.findAll(a, line)) |m| {
            const toks = try moneyTokens(a, rx, line.sub(m.start(), m.end()));
            if (intersects(toks, dead)) try spans.append(a, .{ @intCast(m.start()), @intCast(m.end()) });
        }
    }
    const dk = (try getKey(f.v, "dead_keywords")) orelse Value{ .null = {} };
    if (truthy(dk) and dk != .array) return error.Py; // str/dict + list raises
    var keys: std.ArrayList([]u21) = .empty;
    for (try iterOrEmpty(a, dk)) |k| try keys.append(a, try g.lowerCps(a, try g.decode(a, try pyStr(a, k))));
    if (f.core_err) return error.Py;
    for (f.core) |c| try keys.append(a, try g.lowerCps(a, c));
    for (keys.items) |k| {
        if (k.len == 0) continue;
        var i = g.findCp(low, k, 0);
        while (i) |p| : (i = g.findCp(low, k, p + 1)) try spans.append(a, .{ @intCast(p), @intCast(p + k.len) });
    }
    if (spans.items.len == 0) {
        for (words.items) |w| if (g.findCp(low, w, 0) != null) return true;
        return false;
    }
    for (spans.items) |sp| {
        const seg = g.pySlice(low, @max(0, sp[0] - win), sp[1] + win);
        for (words.items) |w| if (g.findCp(seg, w, 0) != null) return true;
    }
    return false;
}

fn deadHit(a: std.mem.Allocator, rx: *const g.Rx, f: Fact, money: []const f64, words: U, line: Text, ws: *?[]U) !bool {
    const mh = intersects(money, switch (f.money) {
        .ok => |m| m,
        .err => return error.Py,
    });
    if (!mh and !try deadKwHit(a, rx, f, words, line.cps, ws)) return false;
    return deadCtxOk(a, rx, f, line, mh);
}

/// ledger_reject(text, created) → true = "superseded".
pub fn reject(gs: *g.Gates, gpa: std.mem.Allocator, text: []const u8, created: ?[]const u8) !bool {
    if (gs.led.empty() or text.len == 0) return false;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    return rejectInner(a, gs, text, created) catch |e| switch (e) {
        error.OutOfMemory => e,
        else => false,
    };
}

fn rejectInner(a: std.mem.Allocator, gs: *g.Gates, text: []const u8, created: ?[]const u8) !bool {
    const cfull = try g.decode(a, created orelse "");
    const c = cfull[0..@min(10, cfull.len)];
    const t = try Text.init(a, text);
    const as = try asserted(a, &gs.rx, t);
    var ws: ?[]U = null;
    for (gs.led.facts) |f| {
        const ao = try getKey(f.v, "as_of");
        if (c.len > 0 and ao != null and truthy(ao.?)) {
            if (ao.? != .string) return error.Py;
            if (std.mem.order(u21, c, try g.decode(a, ao.?.string)) == .gt) continue;
        }
        if (deadHit(a, &gs.rx, f, as.money, as.words, t, &ws) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => false,
        }) return true;
    }
    return false;
}

/// ledger_scrub(text): calendar check + relative dates + the dead-value stamp. Returns an owned copy.
pub fn scrub(gs: *g.Gates, gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var cur = try weekdayCheck(gs, a, text);
    cur = try resolveRelative(gs, a, cur);
    if (gs.led.empty() or cur.len == 0) return gpa.dupe(u8, cur);
    const out = scrubInner(gs, a, cur) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => cur,
    };
    return gpa.dupe(u8, out);
}

fn scrubInner(gs: *g.Gates, a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(a, '\n');
        first = false;
        try out.appendSlice(a, line);
        if (g.strip(line).len == 0 or std.mem.indexOf(u8, line, "[LEDGER") != null) continue;
        if (cannotHit(gs, a, line)) continue; // no fact can stamp this line (sound ASCII prefilter, see below)
        const t = try Text.init(a, line);
        const as = try asserted(a, &gs.rx, t);
        var ws: ?[]U = null;
        for (gs.led.facts) |f| {
            const hit = deadHit(a, &gs.rx, f, as.money, as.words, t, &ws) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => continue,
            };
            if (!hit) continue;
            const cur = (try getKey(f.v, "current")) orelse Value{ .string = "" };
            const cur_s = switch (cur) {
                .string => |s| blk: {
                    const cps = try g.decode(a, s);
                    break :blk try g.encode(a, cps[0..@min(110, cps.len)]);
                },
                else => return error.Py,
            };
            try out.print(a, "  ⚠[LEDGER {s}: superseded — {s} = {s}]", .{ try pyStr(a, try getKey(f.v, "as_of")), try pyStr(a, try getKey(f.v, "label")), cur_s });
            break;
        }
    }
    return out.items;
}

/// ledger_lines(query): "- [LEDGER · as_of] label = current" for facts whose query_keywords hit the query (whole word, plurals ok).
pub fn lines(gs: *g.Gates, gpa: std.mem.Allocator, query: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    const q = try g.lowerBytes(a, query);
    const qt = try Text.init(a, q);
    for (gs.led.facts) |f| {
        const hit = factHits(a, f, qt) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => break, // the Python wraps the whole loop: an exception stops it, lines so far are kept
        };
        if (!hit) continue;
        try out.print(a, "- [LEDGER · {s}] {s} = {s}", .{ try pyStr(a, try getKey(f.v, "as_of")), try pyStr(a, try getKey(f.v, "label")), try pyStr(a, try getKey(f.v, "current")) });
        const h = try getKey(f.v, "history");
        if (h != null and truthy(h.?)) try out.print(a, "  ⟵ prior: {s}", .{try pyStr(a, h)});
        const rb = try getKey(f.v, "review_by");
        if (rb != null and truthy(rb.?)) {
            var b: [10]u8 = undefined;
            const rbs = try pyStr(a, rb);
            if (std.mem.order(u8, gs.today.iso(&b), rbs) == .gt) try out.print(a, "  ⚠ REVIEW OVERDUE (due {s}) — confirm with Alex/Morgan before relying on it", .{rbs});
        }
        try out.append(a, '\n');
    }
    return gpa.dupe(u8, out.items);
}

fn factHits(a: std.mem.Allocator, f: Fact, q: Text) !bool {
    const qk = (try getKey(f.v, "query_keywords")) orelse return false;
    for (try iterItems(a, qk)) |k| {
        const ks = if (!truthy(k)) "" else switch (k) {
            .string => |s| s,
            else => return error.Py,
        };
        const kl = g.strip(try g.lowerBytes(a, ks));
        if (kl.len == 0) continue;
        var pb: std.ArrayList(u8) = .empty;
        try pb.appendSlice(a, "(?<![a-z0-9])");
        var vi = (try std.unicode.Utf8View.init(kl)).iterator();
        while (vi.nextCodepointSlice()) |cs| {
            if (cs.len == 1 and !std.ascii.isAlphanumeric(cs[0]) and cs[0] != '_') try pb.append(a, '\\');
            try pb.appendSlice(a, cs);
        }
        try pb.appendSlice(a, "(?:s|es|'s)?(?![a-z0-9])");
        var rx = try re.Regex.compile(a, pb.items, .{});
        defer rx.deinit();
        if ((try rx.search(q, 0)) != null) return true;
    }
    return false;
}
