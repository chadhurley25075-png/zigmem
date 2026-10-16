# zigmem PHASE 1 — the store (receipts)

Worker: Claude Code seat (a Claude model) on the dev box, 2026-10-12. Scope: `src/store/`, `src/store_test.zig`, `vendor/sqlite/`,
an additive block in `build.zig`, this file. Phase-0 files (`src/proxy.zig`, `src/main.zig`, `RESULT.md`) untouched.
Test data only: every row in every test and bench is synthetic (`syn-*` subjects, generated words). No family text.

## 0. Predictions (written BEFORE any store code was compiled — 16:40)

| Gate | Prediction | Why |
|---|---|---|
| (a) kill -9 mid-write ×20 | GREEN: 20/20 `integrity_check ok`, FTS `integrity-check` ok, 0 lost committed rows. Rows from the batch in flight at the kill are absent (all-or-nothing). | WAL + `synchronous=NORMAL` only risks the last commits on **power loss**, not on process kill (the WAL is in the OS page cache). The child prints a commit id only after `COMMIT` returns. |
| (b) 100K atoms | insert ≥ 2K/s: GREEN by a wide margin (expect 30–80K/s batched in the writer thread, FTS trigger included). FTS p95 < 20 ms: GREEN (expect 1–5 ms for 2–3 term queries with `LIMIT 10`; common-term OR queries are the risk). vec top-10 p95 < 50 ms: GREEN but closest (expect 15–35 ms, single thread, 100K × 768 f32 = 307 MB scanned per query; memory bandwidth bound). | |
| (c) `<private>` 11/11 | GREEN after one RED (expect a first-run mismatch on case/space-tolerant tags or the unclosed-in-JSONL rule). | Python uses `<\s*private\s*>` IGNORECASE + non-greedy DOTALL span; must be hand-matched. |
| (d) no DELETE reachable | GREEN: 0 `DELETE FROM` in store sources + DB triggers that ABORT any DELETE on l0/atoms/audit (RED shown by trying one). | |
| FTS5 works | GREEN. | Amalgamation compiled with `-DSQLITE_ENABLE_FTS5`. |
| No network code | GREEN: 0 hits for std.Io.net / std.http / socket / connect in `src/store/`. | |
| Lines | ~1,700–2,100 vs SPEC 2,000. | |

## 1. Verdict: PHASE 1 GATE **PASS** (all four SPEC gate items, plus FTS5 and no network code)

| Gate (SPEC §6 phase 1) | Result | Receipt |
|---|---|---|
| (a) kill -9 mid-write ×20, WAL, no corruption, no lost committed rows | **PASS.** 20/20 rounds were killed mid-write (child rc −9 after 73 to 9,256 of 10,000 commits). All 20 passed `integrity_check ok` and FTS5 `integrity-check` on both indexes. Every printed commit was present: **0 missing, 0 text mismatches**. 7 rows were committed but not yet printed (the kill landed between COMMIT and print), and they are present too. atoms = l0 = 90,506, so each op's two rows always landed together. Independent cross-check with the system Python SQLite 3.45.1: `integrity_check ok`, FTS ok. | `receipts/phase1/crash/crash_20rounds.jsonl` + 20 `round*_committed.txt` |
| (a) the checker can go RED | **RED shown.** A made-up commit line gives `missing:1`, rc 1. Writing 4 KiB of garbage into page 40 of a copy gives `error: Corrupt`, rc 1. | `receipts/phase1/crash/negative_controls.txt` |
| (b) 100K atoms: insert ≥ 2K/s | **PASS.** One commit per op (the worst case): 2,664, 3,676 and 3,175 per s. Group commit with 8 submitters: 6,856, 6,358 and 7,157 per s. | `receipts/phase1/perf_100k_GREEN.jsonl` (3 fresh runs) |
| (b) FTS p95 < 20 ms | **PASS.** p95 3.26, 3.29 and 3.28 ms; p99 ≤ 4.15 ms; max ≤ 6.1 ms (1,000 queries of 2–3 terms over 1 or 2 scopes, always 10 hits). | same |
| (b) vec top-10 p95 < 50 ms | **PASS.** 768-d, 100K rows, flat SIMD scan on one thread: p95 10.82, 10.84 and 10.83 ms. Loading from SQLite takes 0.20–0.24 s. | same |
| (c) `<private>` 11/11 vs `the reference private-tag tests` | **PASS 11/11**, ported one-to-one with the names kept. **Also 63/63 parity vectors** generated from the Python reference (`tests/store/gen_private_vectors.py`), covering Unicode whitespace (`\xa0`, ` `, `\x1c-\x1f`, `\x85`), `ı`/`İ` case-folding, nested, unclosed and two-span tags, and JSONL lines. Fail-closed: if allocation fails, an error comes back and nothing is written. Canary: after a checkpoint, a stripped secret is absent from the DB file. | `receipts/phase1/unit_GREEN_*.txt`, `unit_RED_first_run.txt` |
| (d) no DELETE reachable | **PASS.** There are 0 `DELETE FROM` in the store sources (the unit test scans every file; grep receipt too). DB triggers also ABORT any DELETE on `l0`/`atoms`/`audit`, any UPDATE on `l0`/`audit`, and any UPDATE of an atom's identity or text (supersede instead). RED shown: putting one `DELETE FROM` comment into a copy of the tree fails the test. | `receipts/phase1/scans.txt`, `unit_RED_injected_delete.txt` |
| FTS5 works | **PASS.** porter + unicode61 remove_diacritics 2 (stemming test: "prefer" finds "prefers"). Search is scope-filtered, with since/until on L0. | unit tests |
| No network code in the store | **PASS at source level.** There are 0 hits for std.http / Io.net / std.net / socket / connect in `src/store/`, and sqlite3.c has 0. **Note on the binary:** `zigmem-storebench` imports `socket connect bind listen getaddrinfo`. A 3-line Zig 0.17 hello program (`std.process.Init`) imports the same five, so they come from the `std.Io.Threaded` vtable and not from store code. Phase 8's binary scan must whitelist these symbols or check where they are called from. | `receipts/phase1/scans.txt` |

Unit tests: **23/23** in Debug and ReleaseSafe (`zig build test-store [-Drelease]`).

## 2. Predictions vs results (receipt-style)

- (a) Predicted GREEN, got GREEN. The prediction that the in-flight batch would be absent held: each op is all-or-nothing, and atoms == l0 in every round.
- (b) insert: predicted 30–80K/s grouped. **Wrong: got about 6.5–7K/s.** Each op re-prepares about 4 statements and re-parses SAVEPOINT/RELEASE
  (there is no statement cache yet). Each op also runs the private strip, sha256, getrandom and an audit row, and the writer averaged about 3.3 ops per commit. That is
  still 3.2× the bar, and the single-commit worst case is 1.3–1.8×. A prepared-statement cache is the next lever, but the gate does not need it.
- (b) FTS: predicted GREEN at 1–5 ms, with common terms named as the risk. **The first run was RED: p95 26.4 ms** (`perf_100k_RED_fts_p95.json`).
  The synthetic vocabulary is Zipf-skewed (the top word is in 53% of rows), and bm25 over a 50K-row doclist costs about 25–40 ms (profiled:
  count 2.5 ms, rank 40–60 ms). The fix is a document-frequency planner (`store.ftsPlan`). Terms that appear in more than max(1000, rows/20) documents are dropped
  from the MATCH, since their IDF is about 0. Document frequency is counted *through MATCH itself*, so stemming stays consistent, and the count stops at the threshold.
  The second run had p95 3.6 ms but **p99 1.2 s, RED** (`perf_100k_RED_p99_capped_IN.jsonl`): the fallback for all-common queries used
  `rowid IN (subquery)`, and SQLite evaluated it badly. In the final version an all-common query returns the newest matches (`ORDER BY fts.rowid DESC LIMIT k`; FTS5 streams backwards):
  p99 4.1 ms, max 6.1 ms. This changes the semantics: queries made only of very common terms rank by recency, not bm25.
- (b) vec: predicted 15–35 ms, got 10.8 ms (better).
- (c) Predicted one RED among the 11, but **all 11 passed on the first compile**. The RED came from the parity vectors instead, and it exposed a
  **leak in the Python reference**. `private_line` has a fast path (`"rivate" not in line and "RIVATE" not in line` → return line), so a
  mixed-case JSONL tag (`<PrIvAtE>…</pRiVaTe>`) passes through unstripped. `strip_private` itself is fine. The Zig port strips this case, so it is
  stricter and never looser, and the test pins exactly 1 such divergence. **For Alex: the Python fast path should compare against `.lower()`.** I did not change it here because it is out of scope.
- (d) Predicted GREEN, got GREEN. Predicted 1,700–2,100 lines, got 1,985.

## 3. Line count vs SPEC estimate (2,000)

| Part | Lines |
|---|---|
| store library `src/store/{store,sqlite,schema,private,l0,atoms,scenes,vec,jobs,writer}.zig` | 1,352 |
| gate tool `src/store/bench.zig` (perf / crashwrite / verify) | 274 |
| tests `src/store_test.zig` | 359 |
| **Zig total** | **1,985 (99% of the 2,000 estimate)** |
| Python harness + vector generator (`tests/store/`) | 71 |
| `build.zig` additive block | 14 |

Every file is ≤ 600 lines and has a `//!` header.

## 4. What was built (map)

- `sqlite.zig`: a thin wrapper made with translate-c over the vendored header. It turns on extended error codes, sets a 5 s busy timeout, binds with SQLITE_STATIC, and resets and clears each statement before reuse.
- `schema.zig`: the SPEC §3.4 schema as migration v1 (`PRAGMA user_version`), with WAL and synchronous=NORMAL. FTS5 external-content tables are kept current by
  insert triggers. Also: append-only triggers, a `run_id` index (one query retires a bad batch), and a partial unique index allowing one queued job per (kind,key).
- `store.zig`: the Store plus a mandatory `Scope`. An empty scope is an error, and every read builds `scope IN (…)`. It also holds audit, meta, a savepoint helper,
  an integrity check (SQL plus both FTS indexes) and `ftsPlan`.
- `private.zig`: a byte-exact port of `strip_private`, `private_line` and `has_private`.
- `l0.zig`: append (private-stripped, sha-idempotent, with a session cursor) and scoped search with since/until.
- `atoms.zig`: insert; `supersede` (keeps the same lineage, marks the old row superseded with valid_to, never removes it, and refuses cross-subject or cross-scope merges);
  `setStatus` (allowed transitions only, audited); get, history and search.
- `scenes.zig`: scenes (≤ 15 active per scope, caps enforced in code) and persona (one per subject per scope, rev++, 2,000-character cap in code).
- `vec.zig`: unit-normalised f32 blobs with dims pinned in meta, an in-memory index, and scope-masked SIMD top-k.
- `jobs.zig`: a persistent queue (claim, finish, recover after a crash, dead after 5 tries) plus `runs` provenance.
- `writer.zig`: the single writer thread. It has a bounded queue (1,024), group-commits up to 256 ops per transaction, and gives each op its own savepoint so a failing op rolls back alone.

## 5. Not run, and why

- No x86_64 (the x86 box) build this phase. SPEC risk 3 asks for both architectures every phase, but the x86 box was not part of this assignment. Planned for next phase.
- No power-loss test, only process kill. With `synchronous=NORMAL`, a power loss can lose the last few commits but cannot corrupt the database. If Alex wants FULL mode,
  it is a one-pragma switch.
- The store is not wired into `main.zig`, which phase 0 owns. It is also not in the default `zig build test` step, because I left phase 0's line untouched.
  Run it with `zig build test-store`.
- No real data of any kind: every row is `syn-*`.
