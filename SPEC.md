# zigmem — design

**Status:** design document (written 2026-10-12 before the build; the phase documents record what was actually built and measured).
**What it is:** one Zig binary + one SQLite file that gives local LLM agents memory: append raw turns (L0) → a local model
distils typed, dated atoms (L1) → code folds them into scenes (L2) and a short persona per person (L3); recall with
BM25 + vector fusion; inject the stable part once per session so the engine's prefix cache survives.
**Posture:** single household, loopback/tailnet only, local models only, nothing an LLM decides is ever deleted.

---

## 0. The idea in one paragraph

Memory for an agent is a pipeline, not a database feature. Raw turns are the source of truth and are kept forever. A
background extractor turns user turns into short third-person facts with a subject, a type, a priority and a validity
window. Facts are deduplicated against their nearest neighbours by one bounded LLM decision whose targets must come from
the candidates it was shown. Updates supersede; nothing is hard-deleted. Code — not the model — folds atoms into scenes
and a persona, with hard length caps. Recall runs FTS5 BM25 and flat-vector cosine, fuses them with RRF, applies a score
floor, an optional reranker, and a stack of privacy gates, and escapes the result before it reaches a prompt. The stable
part of memory (persona + scene index + tool recipes) is rendered once per session into a byte-identical block placed
right after the system prompt, so prompt caching keeps hitting while memory grows. Estimate at design time: ~11–13K lines
of Zig; the build receipts in `PHASE1..8.md` record what it became.

---

## 1. Design, subsystem by subsystem

### 1.1 Layers

| Layer | What | Decisions and reasons |
|---|---|---|
| **L0** raw turns | Every captured turn stored as-is: `session, seat, scope, role, text, ts, recorded, sha256`; FTS5 copy; optional vector copy | Append-only. The raw log is the source of truth. **One id** serves the row, the FTS entry and the vector entry, so nothing can drift between copies. |
| L0 capture | `/v1/capture` after each exchange (or the proxy after the stream closes); new-messages-only via a cursor; sha-dedup | Capture is idempotent and never on the hot path. Embedding is a **job row**, not fire-and-forget, so a failed embed is retried, not lost. |
| **L1** atoms | `id, lineage, subject, scope, type, priority 0–100, text, valid_from/valid_to, recorded, superseded_by, status, src_l0, extractor, prompt_sha, run_id` | Versioning is explicit: a stable `lineage_id`, bitemporal validity, `superseded_by`, never a hard delete. Types cut for a household: `fact, preference, event, instruction, person` (+ `work_*` optional). |
| Provenance | `runs` table: model, prompt sha256, run id, in/out ids on every extraction | A bad batch (bad model day, bad prompt revision) is retirable with one query. |
| **L2** scenes | Rows (not files): `scope, name, summary, body, heat, updated, status`; sections base/traits/preferences/signals/narrative/evolution/contradictions | The LLM returns JSON; **zigmem code writes the rows**. No LLM file tools. Scene cap (default 15 per scope) enforced in code, not in the prompt. |
| **L3** persona | One persona row **per person per scope**, written by code from LLM JSON | Hard length cap in code (a prompt-only cap is not a cap). |
| Seed / import | `zigmem import` of old transcripts (opt-in per path, `<private>`-stripped, never genome files by default) | Shadow-loading history is how a memory system gets evaluated before it is trusted. Import waits for L2/L3 completion before reporting done. |
| Prompts | One prompt set, versioned by sha256 in the repo | No per-layer custom prompt strategies or prompt tables; prompt identity rides on every row instead. |

Not in zigmem: agent-context compression (tool-result summarising, task judging, history rewriting). Rewriting history
breaks the prefix cache, and it is not memory.

### 1.2 Extraction pipeline

| Piece | Decision | Reason |
|---|---|---|
| Triggers | every N turns (5), idle 600 s, session end; **warm-up 1→2→4→N** | Warm-up gets day-one facts in early; a flat N leaves a new seat empty for its first hour. |
| L2/L3 cadence | `max(now+delay, last+900 s)`, forced 3600 s, stop after 24 h idle; L3 after L2 on first run / missing / +50 atoms | One scheduler, config-visible thresholds. |
| Pre-filter | drop empty / slash commands / framework noise / symbol-only; plus `is_machine_traffic` / `drop_machine_turns` ports | Machine traffic in the raw tape poisons extraction. |
| Window | last 10 new turns + 5 older marked "background, don't extract"; cap per session (default 12) | Context discipline: the model sees enough to resolve "it", not enough to re-extract old facts. |
| Prompt | English; household types; **third-person subject named** ("Morgan prefers…", never "User…"); priority floor enforced in code | A first-person or "User" fact cannot be attributed later and mis-files across people — the class of bug that scoping exists to prevent. **Assistant text excluded by default**: extracting the model's own output produces self-reinforcing echoes, and a prompt instruction alone does not stop it. |
| Parser | strip `<think>` + fences; **bounded JSON recovery** (`std.json.Scanner`, ≤32 balanced-brace candidates, ≤256 KB, string-aware); strict schema validation; one repair pass; 180 s timeout; diagnostics `no_json / parse_fail / not_array / empty_scenes` | Reject on schema mismatch. Never "store everything" when the model's reply is unparseable. |
| Scheduling | one process, one extraction worker (up to two threads), a persistent `jobs` table that survives restart | No external queue, no timers lost on crash. |

### 1.3 Dedup / merge / supersession

| Piece | Decision | Reason |
|---|---|---|
| Candidates | FTS ∥ vector, RRF, top-5 per new atom, same scope (and the subject's own person scope when the speaker may write there), excludes the atom's own batch | Nearest neighbours only; a decision over the whole store is unbounded. |
| Decision | one batch LLM decision `store / update / merge / skip` with `target_ids`; **exactly one decision per new atom** | A model is good at "is this the same fact", bad at bookkeeping. |
| Target check | **targets ⊆ the candidates shown, or the decision is rejected**; no cross-person merges | An unchecked target id lets a model touch any row in scope. |
| Supersession | **soft only**: new row, old row gets `superseded_by` + `valid_to` + an audit row; creation time of the lineage is kept | Nothing an LLM decides is ever deleted ("demote, never delete"). A merge that mints a new id with `created=now` loses history. |
| Failure | unparseable dedup output → the atom lands `pending_review` | Fail to a reviewable state, never to a blind write. |
| Time | bitemporal: `valid_from/valid_to` (world time) + `recorded` (record time) | "When was this true" and "when did we learn it" are different questions. |

### 1.4 Retrieval and recall

| Piece | Decision | Reason |
|---|---|---|
| FTS | SQLite FTS5, `tokenize='porter unicode61 remove_diacritics 2'`, `bm25()`; scope columns are real indexed columns | English stemming, no external tokenizer, scope filtering inside the query plan. |
| Vectors | own flat f32 store (blob per row, `@Vector` cosine, top-k heap); IVF only above ~500K rows; embedding fingerprint `provider|model|dims|url` in `meta` → change triggers a reindex job | ~100K atoms × 768-d is a 20–40 ms scan; an index is complexity without a payoff at household scale. |
| Embeddings | a local HTTP embedder is first-class (`--embed-url`, `{"inputs":[...]}` → float arrays, 768-d); without one, BM25 | Local-only is the default, not a degraded mode. |
| Fusion | RRF k=60, sum 1/(k+rank+1), implemented **once** (`rrf.zig`) | |
| Floor + rerank | floor on the **fused** score + per-engine minimum; optional reranker (`--rerank`, `{"query","docs"}` → `{"scores"}`) with a short leash; **when the reranker is down keep ≤2 rows** | A threshold that one code path ignores is not a threshold. A missing reranker must narrow, not widen, what reaches the prompt. |
| Scope | **a required argument of every store query**, derived from the seat token, never from the request | Isolation that a caller can forget to pass is not isolation. |
| Injection | stable part → the frozen block (§3.8); dynamic part only via tools or a late message; **text escaped** (tags, role headers); priority boosts rank; `instruction` atoms always included | Unescaped memory text is a prompt-injection path. |
| Self-echo | injected blocks wrapped in a per-session unguessable marker and stripped by marker before capture; `is_self_echo` port | Memory that re-reads its own injection grows an echo chamber. |
| Injection filter | on by default, red/green tested | |

The relationship graph (entity graph) stays outside zigmem; it is a different store with a different job.

### 1.5 Storage, config, plugins

| Piece | Decision | Reason |
|---|---|---|
| Tables | `meta, people, seats, sessions, frozen_blocks, l0, l0_fts, atoms, atoms_fts, vec, scenes, persona, audit, runs, jobs` (§3.4); WAL, busy 5000, 64 MB cache, 128 MB mmap | One file to back up, atomic. |
| L2/L3 | rows in SQLite; optional markdown export | No `.backup/` directory trees. |
| Backends | **one** backend: vendored SQLite | No document store, no cloud vector service, no object storage, no storage abstraction layer. |
| Identity tables | `seats` + `people` + scopes; tokens stored as sha256, **never plaintext** | |
| Config | one small INI-subset file + flags; **no default LLM URL** — the engine must be set and must resolve to an entry on the allowlist | A memory system that quietly talks to a default cloud endpoint is not local. |
| Env | plain, enumerated env reads; documented list | |
| Host integration | recall-before / capture-after / 2–3 read tools, exposed as **MCP + HTTP**, never as in-process host plugins; `read_file` → `read_scene` (no arbitrary paths) | zigmem never loads code into another product. |
| Adapters | printed snippets (`zigmem connect`) the person pastes or approves; the Hermes-style `Bearer local` default is refused | zigmem never writes into another product's tree or config. |
| Migrations | `PRAGMA user_version` stepwise, each tested on a copy; startup never drops a table | |

Not in zigmem: quotas/credits, task-source imports, a skills store, a code-graph service, a second runtime. Out of scope
for a household memory sidecar.

### 1.6 Proxy

| Piece | Decision | Reason |
|---|---|---|
| Wire formats | OpenAI chat (and the Anthropic / Responses shapes where supported), **explicit route table**, no catch-all `POST /*` | A catch-all forwards what it does not understand. |
| Auth order | **seat token first, then** the configured upstream key is attached; per-seat rate bucket (in-memory) | Attaching an upstream key before checking the caller is an open relay. |
| Bind | `127.0.0.1` / `::1` / unix socket / this host's CGNAT tailnet address; anything else → **refuse to start** | |
| Admin | a separate admin token file, mode 0600; an empty admin key is not "public" | |
| Frozen block | built on `session_init` (miss → build → cache); placed immediately after the byte-stable system prompt; **per-turn recall is never injected into the user message** | Per-turn injection into the conversation body breaks the prefix cache; per-turn hits arrive through tools or a late message instead. |
| Session key | from headers (`x-session-id`, `x-conversation-id`, `x-parent-conversation-id`, …) | |
| Streaming | SSE tee: body to the client + a background usage tap; stream parsers per wire format; bounded memory; client disconnects handled | |
| Archive | L0 write **after** the stream closes, never on the hot path | |
| `mem:` commands | help / sync / reset | |
| Proxy state | same SQLite file as the store: `sessions` + `frozen_blocks` | |
| Logging | local rotating JSONL with ids, sizes, timings only | |

Not in zigmem: synthetic tool-call "forms" injected into a conversation to pick an identity (identity comes from the seat
token); a debug mode that dumps full inbound prompts to disk; a raw passthrough route that skips auth; keys in query
strings; a proxy base URL that sniffs and embeds the host's LAN address into tool recipes (recipes use a configured name).

### 1.7 API and MCP

| Route | Shape | Why |
|---|---|---|
| `GET /health` | `{ok, version, schema, rows:{l0,atoms}, fts, embed:{ok,fingerprint}, llm:{ok,host}, …}` (no auth) | the one unauthenticated route |
| `POST /v1/recall` `/v1/capture` `/v1/search/memories` `/v1/search/conversations` `/v1/session/end` `/v1/seed` (also unprefixed) | request fields `query, session_key, user_content, assistant_content, limit, type`; responses `context/strategy/memory_count`, `code/message/retryable`, `results/total/strategy` | a client that already speaks this shape points at zigmem with a URL + token change |
| `POST /v3/conversation/{add,query,search,count}` · `/v3/atomic/{query,search,update,count}` · `/v3/scenario/{ls,read}` · `/v3/core/read` | `{code, message, data}` envelope; **`delete`/`write`/`rm` → admin token, and become retire** (a status flip) | v3-style compatibility routes for existing SDK-style clients; zigmem ships no SDK |
| `POST /v1/atoms/{add,get,list,supersede,demote}` · `/v1/session/block` · `/v1/household/*` | zigmem's own routes | lineage, supersession, the frozen block, household admin |
| `POST /mcp` (+ `zigmem mcp --stdio`) | JSON-RPC 2.0 `initialize`, `tools/list`, `tools/call`; tools `memory_search(query, limit≤20, type?, scene?)`, `conversation_search(query, limit, session?)`, `read_scene(name)`, `read_persona(subject?)`, and for seats with `writes` `memory_capture(text)` | the agent-facing surface |
| `POST /admin/{token,retire,reindex,export}` · `/admin/runs` | admin token only; `runs` exposed read-only for provenance | |
| `GET /panel/*` | §1.9 | |

Ignored on input and recorded in the audit as `ignored_identity`: any client identity header (`x-*-user-id`,
`x-*-service-id`, `x-*-agent-id`, `x-*-team-id`, `x-zigmem-seat`) and body `team_id / user_id / agent_id / seat`.
**Identity = token.**

### 1.8 Household, auth and privacy

- **Bind:** `127.0.0.1` / `::1` / unix socket / this host's CGNAT tailnet address. Anything else → exit 2 with a message.
  Never a public funnel.
- **Seat tokens:** 32 random bytes, shown once, stored as sha256; `Authorization: Bearer`; constant-time compare; per-seat
  `scopes` (e.g. `household`, `person:<name>`, `kid:<name>`, `work`), `writes` flag, `trusted` flag, rate bucket. Admin
  token separate, file 0600. A token file with loose permissions fails closed (every token 401).
- **Scopes in every query:** store functions take a `Scope` value, not an optional. A test fuzzes recall with forged
  headers and body ids.
- **Household rule on every row:** a seat reads only what its member may see; medical facts never promote to the shared
  scope and never cross scopes; an ambiguous name fails closed; a parent may write about a child into the child's scope,
  never a medical row.
- **`<private>…</private>`:** stripped before the L0 write; an unclosed tag hides the rest of the message; if the filter
  cannot run the text is **dropped** (fail-closed).
- **Stale-fact scrub ("ledger firewall"):** a recalled line asserting a value the current-facts ledger marks dead is
  **annotated with the current truth, never deleted**. Fail-open per fact: an unparseable ledger entry skips itself.
- **Medical person-scope gate:** a medication/condition line is served only for its own person. Atoms carry a `subject`
  at write time, so the gate checks a column, not a guess.
- **Self-echo / machine traffic:** ported filters + the per-session marker around injected blocks.
- **Parity rule:** one `gate_vectors.json` (inputs → expected outputs) generated from the reference Python filters; the
  Zig gates must match 100% before the retrieval phase passes. The Python stays the reference.
- **Generic in public builds:** house-specific gates sit behind `-Dhouse=true`; the public tree ships `<private>`, a
  generic subject-scope gate and a pluggable deny-list file, with no family names and no ledger schema.

### 1.9 Panel

- Served by the hub itself at `/panel` on the same loopback/tailnet port; ~6 read-mostly server-rendered pages + ~200
  lines of vanilla JS, no build step, no bundle.
- Same seat token as the API, HttpOnly cookie, CSRF token on every write. **No secrets in browser storage.**
- Pages: atoms by subject, lineage view, supersede/retire (a panel edit = a new superseding row), seats, health.
- No roles beyond household scopes; no SSO; no external URLs.

### 1.10 Deploy

- One static binary + vendored SQLite; no container in v1; a systemd **user** unit with `NoNewPrivileges`,
  `ProtectSystem=strict`, `ReadWritePaths=` the data dir only.
- The admin token is minted locally by `zigmem token --admin` (file 0600). **No network route can create an admin.**
- Reproducible `zig build -Drelease`; the release notes carry the binary's sha256.
- A test greps the binary's strings for any URL that is not a loopback example.

---

## 2. Design boundaries (what zigmem does not do, on purpose)

| # | Boundary | How it is enforced |
|---|---|---|
| B1 | **No telemetry, no trace exporter, no analytics sink.** | No exporter code exists. The binary links no network client except the configured, allowlisted LLM / embedding / rerank hosts. `tests/extract/run_gate.sh` runs the extractor under `strace` and lists every `connect()` destination. |
| B2 | **No prompt or completion text in any trace or log.** | Logs carry ids, sizes and timings only; the audit row has no request text. |
| B3 | **No default model URL, no cloud fallback.** | The engine must be configured and must be on the allowlist (IP literals, no DNS); any other host → refuse to start. |
| B4 | **No unauthenticated bind.** | Bind allowlist: `127.0.0.1`, `::1`, a unix socket, or this host's CGNAT tailnet address. `0.0.0.0` and LAN addresses → refuse to start. Every route but `/health` needs a seat token. |
| B5 | **No open relay.** | The seat token is checked before any upstream key is attached; per-seat rate bucket. |
| B6 | **No install scripts, no edits to another product's files.** | Adapters are printed snippets the person pastes or approves. A diff check in the adapter gate proves zero files of other products changed. |
| B7 | **No second runtime, no process spawning.** | Single static Zig binary + vendored SQLite. |
| B8 | **Plain, enumerated env reads.** | Documented list; nothing obfuscated. |
| B9 | **TLS verification is never disabled.** | Clients talk plain HTTP over loopback or WireGuard; if TLS is ever used, verification is on. |
| B10 | **Identity comes from the seat token only.** | Client identity headers and body ids are ignored and recorded; no synthetic tool-call forms. |
| B11 | **No full-prompt debug dumps.** | Not implemented. |
| B12 | **Tokens only in `Authorization`, stored as sha256, never in browser storage, never in a URL.** | |
| B13 | **Startup never drops a table.** | Migrations are additive and versioned. |
| B14 | **No DELETE reachable from extraction.** | Supersession only; a grep test in the store gate proves it. |
| B15 | **No LLM- or server-named file paths.** | Files are keyed by zigmem's own ids. |
| B16 | **Ports are configured, not assumed.** | Default hub `127.0.0.1:8470`; panel under the same port at `/panel`. |

---

## 3. Zig architecture

### 3.1 Shape

One binary `zigmem`, subcommands: `serve` (hub + worker threads), `proxy`, `import`, `export`, `migrate`, `doctor`,
`token`, `household`, `connect`, `mcp`.
One data dir (`--home`, default `~/.zigmem/`): `zigmem.db` (+ WAL), `tokens` (0600), config, `logs/`.

```
src/
  main.zig          subcommands
  conf.zig          INI-subset parser, bind/LLM allowlists, refuse-unsafe
  proxy.zig         frozen block, passthrough, gates
  store/
    sqlite.zig      thin wrapper over the vendored amalgamation: open/prepare/bind/step/tx
    schema.zig      DDL + PRAGMA user_version migrations
    l0.zig          append turns, cursors, idempotent capture
    atoms.zig       L1 rows, lineage, supersede, audit
    scenes.zig      L2 rows + L3 persona rows
    vec.zig         f32 blobs, SIMD cosine, flat top-k
    jobs.zig        persistent job queue (embed/extract/scene/persona)
  extract/
    llm.zig         OpenAI-compatible chat client (non-stream), timeout, retry
    prompts.zig     prompt text + sha256; render (no date/score in stable parts)
    parse.zig       bounded JSON recovery: strip think/fences, Scanner, schema check
    l1.zig          window selection, extraction run, priority floor
    dedup.zig       candidates, LLM decision, target ⊆ candidates, apply
    sched.zig       warm-up 1→2→4→N, idle, L2/L3 cadence
  retrieve/
    fts.zig         FTS5 query building (unicode61+porter), bm25()
    embed.zig       HTTP embedder client, batching, fingerprint
    rrf.zig         RRF k=60, fused floor, priority boost
    rerank.zig      optional reranker, ≤2 rows when down
    recall.zig      scope-filtered recall, format + escape
  privacy/
    private.zig     <private> strip, fail-closed
    regex.zig       POSIX ERE via libc regcomp/regexec (translate-c) + flags
    ledger.zig      stale-fact scrub
    medscope.zig    medical person-scope gate
    echo.zig        self-echo / machine-traffic / injected-marker strip
  household/        members, seats, scopes, the write rule
  api/
    http.zig        std.http.Server loop, thread-per-conn, body limits
    auth.zig        seat tokens (sha256 at rest), scopes, admin token
    rest.zig        /health /v1/* /v3/* /admin/*
    mcp.zig         JSON-RPC 2.0 over HTTP (+ stdio mode), tools
  panel/            server-rendered pages + CSRF; one CSS + ~200 lines vanilla JS, @embedFile
  adapters/         `zigmem connect` snippet writers
vendor/sqlite/      sqlite3.c + sqlite3.h (amalgamation, public domain), FTS5 on
```

Every file ≤ 600 lines with a one-line `//!` header, so the tree reads like a lean engine sidecar.

### 3.2 Dependencies (and why)

| Need | Choice | Notes |
|---|---|---|
| Compiler | **Zig 0.17.0** pinned | Same toolchain as the local inference engine it sits beside. |
| SQLite | **Vendored amalgamation** compiled by `build.zig` (`addCSourceFile`, `-DSQLITE_ENABLE_FTS5 -DSQLITE_DQS=0 -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1`), bound via `b.addTranslateC` | `@cImport` no longer exists in 0.17; `addTranslateC` + `createModule()` works. Vendoring avoids `-dev` packages and pins the version. |
| FTS | SQLite FTS5, `tokenize='porter unicode61 remove_diacritics 2'`, `bm25()` | No external tokenizer. |
| Vectors | **Own flat store** (f32 blob per row, `@Vector` cosine, top-k heap) | ~100K atoms × 768-d = 300 MB f32; flat scan ~20–40 ms on the dev box. IVF only above ~500K rows. |
| Embeddings | HTTP `{"inputs":[...]}` → float arrays (nomic-embed-text-v1.5, 768-d) | Fingerprint = `provider|model|dims|url` in `meta`; change → reindex job. |
| Extraction LLM | **Local only**, an OpenAI-compatible `/v1/chat/completions` on an allowlisted host | Runs as idle-time jobs; the runner yields when the engine reports a queue. Never cloud. |
| Rerank | optional, `{"query","docs"}` → `{"scores"}`, short leash (0.5 s connect / 3 s read) | |
| HTTP server/client, JSON | `std.http.Server`, `std.http.Client`, `std.json`, `std.Io.net` | |
| Regex (for gate ports) | libc POSIX `regcomp/regexec` (ERE, `REG_ICASE`) via translate-c | std has no regex. glibc ERE lacks lookarounds and inline flags; patterns are re-expressed and held to a shared test-vector file. |
| Hashing | `std.crypto.hash.sha2.Sha256`, `Blake3` | Blake3 over 256-token chunks matches the engine-side prefix-cache key chain, so the frozen block's prefix key can be looked up by the engine. |

No other dependency. No Node, no Python at runtime, no container.

### 3.3 Threads

`serve` runs: N HTTP connection threads (thread-per-connection, capped), **one writer thread** owning the SQLite write
connection (all writes go through a bounded queue → no `SQLITE_BUSY` storms), one **job worker** (embed / extract / scene /
persona; one LLM call at a time, up to two threads), read connections per HTTP thread (WAL readers).

### 3.4 Storage schema (SQLite, `PRAGMA user_version`)

```
meta(k TEXT PK, v TEXT)                                  -- schema, embed fingerprint, prompt shas
people(id TEXT PK, display TEXT, aliases TEXT)           -- household members; aliases for subject resolution
seats(id TEXT PK, token_sha256 BLOB UNIQUE, person_default TEXT, scopes TEXT, writes INTEGER, created_ms INTEGER, revoked_ms INTEGER)
sessions(id TEXT PK, seat TEXT, session_key TEXT, started_ms INTEGER, last_ms INTEGER, turns INTEGER, state TEXT)
frozen_blocks(session_id TEXT PK, text TEXT, sha256 BLOB, built_ms INTEGER, source_rev INTEGER, kv_prefix_key BLOB)
l0(id INTEGER PK, session_id TEXT, seat TEXT, scope TEXT, role TEXT, text TEXT, ts_ms INTEGER, recorded_ms INTEGER, sha256 BLOB UNIQUE, private_dropped INTEGER)
l0_fts USING fts5(text, content='l0', content_rowid='id', tokenize='porter unicode61 remove_diacritics 2')
atoms(id INTEGER PK, lineage TEXT, subject TEXT, scope TEXT, type TEXT, priority INTEGER, text TEXT,
      valid_from TEXT, valid_to TEXT, recorded_ms INTEGER, superseded_by INTEGER, status TEXT,   -- active|superseded|pending_review|retired
      src_l0 TEXT, extractor TEXT, prompt_sha BLOB, run_id TEXT, sha256 BLOB)
atoms_fts USING fts5(text, content='atoms', content_rowid='id', tokenize='porter unicode61 remove_diacritics 2')
vec(kind TEXT, row_id INTEGER, dims INTEGER, emb BLOB, PRIMARY KEY(kind,row_id))   -- kind = l0|atom|scene
scenes(id INTEGER PK, scope TEXT, name TEXT, summary TEXT, body TEXT, heat REAL, updated_ms INTEGER, status TEXT)
persona(subject TEXT, scope TEXT, text TEXT, rev INTEGER, built_ms INTEGER, PRIMARY KEY(subject,scope))
audit(id INTEGER PK, ts_ms INTEGER, seat TEXT, action TEXT, table_name TEXT, row_id INTEGER, detail TEXT)
runs(id TEXT PK, kind TEXT, model TEXT, prompt_sha BLOB, started_ms INTEGER, ended_ms INTEGER, in_ids TEXT, out_ids TEXT, outcome TEXT)
jobs(id INTEGER PK, kind TEXT, key TEXT, due_ms INTEGER, tries INTEGER, state TEXT, last_err TEXT)
```
Indexes on every `scope`, `(scope,status)`, `(session_id,ts_ms)`, `lineage`, `subject`. No DELETE on `l0`, `atoms`, `audit`
from any code path except the admin `retire` (which sets `status`, never deletes). Retention: L0 forever — it is the raw
tape; `export` + `<private>` stripping at write keep it honest.

### 3.5 Pipelines

- **Capture** (`/v1/capture`, proxy after-stream, MCP `memory_capture` if the seat has `writes`): strip `<private>` →
  drop machine traffic / injected markers / self-echo → L0 append (sha-dedup) → bump turn counter → maybe enqueue `extract`.
- **Extract** (job): window 10 new + 5 background, **user turns only by default** → LLM → parse/validate → subject must resolve
  to a `people` row or `unknown` (unknown → `pending_review`) → candidates (FTS ∪ vec, top-5, same scope) → dedup decision →
  apply as insert / supersede (new row, old `superseded_by`, `valid_to`) / skip. Every row stamped with run id + prompt sha.
- **Review** (idle job): one bounded call per `pending_review` atom; code re-files it under a member through the same write
  rule, or retires it — always with an audit row, never a silent drop.
- **Scenes / persona** (jobs): LLM returns JSON; code writes; length caps in code; persona per subject per scope.
- **Recall** (`/v1/recall`, MCP `memory_search`): scope from token → FTS top-3k ∥ vec top-3k → RRF k=60 → fused floor →
  priority boost → optional rerank → gate stack (§1.8) → escape → ≤ budget chars.

### 3.6 Frozen-per-session block (prompt cache)

- Built once per session at the first request: persona(s) for the seat's scopes + scene navigation + the read-only tool
  recipes / MCP hint. **No dates, scores, counters or ids** inside it — any of those kills the cache.
- Stored in `frozen_blocks` with sha256 and `source_rev`; reused byte-identically for the session's life; a new session
  picks up new persona revisions. Placed **immediately after the byte-stable system prompt**.
- Per-turn hits never go into that block: tools, or a late system message last.
- **Prefix-cache link:** the block's token prefix key is computed with the engine's chain (blake3 over 256-token chunks);
  only full 256-token chunks are cold-exact, so `exact_upto` is recorded and the engine re-reads the tail. A frame key
  includes the model identity, so a frame built for one quantisation never serves another. Frames are built only from
  **filtered** text. zigmem never ships KV bytes itself — it hands the engine a stable prefix and, where a cache bank is on,
  a key to look up.

### 3.7 Toolchain probes run for this design (Zig 0.17, throwaway dirs)

| Probe | Result |
|---|---|
| `pub fn main(init: std.process.Init)` + `std.json.parseFromSlice` + `std.Io.net.IpAddress.parse("127.0.0.1",0).listen(io,.{.reuse_address=true})` | compiles + runs |
| `@cImport({@cInclude("stdio.h")})` | **error: invalid builtin function '@cImport'** — removed in 0.17 |
| `b.addTranslateC(.{.root_source_file=…, .link_libc=true}).createModule()` → `@import("c").printf` | works |
| system SQLite | 3.45.1 with FTS5 but no `sqlite3.h` on the dev box → vendor the amalgamation |
| std signatures | `http.Server.init(in,out)`, `receiveHead`, `Request.respond/respondStreaming`; `http.Client.fetch/request`; `Io.net.Server.accept(io)`; `Io.Threaded`, `Io.Uring`, `Io.Evented` exist |

---

## 4. How zigmem fits beside an existing memory stack without replacing anything

| Existing | Relationship | Rule |
|---|---|---|
| A typed long-term store | untouched; zigmem never writes it | Optional later: zigmem atoms that survive review become **candidates** for it through its normal review path, never directly. |
| A cloud / self-hosted vector memory | untouched | No mirror, no hooks into its write chain. |
| A reranked retrieval lane | zigmem is **one more source** (shadow first, fallback mode, minimum score) | Never replaces the existing engines. |
| A handoff gateway between seats | different job | zigmem copies its posture (allowlist, loopback, privacy screen, per-call audit line with no arguments) — not its data. |
| A review pipeline for canon | zigmem output = **signals/candidates only** | Nobody writes canon directly. Family-name / medical / money atoms are **never auto-promoted**; they sit `pending_review` until a principal ratifies (or forever). |
| An engine-side prefix-cache bank | zigmem supplies a byte-stable block + its prefix key | The bank stays opt-in; zigmem never stores KV bytes. |
| A journal pen | untouched | zigmem never appends to it; seed import may *read* a replica. |

**Shadow-mode ladder (each step needs its gate green before the next):**
1. **Dark:** runs on the dev box on `127.0.0.1:8470`, fed by `zigmem import` of a *copy* of recent transcripts; nothing reads it.
2. **Bench-only:** a new bench lane and a family-eval lane.
3. **Extra source, fallback mode:** on one terminal seat only.
4. **One local seat's frozen block** through the proxy.
5. Anything wider = a principal's call.

**Eval gates (hard, every phase that touches recall):** the 130-question bench — hits must not drop vs the same-day
control; the family eval — **dead-value leaks stay 0/93**, safety@turn not lower, self-pollution not higher, surface SLO
≤ 4 s for phone lanes. Prediction note before each run, receipts after, "not run, and why" in every report.

---

## 5. The inference-engine add-on

- **Sidecar, never inside the engine.** zigmem talks HTTP to the engine's serve command; the engine needs zero changes.
  Topology: `client → zigmem proxy → engine`; the zigmem hub beside it; extraction calls go to the same engine (or another
  local one) at idle via its OpenAI route.
- **Why it helps engine users:** an engine that keeps prefix states on disk keyed by token hash turns a byte-stable
  per-session memory block right after the system prefix into a reusable prefix instead of a cache miss. That is the
  add-on's pitch, measured as TTFT with/without.
- **Only upstream shape that could land later:** an issue first, then a single `--memory DIR` flag, replies byte-identical
  when off, golden tests, no env vars, no external embedding call, files ≤ 600 lines. Not planned; the sidecar is the product.
- **Public release (`zigmem`, Apache-2.0):**
  - Repo built from a clean orphan commit, never a local working history.
  - **Generic only:** no persona names, no family names, no ledger, no fleet names, no house ports, no `-Dhouse` code paths
    in the public tree (house-specific gates live in a private overlay). The household's own memory system is never
    published; the public zigmem is a generic local memory sidecar.
  - Ships: the `zigmem` binary (aarch64/x86_64 Linux, aarch64 macOS), an example config pointing at `127.0.0.1`
    OpenAI-compatible engines, MCP + v1/v3 docs, a synthetic-data test suite and a public bench on synthetic personas.
  - Release checks: secret/house-name scan (0 hits), URL scan of the binary (only localhost examples), reproducible sha256.

---

## 6. Phased plan

Lines = Zig only (tests included, prompt text and HTML excluded). Days = focused agent-days with receipts, not calendar.

| Phase | What | Zig lines | Days | Depends on | Pass/fail gate |
|---|---|---|---|---|---|
| **0** | Proxy: frozen block after system prompt, passthrough, cache/quality gates | — | — | — | `RESULT.md` (exactness 10/10 token-SHA, TTFT ±10%, 30-q quality) |
| **1** | **Store**: vendored SQLite + translate-c, schema + migrations, L0/atoms/scenes/persona/audit/jobs, FTS5, flat vectors, `<private>` at write, writer thread | 2,000 | 6–8 | — | (a) kill -9 during 10K-row write ×20 → `integrity_check ok`, no lost committed rows; (b) 100K atoms: insert ≥ 2K/s, FTS p95 < 20 ms, vec top-10 p95 < 50 ms; (c) `<private>` red/green 11/11 vs the reference test cases; (d) no DELETE reachable (grep test) |
| **2** | **Extract**: LLM client, prompts, parser, L1 run, dedup w/ candidate check, supersession, scheduler (warm-up, idle, L2/L3), scenes/persona writers | 2,300 | 8–10 | 1 | on 40 replayed sessions (synthetic + shadow copies): JSON valid ≥ 95% on the primary engine, ≥ 85% on a 7B fallback; **0 hard deletes, 0 out-of-candidate targets applied**; subject resolved ≥ 90%, unresolved → pending_review 100%; extraction makes 0 connections outside the allowlist (socket audit); warm-up timing matches 1→2→4 |
| **3** | **Retrieve + gates**: FTS/vec/RRF/floor/rerank, scope-mandatory recall, escape, gate ports (private, ledger, medscope, echo) + `gate_vectors.json` parity | 1,700 | 6–8 | 1, 2 | gate parity 100% vs Python; forged-scope fuzz 0 leaks; bench lane as extra source: **130-q hits ≥ control**, **family eval leaks 0/93**, safety@turn ≥ control; reranker-down run keeps ≤ 2 rows |
| **4** | **Hub API + MCP**: http loop, seat/admin tokens, v1 + v3 routes, MCP HTTP + stdio, admin CLI | 1,900 | 6–8 | 1, 3 | auth matrix (no token 401, wrong scope 403, forged identity headers ignored) 100%; refuses 0.0.0.0/LAN bind; contract tests replaying hand-written v1/v3 request shapes; Claude Code connects over MCP and `memory_search` answers |
| **5** | **Household memory**: people, scopes, seat→scope mapping, shared vs private atoms, per-person persona | 700 | 3–4 | 4 | cross-scope matrix (each kid seat cannot read another's private scope; a principal has full authority) 0 leaks; medical subject column gates 100% |
| **6** | **Panel (minimal)**: atoms by subject, lineage view, supersede/retire, seats, health | 800 (+~400 HTML/JS) | 4–5 | 4, 5 | loopback/tailnet only; CSRF on every write; no secret in localStorage/sessionStorage (browser test); retire = status flip, audit row |
| **7** | **Adapters**: Claude Code (MCP entry + optional capture hook script), pi extension (MCP/HTTP), Hermes (URL+token), Codex (MCP), OpenClaw (MCP, never patched) | 500 (+ small TS/py shims) | 4–5 | 4 | each adapter: capture → recall round trip on a scratch seat; zero files of other products modified (diff check) |
| **8** | **Shadow rollout + sidecar packaging**: import tool, doctor, systemd user unit, prefix-cache key link, public generic tree + scans | 900 | 5–6 | 1–7 | shadow ladder steps 1–3 green; public tree house-name scan 0 hits; TTFT win with engine prefix reuse vs no block, ABBA-paired, 95% CI |
| 9 (opt.) | Knowledge/wiki (character-chunked ingest, wiki FTS + wikilink hop, `wiki_*` MCP tools) | 2,500 | 8–10 | 4 | only if wanted; existing library/wiki stores already cover this |

**Total (phases 1–8): ~10,800 lines Zig (+ ~1,200 lines prompts/HTML/JS/shims) ≈ 12K; 42–54 agent-days.**
Honest range with rework and Zig churn: **45–60 days** for one lane, ~6–8 calendar weeks with two lanes
(store∥extract-prompt work, then retrieve∥hub). Phase 9 adds ~2 weeks. The tree stays small because tenancy, cloud
backends, context compression, telemetry, a bundled web app and a code graph are all outside its scope.

## 7. Hard parts and risks (ranked)

1. **Extraction quality on a local model.** Extraction prompts of this kind are usually tuned on large cloud models; a 7B
   model is weak at strict JSON and at many-to-many dedup decisions; a mid-size local model is better but shared.
   Mitigation: small single-purpose prompts, code-enforced schema, yes/no sub-calls, `pending_review` instead of guessing,
   a 40-session replay set with a regex truth file, prompt sha on every row so a bad batch is retirable.
2. **Privacy-gate parity in Zig without a regex engine.** The stale-fact scrub and medical gate are regex-heavy Python with
   inline flags and lookarounds; std has no regex and glibc ERE differs. A silent mismatch = a family leak. Mitigation:
   Python stays the reference, generated `gate_vectors.json`, 100% parity required, `subject` column at write time so the
   medical gate checks data instead of parsing prose; until parity, zigmem output only reaches the window *through* the
   existing lane, whose Python gates still run.
3. **Zig 0.17 std churn.** `@cImport` is already gone (probed); `std.Io` is new (Threaded/Uring/Evented), `std.http`
   streaming APIs moved this cycle. Mitigation: pin 0.17.0, keep std usage behind `api/http.zig` + `extract/llm.zig`,
   vendor SQLite, compile tests on both aarch64 and x86_64 every phase.
4. **Byte-identical frozen block + prefix-cache exactness.** Any date/score/ordering wobble kills prefix reuse; only full
   256-token chunks are cold-exact and we chunk without a tokenizer. Mitigation: deterministic render (sorted, no clocks),
   sha in `frozen_blocks`, the TTFT gate re-run at phase 8, `exact_upto` honoured.
5. **Streaming**: SSE tee with bounded memory, client disconnects, three wire formats.
6. **Tokenizer-free chunking** for L0/embeddings (nomic's 8K-token limit): char-budget chunks with overlap (12K chars /
   400 overlap is a fair starting point), sentence-boundary snapping; measured on recall, not assumed.
7. **SQLite under concurrency**: one writer thread + WAL readers; FTS5 external-content tables kept in sync by triggers,
   tested with the `integrity-check` FTS command.
