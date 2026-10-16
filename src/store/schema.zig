//! Schema (SPEC §3.4) as stepwise PRAGMA user_version migrations; DB-level guards that make rows append-only.
const std = @import("std");
const sqlite = @import("sqlite.zig");

/// Connection pragmas. WAL + synchronous=NORMAL. Promise: a committed (acked) write survives a process crash; a power loss
/// may drop the last commits, never corrupts. FULL (fsync per commit) was measured at 229-248 inserts/s, far under the
/// 2K/s bar, so NORMAL stays (receipts/fixbatch/storebench_full_vs_normal.jsonl). Writers also set a 64 MB cache; readers are query_only.
pub fn pragmas(db: sqlite.Db, writer: bool) !void {
    try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;" ++
        " PRAGMA cache_size=-65536; PRAGMA mmap_size=134217728; PRAGMA temp_store=MEMORY;");
    if (!writer) try db.exec("PRAGMA query_only=ON;");
}

/// Version 1 = the whole SPEC §3.4 schema plus append-only triggers. Never drops a table.
const v1 =
    \\CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
    \\CREATE TABLE people(id TEXT PRIMARY KEY, display TEXT NOT NULL, aliases TEXT NOT NULL DEFAULT '');
    \\CREATE TABLE seats(id TEXT PRIMARY KEY, token_sha256 BLOB UNIQUE, person_default TEXT, scopes TEXT NOT NULL,
    \\  writes INTEGER NOT NULL DEFAULT 0, created_ms INTEGER NOT NULL, revoked_ms INTEGER);
    \\CREATE TABLE sessions(id TEXT PRIMARY KEY, seat TEXT NOT NULL, session_key TEXT, started_ms INTEGER NOT NULL,
    \\  last_ms INTEGER NOT NULL, turns INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'open');
    \\CREATE TABLE frozen_blocks(session_id TEXT PRIMARY KEY, text TEXT NOT NULL, sha256 BLOB NOT NULL,
    \\  built_ms INTEGER NOT NULL, source_rev INTEGER NOT NULL, kv_prefix_key BLOB);
    \\CREATE TABLE l0(id INTEGER PRIMARY KEY, session_id TEXT NOT NULL, seat TEXT NOT NULL, scope TEXT NOT NULL,
    \\  role TEXT NOT NULL, text TEXT NOT NULL, ts_ms INTEGER NOT NULL, recorded_ms INTEGER NOT NULL,
    \\  sha256 BLOB NOT NULL UNIQUE, private_dropped INTEGER NOT NULL DEFAULT 0);
    \\CREATE VIRTUAL TABLE l0_fts USING fts5(text, content='l0', content_rowid='id',
    \\  tokenize='porter unicode61 remove_diacritics 2');
    \\CREATE TABLE atoms(id INTEGER PRIMARY KEY, lineage TEXT NOT NULL, subject TEXT NOT NULL, scope TEXT NOT NULL,
    \\  type TEXT NOT NULL, priority INTEGER NOT NULL, text TEXT NOT NULL, valid_from TEXT, valid_to TEXT,
    \\  recorded_ms INTEGER NOT NULL, superseded_by INTEGER REFERENCES atoms(id),
    \\  status TEXT NOT NULL CHECK(status IN ('active','superseded','pending_review','retired')),
    \\  src_l0 TEXT, extractor TEXT, prompt_sha BLOB, run_id TEXT, sha256 BLOB NOT NULL);
    \\CREATE VIRTUAL TABLE atoms_fts USING fts5(text, content='atoms', content_rowid='id',
    \\  tokenize='porter unicode61 remove_diacritics 2');
    \\CREATE TABLE vec(kind TEXT NOT NULL CHECK(kind IN ('l0','atom','scene')), row_id INTEGER NOT NULL,
    \\  dims INTEGER NOT NULL, emb BLOB NOT NULL, PRIMARY KEY(kind,row_id));
    \\CREATE TABLE scenes(id INTEGER PRIMARY KEY, scope TEXT NOT NULL, name TEXT NOT NULL, summary TEXT NOT NULL,
    \\  body TEXT NOT NULL, heat REAL NOT NULL DEFAULT 0, updated_ms INTEGER NOT NULL,
    \\  status TEXT NOT NULL DEFAULT 'active', UNIQUE(scope,name));
    \\CREATE TABLE persona(subject TEXT NOT NULL, scope TEXT NOT NULL, text TEXT NOT NULL, rev INTEGER NOT NULL,
    \\  built_ms INTEGER NOT NULL, PRIMARY KEY(subject,scope));
    \\CREATE TABLE audit(id INTEGER PRIMARY KEY, ts_ms INTEGER NOT NULL, seat TEXT NOT NULL, action TEXT NOT NULL,
    \\  table_name TEXT NOT NULL, row_id INTEGER, detail TEXT);
    \\CREATE TABLE runs(id TEXT PRIMARY KEY, kind TEXT NOT NULL, model TEXT, prompt_sha BLOB, started_ms INTEGER NOT NULL,
    \\  ended_ms INTEGER, in_ids TEXT, out_ids TEXT, outcome TEXT);
    \\CREATE TABLE jobs(id INTEGER PRIMARY KEY, kind TEXT NOT NULL, key TEXT NOT NULL, due_ms INTEGER NOT NULL,
    \\  tries INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'queued', last_err TEXT);
    \\CREATE INDEX l0_scope ON l0(scope);
    \\CREATE INDEX l0_session_ts ON l0(session_id, ts_ms);
    \\CREATE INDEX atoms_scope_status ON atoms(scope, status);
    \\CREATE INDEX atoms_lineage ON atoms(lineage);
    \\CREATE INDEX atoms_subject ON atoms(subject);
    \\CREATE INDEX atoms_run ON atoms(run_id);
    \\CREATE INDEX scenes_scope ON scenes(scope, status);
    \\CREATE INDEX persona_scope ON persona(scope);
    \\CREATE INDEX audit_row ON audit(table_name, row_id);
    \\CREATE INDEX jobs_due ON jobs(state, due_ms);
    \\CREATE UNIQUE INDEX jobs_one_queued ON jobs(kind, key) WHERE state = 'queued';
    \\CREATE TRIGGER l0_fts_ai AFTER INSERT ON l0 BEGIN
    \\  INSERT INTO l0_fts(rowid, text) VALUES (new.id, new.text); END;
    \\CREATE TRIGGER atoms_fts_ai AFTER INSERT ON atoms BEGIN
    \\  INSERT INTO atoms_fts(rowid, text) VALUES (new.id, new.text); END;
    \\CREATE TRIGGER l0_no_update BEFORE UPDATE ON l0 BEGIN SELECT RAISE(ABORT, 'l0 is append-only'); END;
    \\CREATE TRIGGER l0_no_remove BEFORE DELETE ON l0 BEGIN SELECT RAISE(ABORT, 'l0 is append-only'); END;
    \\CREATE TRIGGER atoms_immutable BEFORE UPDATE OF id, lineage, subject, scope, type, text, recorded_ms, sha256,
    \\  valid_from ON atoms BEGIN SELECT RAISE(ABORT, 'atom identity is immutable; supersede instead'); END;
    \\CREATE TRIGGER atoms_no_remove BEFORE DELETE ON atoms BEGIN SELECT RAISE(ABORT, 'atoms are never removed'); END;
    \\CREATE TRIGGER audit_no_update BEFORE UPDATE ON audit BEGIN SELECT RAISE(ABORT, 'audit is append-only'); END;
    \\CREATE TRIGGER audit_no_remove BEFORE DELETE ON audit BEGIN SELECT RAISE(ABORT, 'audit is append-only'); END;
    \\INSERT INTO meta(k, v) VALUES ('schema', '1');
;

const migrations = [_][:0]const u8{v1};
pub const version: i64 = migrations.len;

/// Apply every migration above the file's user_version, each in its own transaction.
pub fn migrate(db: sqlite.Db) !void {
    const have = (try db.oneInt("PRAGMA user_version", .{})) orelse 0;
    if (have > version) return error.SchemaFromTheFuture;
    var v: usize = @intCast(have);
    while (v < migrations.len) : (v += 1) {
        try db.exec("BEGIN IMMEDIATE");
        errdefer db.exec("ROLLBACK") catch {};
        try db.exec(migrations[v]);
        var buf: [48]u8 = undefined;
        const set = try std.fmt.bufPrintSentinel(&buf, "PRAGMA user_version = {d}", .{v + 1}, 0);
        try db.exec(set);
        try db.exec("COMMIT");
    }
}
