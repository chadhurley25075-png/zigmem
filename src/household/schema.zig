//! Household tables beside the phase-1 schema (own version key in `meta`, never touches the store's user_version).
//! Append-only like the store: members and seats are revoked by timestamp, promotions decided by status, never removed.
const std = @import("std");
const store = @import("store");

pub const version = "1";

const v1 =
    \\CREATE TABLE IF NOT EXISTS hh_members(id TEXT PRIMARY KEY, display TEXT NOT NULL, aliases TEXT NOT NULL DEFAULT '',
    \\  role TEXT NOT NULL CHECK(role IN ('principal','child','guest')), relation TEXT NOT NULL DEFAULT '',
    \\  created_ms INTEGER NOT NULL, created_by TEXT NOT NULL, revoked_ms INTEGER, revoked_by TEXT);
    \\CREATE TABLE IF NOT EXISTS hh_seats(name TEXT PRIMARY KEY, member TEXT REFERENCES hh_members(id),
    \\  created_ms INTEGER NOT NULL, created_by TEXT NOT NULL, revoked_ms INTEGER, revoked_by TEXT);
    \\CREATE TABLE IF NOT EXISTS hh_tags(atom_id INTEGER PRIMARY KEY REFERENCES atoms(id), medical INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS hh_promotions(id INTEGER PRIMARY KEY, atom_id INTEGER NOT NULL REFERENCES atoms(id),
    \\  requested_by TEXT NOT NULL, requested_ms INTEGER NOT NULL,
    \\  state TEXT NOT NULL CHECK(state IN ('pending','approved','refused')), decided_by TEXT, decided_ms INTEGER,
    \\  new_atom_id INTEGER REFERENCES atoms(id));
    \\CREATE TRIGGER IF NOT EXISTS hh_members_keep BEFORE DELETE ON hh_members BEGIN SELECT RAISE(ABORT, 'members are revoked, never removed'); END;
    \\CREATE TRIGGER IF NOT EXISTS hh_seats_keep BEFORE DELETE ON hh_seats BEGIN SELECT RAISE(ABORT, 'seats are revoked, never removed'); END;
    \\CREATE TRIGGER IF NOT EXISTS hh_tags_keep BEFORE DELETE ON hh_tags BEGIN SELECT RAISE(ABORT, 'tags are append-only'); END;
    \\CREATE TRIGGER IF NOT EXISTS hh_tags_fixed BEFORE UPDATE ON hh_tags BEGIN SELECT RAISE(ABORT, 'tags are append-only'); END;
    \\CREATE TRIGGER IF NOT EXISTS hh_prom_keep BEFORE DELETE ON hh_promotions BEGIN SELECT RAISE(ABORT, 'promotions are never removed'); END;
    \\CREATE TRIGGER IF NOT EXISTS hh_members_unrevoke BEFORE UPDATE OF revoked_ms ON hh_members WHEN old.revoked_ms IS NOT NULL
    \\  BEGIN SELECT RAISE(ABORT, 'a revocation is permanent; add a new member'); END;
    \\CREATE TRIGGER IF NOT EXISTS hh_seats_unrevoke BEFORE UPDATE OF revoked_ms ON hh_seats WHEN old.revoked_ms IS NOT NULL
    \\  BEGIN SELECT RAISE(ABORT, 'a revocation is permanent; bind a new seat'); END;
    \\INSERT INTO meta(k, v) VALUES ('household_schema', '1') ON CONFLICT(k) DO NOTHING;
;

pub fn migrate(st: *store.Store) !void {
    try st.db.exec("SAVEPOINT hh_migrate");
    st.db.exec(v1) catch |e| {
        st.db.exec("ROLLBACK TO hh_migrate; RELEASE hh_migrate") catch {};
        return e;
    };
    try st.db.exec("RELEASE hh_migrate");
}
