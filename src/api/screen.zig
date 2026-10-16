//! Privacy screen for writes from UNTRUSTED seats: refuse family / medical / money text. A hand-written matcher
//! equivalent to the the handoff gateway's PRIVATE regex (a private-text word list): case-insensitive
//! whole words, `\w*` prefixes, `$<digit>`, phone numbers, e-mail addresses, `401(k)`, and `<n>k|m` near stock words.
//! It over-refuses on purpose ("pain", "er", "son"): an untrusted seat describes the work, not the people.
const std = @import("std");

/// Whole words (must end on a word boundary).
const words = [_][]const u8{
    "grandma",   "grandpa",       "nanny",      "babysitter",   "son",          "sons",          "wife",          "husband",
    "mom",         "mother",        "dad",         "father",        "kid",          "kids",          "girl",          "girls",
    "family",      "tooth",         "teeth",       "covid",         "surgery",      "lab",           "labs",          "uti",
    "pain",        "fever",         "er",          "amoxicillin",   "augmentin",    "paxlovid",      "lisinopril",    "metformin",
    "loratadine",  "atorvastatin", "omeprazole", "oxycodone", "ketorolac",      "aleve",         "ibuprofen",     "prozac",
    "portfolio",   "ledger",        "employer",        "annuity",       "insurer",          "ira",           "401k",          "the brokerage",
    "brokerage",   "the floor",     "monthly draw", "account number", "ssn",        "password",      "advisor",         "newsletter",
    "analyst",    "salary",        "asthma",      "eczema",        "adhd",         "dr",            "stock",         "stocks",
    "shares",      "roth",          "net worth",   "kidney",        "insulin",      "blood pressure", "infection",    "stone",
    "dose",        "dosage",        "cardiac",     "mortgage",      "social security",
};

/// `\b<prefix>\w*` — any word starting with these.
const prefixes = [_][]const u8{
    "morgan",     "taylor",   "jordan",    "quinn",     "rowan",     "daughter", "doctor",  "dentist", "abscess", "antibiotic",
    "surgeon",  "medic",    "diagnos", "pregnan",  "therap",   "prescri",  "pharmac", "hospital", "clinic", "etf",
    "insurance", "dyslexi", "seizure", "medication", "diabet", "bank",
};

pub const Hit = struct { at: usize, len: usize };

fn isWord(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

fn startsFold(s: []const u8, i: usize, p: []const u8) bool {
    return i + p.len <= s.len and std.ascii.eqlIgnoreCase(s[i .. i + p.len], p);
}

fn boundaryBefore(s: []const u8, i: usize) bool {
    return i == 0 or !isWord(s[i - 1]);
}

fn boundaryAt(s: []const u8, i: usize) bool {
    return i >= s.len or !isWord(s[i]);
}

fn digits(s: []const u8, i: usize, n: usize) bool {
    if (i + n > s.len) return false;
    for (s[i .. i + n]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// `\(?\b\d{3}\)?[-. ]?\d{3}[-. ]?\d{4}\b` starting at i.
fn phoneAt(s: []const u8, start: usize) ?usize {
    var i = start;
    if (i < s.len and s[i] == '(') i += 1;
    if (!boundaryBefore(s, i) or !digits(s, i, 3)) return null;
    i += 3;
    if (i < s.len and s[i] == ')') i += 1;
    if (i < s.len and (s[i] == '-' or s[i] == '.' or s[i] == ' ')) i += 1;
    if (!digits(s, i, 3)) return null;
    i += 3;
    if (i < s.len and (s[i] == '-' or s[i] == '.' or s[i] == ' ')) i += 1;
    if (!digits(s, i, 4)) return null;
    i += 4;
    return if (boundaryAt(s, i)) i - start else null;
}

fn emailCh(c: u8) bool {
    return isWord(c) or c == '.' or c == '+' or c == '-';
}

/// `[\w.+-]+@[\w-]+\.[\w.]+` with the '@' at i.
fn emailAt(s: []const u8, at: usize) ?Hit {
    if (at == 0 or !emailCh(s[at - 1])) return null;
    var l = at;
    while (l > 0 and emailCh(s[l - 1])) l -= 1;
    var j = at + 1;
    const d0 = j;
    while (j < s.len and (isWord(s[j]) or s[j] == '-')) j += 1;
    if (j == d0 or j >= s.len or s[j] != '.') return null;
    j += 1;
    const t0 = j;
    while (j < s.len and (isWord(s[j]) or s[j] == '.')) j += 1;
    if (j == t0) return null;
    return .{ .at = l, .len = j - l };
}

const near = [_][]const u8{ "stock", "share", "sell", "buy", "worth" };

/// `\b\d+(\.\d+)?\s?[km]\b(?=.{0,20}(stock|share|sell|buy|worth))` at a word start i.
fn amountAt(s: []const u8, start: usize) ?usize {
    var i = start;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == start) return null;
    if (i + 1 < s.len and s[i] == '.' and std.ascii.isDigit(s[i + 1])) {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    }
    if (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    if (i >= s.len or (std.ascii.toLower(s[i]) != 'k' and std.ascii.toLower(s[i]) != 'm')) return null;
    i += 1;
    if (!boundaryAt(s, i)) return null;
    var off: usize = 0;
    while (off <= 20 and i + off <= s.len) : (off += 1) {
        for (near) |w| if (startsFold(s, i + off, w)) return i - start;
        if (i + off < s.len and s[i + off] == '\n') break;
    }
    return null;
}

/// First private match in `s`, or null when the text is clear.
pub fn find(s: []const u8) ?Hit {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '$') {
            var j = i + 1;
            if (j < s.len and std.ascii.isWhitespace(s[j])) j += 1;
            if (j < s.len and std.ascii.isDigit(s[j])) return .{ .at = i, .len = j + 1 - i };
        }
        if (c == '@') if (emailAt(s, i)) |h| return h;
        if (startsFold(s, i, "401(k)")) return .{ .at = i, .len = 6 };
        if (c == '(' or std.ascii.isDigit(c)) if (phoneAt(s, i)) |n| return .{ .at = i, .len = n };
        if (!isWord(c) or !boundaryBefore(s, i)) continue;
        if (std.ascii.isDigit(c)) if (amountAt(s, i)) |n| return .{ .at = i, .len = n };
        for (words) |w| if (startsFold(s, i, w) and boundaryAt(s, i + w.len)) return .{ .at = i, .len = w.len };
        for (prefixes) |p| if (startsFold(s, i, p)) {
            var j = i + p.len;
            while (j < s.len and isWord(s[j])) j += 1;
            return .{ .at = i, .len = j - i };
        };
    }
    return null;
}

test "screen: family, medical and money text is caught; work text passes" {
    const hits = [_][]const u8{
        "Morgan's appointment moved", "the girls are home",           "she has a fever",       "call 202-555-0100 later",
        "mail x.y+z@ex-ample.co",   "it costs $ 40",                "sell 12k shares",       "my 401(k) balance",
        "ETF3 is up",               "diagnosed last week",          "the ER visit",          "Rowan",
        "the brokerage called",      "net worth review",             "(202) 555-0100",        "Dr. Smith",
        "grandma is visiting",       "ask my employer",
    };
    for (hits) |h| if (find(h) == null) {
        std.debug.print("missed: {s}\n", .{h});
        return error.TestUnexpectedResult;
    };
    const clear = [_][]const u8{
        "rebuild the FTS index on the dev box", "port 8470 is free",        "Alex Harper wrote the spec",  "erase the scratch dir",
        "Sam and Edith reviewed the PR",     "the Colin branch merged",
        "persona rows per subject",         "12 kilometers of cable",   "the lantern project",         "bash@ prompt",
        "stoned",                           "version 1.2.3 build 4567", "pattern matching in Zig",     "",
    };
    for (clear) |c| if (find(c)) |h| {
        std.debug.print("false hit: {s} @ {d}\n", .{ c, h.at });
        return error.TestUnexpectedResult;
    };
}
