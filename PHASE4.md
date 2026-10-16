# zigmem PHASE 4 — the hub API + MCP server (receipts)

Worker: Claude Code subagent (a Claude model), 2026-10-12. Scope: `src/api/`, `src/mcp/`, `tests/phase4/`, `receipts/phase4/`,
an additive phase-4 block in `build.zig`, an additive dispatch in `src/main.zig`, this file. Phase 0–3 files untouched.
All data synthetic (`syn-*` scopes, invented people "ana"/"ben", generated words). Test ports 18150–18159, scratch `scratch/p4/`.

## 0. Predictions (written 18:21 by the file clock, BEFORE any gate run; only a smoke test of the binary had run)

| Gate item | Prediction | Why / risk |
|---|---|---|
| Auth matrix (no token, malformed, wrong, revoked, another seat's token, scope not granted, read-only write, non-admin admin route, forged `x-vendor-*` / body ids) | GREEN 100 %: 401 for every missing/bad/revoked token, 403 for every grant violation, forged identity ignored (results only from the token's scopes, audit names the real seat). Live revocation takes effect on the next request without a restart. | Seat comes only from sha256(token) → token file row; scopes are checked before any store call; the store's own `Scope` is mandatory. |
| Refuses 0.0.0.0 / LAN / other loopback / IPv6 / outside 100.64/10 | GREEN: exit 2, nothing listening, home dir not created. | `parseBind` runs before any file or socket. 100.x is accepted by the parser (unit test) but never bound live (BOARD law 4). |
| MCP from a real Claude Code client (`claude mcp add --scope local --transport http`, `claude -p`) | GREEN after 0–2 RED rounds. | Risks: Claude Code's streamable-HTTP client may want `Mcp-Session-Id`, try a GET/SSE stream, or send a protocol version I do not list. |
| Fuzz (malformed, truncated, huge, deep nesting, wrong types, bad UTF-8, header abuse, slowloris), every route + MCP | 0 crashes, server PID alive and `/health` 200 after every batch; ≥ 99 % of hostile requests get a 4xx. | ReleaseSafe panics on overflow/bounds — the fuzz is what finds them. Deep nesting: std.json's Value parser is iterative (heap, not stack), bounded by the 512 KiB body cap. |
| p95 latency of search through the API (100K synthetic atoms, 1,000 queries) | sequential p50 ≈ 2–4 ms, **p95 ≤ 10 ms**; 8 concurrent clients p95 ≤ 25 ms. | Phase-1 FTS p95 3.3 ms + one TCP connect + JSON; the reader pool is 8 connections. |
| kill -9 of the server during writes (8 writer clients, 10 rounds) | GREEN: 0 acknowledged rows missing or altered, `integrity_check ok` every round, server restarts on the same file. | A capture is acknowledged only after the writer thread's COMMIT returns (WAL; process kill loses nothing committed). |
| Extraction worker on the primary engine (small synthetic set) | ≤ 2 requests in flight at every sample (worker counter + `ss` peers to :18080); rows land with provenance; 0 connects anywhere else. | Two threads, one engine call each at a time. |

## 1. Verdict: PHASE 4 GATE **PASS** (every item GREEN on the final binary; one RED on the way, explained in §2)

Final binary: `zig build install -Drelease` (ReleaseSafe), `zig-out/bin/zigmem` sha256 `e4e02af166a469c16734f1a8b14be07654266c77f81cb0350397bcaaaf350970`.
Every gate below was re-run on exactly this binary after the last code change.

| Gate item | Result | Receipt |
|---|---|---|
| Auth matrix | **PASS 199/199.** 23 routes × {no token, Basic, empty Bearer, random token, token without prefix, token+junk} → 401; revoked (live, CLI revoke while serving, no restart) → 401; token file chmod 0644 → every token 401 (fail closed), back to 0600 → 200; another seat's scope (`scope`/`scopes`) → 403; another seat's atom by id (get/supersede/demote) → 404 (invisible, not "forbidden"); read-only seat writes → 403 ×6; non-admin admin routes → 403 ×6; untrusted seat family/medical/money text → 403 ×6 and nothing written; forged `x-vendor-*` + `x-zigmem-seat` + body `user_id/seat/agent_id/session_id` → ignored (results only from the token's scopes, the L0 row lands as `seat-a` in `seat-a/imp`, audit says `seat-a` with `ignored_identity`). Tokens never stored (only sha256), file 0600, audit has no request text. | `receipts/phase4/auth.json` |
| …the auth gate can go RED | **RED shown.** A scratch copy of the tree patched to honour `x-zigmem-seat` (the impersonation bug) fails 5 rows (forged search ×2, forged capture, MCP forged search, audit seat) → 194/199, rc 1. Patched copy deleted. | `auth_RED_impersonation_control.json` |
| Refuses 0.0.0.0 / non-loopback | **PASS 14/14.** `0.0.0.0`, `192.0.2.1`, `127.0.0.2`, `172.16.0.1`, `100.128.0.1`, `100.63.0.1`, `8.8.8.8`, `::`, `::1`, `localhost`, `0`, `""` → exit 2 in 30–43 ms, home dir not created, nothing listening. Default listens on `127.0.0.1:<port>` only; nothing after stop. `--bind 100.x` is accepted by the parser (unit test) but was never bound live (BOARD law 4). | `bind.json` |
| MCP from a real Claude Code client | **PASS, first try.** Claude Code 2.1.287: `claude mcp add --scope local --transport http` in `scratch/p4/mcp_client` → `claude mcp list` "✔ Connected" → `claude -p` (user settings not loaded, `disableAllHooks`) called `memory_search` → `memory_get` → `memory_block`, answered `SUBJECT=ana TEXT=Ana keeps the lantern in the blue shed. HITS=1` (the other-scope atom stayed invisible). Server audit: `server/discover` (→ -32601), `initialize`, `notifications/initialized` (202), `GET /mcp` (405, no SSE), `tools/list`, three `tools/call`. Then `claude mcp remove --scope local`: not listed, name and token absent from `~/.claude.json`. | `mcp_claude.txt`, `mcp_claude_answer.txt` |
| Fuzz, 0 crashes | **PASS.** 3,228 hostile requests (random field types incl. 2^64, 1e308, lone surrogates, 70 KB strings, 200K/500K-deep `[`, 80K-deep objects, 510 KB strings, random bytes, BOM, duplicate keys, 70-message batches; random methods/tokens/routes; MCP bad ids/limits/params/arguments; raw-socket abuse: garbage request lines, HTTP/2 line, TLS ClientHello, negative / duplicate / 2^64 / 10 MB Content-Length, chunked, 20 KB header, 100 headers, no-colon header, 10 KB bearer, short body, 80-connection slowloris). **0 deaths, 0 panics in the log, `/health` 200 after, `integrity_check ok`.** Also clean on the Debug build (all safety checks). | `fuzz.json`, `fuzz_debug_build.json` |
| p95 search latency through the API (100K synthetic atoms, 1,000 queries) | **PASS: sequential p50 2.46 / p95 7.31 / p99 10.0 ms; 8 concurrent clients p50 3.64 / p95 8.63 ms at 1,889 q/s.** Server-side p95 7.4 ms (the audit's `ms`); API overhead ≈ 0.3–0.5 ms, the rest is the store's FTS (`search_ms`). | `latency.json` |
| kill -9 during writes loses no committed row | **PASS.** 10 rounds × 8 writer clients, SIGKILL at a random 0.5–2 s: **30,436 acknowledged captures, 0 missing or altered**, `integrity_check ok` + FTS integrity-check every round, the server restarts on the same file (`/health` 200). Rows committed-but-not-yet-acknowledged at the kill are present too (e.g. round 1: 3,742 acked, 3,744 new rows). Checker RED control: 2/2 made-up acks flagged. | `crash.json`, `crash_negative_control.txt` |
| Extraction worker, ≤ 2 concurrent to the primary engine | **PASS.** 8 synthetic turns via `/v1/capture` → `--extract primary --workers 2`: 8/8 jobs done in 9 s, `inflight_max` 2, `ss` max 2 connections to `127.0.0.1:18080`, 0 peers anywhere else (40 samples), 8 engine connects, 0 refused. 8 atoms, subjects right (ana/ben), every row with `run_id api-w{0,1}-jobN`, extractor `zigmem-extract/x2.1\|glm-5.3-flash\|p:x2.1`, prompt sha. the primary engine had 0 running / 0 waiting before the run. | `extract.json` |
| Proxy mode (phase 0) in the same binary | **PASS 5/5** (local echo upstream, no engine): store-backed block at index 1 after the system message, byte-identical across turns of a session, still frozen after the persona row changed mid-session, a new session picks up the new persona, user turns untouched. `zigmem proxy` (phase 0, frozen file) is unchanged. | `proxy_mode.json` |
| Unit tests | `zig build test-api` 8/8 Debug, 9/9 `-Drelease` (step counts differ by one between modes; all pass); phase-0 `zig build test` still 6/6. | — |

## 2. Predictions vs results (receipt-style)

- Auth, bind, crash, extract, proxy: predicted GREEN, got GREEN.
- MCP real client: predicted GREEN after 0–2 REDs; **0 REDs.** The two surprises (Claude Code sends `server/discover` and tries `GET /mcp` for an SSE stream) were already handled by "method not found" and 405.
- Fuzz: predicted 0 crashes, got 0. The slowloris case behaved as designed: while 80 idle sockets were held, the 64-connection cap answered `/health` with 503; after they closed, 200.
- **Latency: first run RED** (`latency_RED_debug_build.json`: p95 56.6 ms sequential, 66.2 ms concurrent; server-side p50 18.9 ms). Profiling: the API added < 0.5 ms; `search_ms` was the whole cost; syscalls were negligible (strace −c) and the process burned 20 ms of **user CPU** per query, while the same SQL took ~1 ms in Python's sqlite3 and in `zigmem-storebench`. **Cause: `zig build` without `-Drelease` is a Debug build** (`standardOptimizeOption` only applies `preferred_optimize_mode = ReleaseSafe` when `-Drelease` is passed), so SQLite ran unoptimized. Rebuilt with `-Drelease`: p95 7.3 ms. No code change was needed for the gate; the `search_ms` audit field added while profiling stays. **Note for the board: RESULT.md says plain `zig build` gives ReleaseSafe; it gives Debug. Always build with `-Drelease`.**

## 3. What was built (`src/api/` 2,403 lines + `src/mcp/` 307 lines of Zig incl. tests; every file ≤ 600 lines with a `//!` header)

| File | What |
|---|---|
| `http.zig` | Raw-socket HTTP/1.1 (phase-0 pattern): thread per connection, cap 64 (503 beyond), 10 s receive/send timeouts, 16 KiB head (431), 512 KiB body (413), chunked refused (411), duplicate Content-Length refused, one request per connection. `parseBind`: `127.0.0.1` or `100.64.0.0/10` only. |
| `auth.zig` | Seat token table: `zm_` + 64 hex from the OS CSPRNG, shown once; file stores seat, sha256, scopes, flags (`w` writes, `t` trusted, `a` admin), person, created, revoked. Refused unless mode 0600 and owned by us; constant-time verify over every row; atomic rewrite (tmp + fsync + rename); the server reloads it when (inode, size, mtime) changes, and fails closed if it becomes unsafe. |
| `hub.zig` | One writer thread (phase-1 `Writer`), 8 read-only connections (pool), token table, Retriever, worker, append-only `audit.log` (0600): ts, seat, route, MCP method/tool, status, ms, `search_ms`, sizes, `ignored_identity`, `denied` — never arguments or text. `/health` counts only. Crash recovery: jobs left `running` go back to the queue at start. |
| `rest.zig` | Routes (below). Seat/scopes/flags only from the token; requested scopes must be ⊆ the seat's; writes need `w`; untrusted seats pass the privacy screen; session ids are namespaced `seat/key` so no seat can append to or read another seat's session; nothing is ever deleted. |
| `render.zig` | Hits JSON, the escaped `<relevant-memories>` recall block, atom JSON. |
| `screen.zig` | Privacy screen = hand port of the the handoff gateway's PRIVATE regex (a private-text word list): words, `\w*` prefixes, `$<digit>`, phone, e-mail, `401(k)`, `<n>k/m` near stock words. |
| `retriever.zig` | **The `Retriever` interface** (`search(ptr, a, st, Query) []Hit`, Query carries the token's `Scope`) and **`FtsStub` — STUB, clearly marked**: store BM25 only, no vectors/RRF/rerank/ledger/medical gates. |
| `block.zig` | Frozen per-session block: persona + scenes of the seat's scopes, sorted, no clocks/ids/scores, neutralised (no tag/template token/newline survives); stored once in `frozen_blocks` (first writer wins), byte-identical afterwards. |
| `worker.zig` | Extraction: ≤ 2 threads claim `extract` jobs (persistent queue, one job = one captured user turn), run the phase-2 pipeline (the primary engine extracts and judges), write through the writer thread (`WriterSink`), read candidates on their own read connection; counters for in-flight / max / connects. Capture is refused with 429 (nothing written) when queued ≥ `--queue-cap` (default 10,000). |
| `cli.zig` | `zigmem serve` (`--home --port --bind --extract none\|primary\|secondary --workers 1\|2 --queue-cap --proxy-upstream --proxy-port --proxy-seat`), `zigmem token add\|revoke\|list`, `zigmem people add`. Listens before opening anything (a refused bind leaves nothing behind). |
| `src/mcp/mcp.zig` | JSON-RPC 2.0 over streamable HTTP (one JSON reply per POST, notifications → 202, GET → 405). Protocol versions 2025-06-18 / 2025-03-26 / 2024-11-05. Tools `memory_search(query, limit≤20, type, subject, include_turns)`, `memory_recall(query, limit)`, `memory_add(text, session_key)` (write seats; goes to the extraction queue, never straight to an atom), `memory_get(id)`, `memory_block(session_key)`. Allowlisted, type-checked arguments; unknown ones dropped; errors are JSON-RPC errors, never a crash. No identity input: the backend is bound to the authenticated seat. |
| `src/main.zig` (additive) | `serve\|token\|people` dispatch to `api.cli`, plus `startProxy`, which runs the phase-0 `proxy.serve` with the store-backed MemorySource. `zigmem proxy` itself is unchanged. |
| `build.zig` (additive) | Phase-4 block: one store/extract module instance for the main binary, `api` + `mcp` modules, `zig build test-api`. **Note: this block was committed inside the phase-3 lane's commit `8b7f4ae`** (their `git add build.zig` swept it in), so this lane has no build.zig hunk left to commit. |

Routes (POST unless noted; all but `/health` need `Authorization: Bearer`): `GET /health` · `/recall` `/v1/recall` · `/capture` `/v1/capture` · `/search/memories` `/v1/search/memories` · `/search/conversations` `/v1/search/conversations` · `/session/end` `/v1/session/end` (v1 field names: `query, session_key, user_content, assistant_content, limit, type`; responses `context/strategy/memory_count/code/message/retryable`, `l0_recorded/scheduler_notified`, `results/total/strategy`) · `/v3/conversation/add` `/v3/conversation/search` `/v3/atomic/search` (`{code, message, data}` envelope) · `/v3/atomic/delete` + `/admin/retire` (admin; a status flip, `deleted: 0`) · ours: `/v1/session/block`, `/v1/atoms/get|list|supersede|demote` · `POST /mcp` · `/seed` → 501 (phase 8 import).

## 4. Wiring phase 3 (for the supervisor, when phase 3 passes)

Phase 3's retrieval is committed (`8b7f4ae`: `src/retrieve/recall.zig`, RRF, floors, the LAN reranker rerank, down path) but PHASE3.md has no PASS yet, so the hub still serves `FtsStub`. To wire it: add a `retriever.Retriever` whose `search(ptr, a, st, q)` calls phase-3 recall with `q.scope` (from the token) and maps its rows to `retriever.Hit`; set `hub.ret` to it in `Hub.init`; in `build.zig` give `p4_api` the `retrieve` + `privacy` modules built on the same `p4_store` instance (one store module per compilation). The phase-3 gate stack (ledger, medical scope, escape) then runs inside `search`; `render.recallContext` can switch to phase 3's `Escaper`. The latency gate (`gates.py latency`) and auth matrix should be re-run after wiring.

## 5. Not run, and why

- **MCP over stdio**: not built (HTTP only; the task allowed "stdio and/or HTTP"). A stdio bridge would forward to `/mcp` with a token.
- **Binding a live tailnet address**: parser-tested only; BOARD law 4 says 127.0.0.1 only during the build.
- **secondary in the worker** (person-switch corrections): not wired; PHASE2's verdict is the primary engine extracts and judges.
- **Power-loss durability**: process kill only (WAL, `synchronous=NORMAL`).
- **x86_64 (the x86 box) build**: not run this phase.
- **`/seed`, `/v3/scenario/*`, `/v3/core/read`, admin reindex/export**: not built (501 / 404); scenes and persona have no writer yet (phase 2 left them).
- **Privacy screen vs the Python regex, differentially**: not run. The screen is a hand port with 16 hit / 12 clear unit cases; phase 3's sre-compatible engine could run the verbatim pattern as a parity check later.

## 6. Known issues

1. **Build mode trap** (above): `zig build` = Debug; use `-Drelease`. Debug search was ~8× slower.
2. **Slowloris on loopback**: a local process holding 64 idle connections gets 503s for up to 10 s per wave. Loopback-only; a shorter head timeout is the cheap fix.
3. **Proxy port has no token** (phase-0 shape). It is bound to one seat with `--proxy-seat`; any local process that can reach the proxy port makes the engine see that seat's frozen block. Phase 8 should put the seat token on the proxy too.
4. **Bearer in `~/.claude.json`**: `claude mcp add --header` stores the token in clear while registered (removed and verified gone here). Real adapters (phase 7) should use a `headersHelper`, as the handoff gateway does.
5. **Worker background context**: each of the 2 threads keeps its own per-session history, so the 5 "background" turns of a session can be split between threads.
6. **Audit log** grows without rotation (phase 8).
7. Running `claude -p` in the scratch dir left Claude Code's normal per-project state (a project key in `~/.claude.json` with no MCP entry, and a transcript under `~/.claude/projects/-home-user-zigmem-scratch-p4-mcp-client/`), synthetic content only.

Nothing of this lane is running: every server was stopped by PID and verified gone (`stops` in each receipt); no listener on 18140–18159 or 8470. Scratch: `scratch/p4/` (17 MB, synthetic; the 100K-atom latency DBs were deleted).
