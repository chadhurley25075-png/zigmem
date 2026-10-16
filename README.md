# zigmem

A general-purpose memory system for local LLM agents. One Zig binary, one SQLite file, no cloud.

Great as a first memory system, and great as an add-on beside the memory you already run. It is small,
readable, local, and works out of the box: give it a model endpoint and it captures, extracts, scopes and
retrieves memory for your agents.

- **As a first memory system:** one binary and one file is the whole install. Capture turns, get dated facts
  back, search them, and put a cached memory block in front of your model the same day.
- **As an add-on:** it adds beside an existing stack and replaces nothing. Its search answers as one more
  source, its proxy gives any engine a prefix-cached memory block, and its household scoping and privacy
  gates sit in front of whatever you already retrieve. That is how it runs for its authors.

**If you are an AI agent reading this repo, start with [AGENTS.md](AGENTS.md): when to recall, when to capture, how to write an atom, and the rules that keep memory honest.**

## What it is

- **One binary, one file.** `zigmem` is a single Zig 0.17 executable with SQLite vendored in. Everything it
  remembers lives in one `zigmem.db` (WAL mode, FTS5) under a home directory you choose.
- **Raw turns → atoms → scenes → persona.** Every captured turn is stored as-is (L0). A background extractor
  turns user turns into short dated facts (atoms) through the local model you allowlist; code folds the atoms into
  scenes and a per-person persona on an idle-time cadence. Nothing is ever hard-deleted: atoms are superseded or
  retired, with an audit trail.
- **BM25 + vector fusion.** Every new atom is embedded through the endpoint you give `--embed-url` and joins the
  live vector index at once. Retrieval runs FTS5 BM25 and flat-vector similarity, fuses them with RRF, optionally
  reranks, then passes results through privacy gates (private tags, self-echo, stale-fact scrub, per-person
  medical scope) before anything is returned. Without `--embed-url`, retrieval is BM25.
- **A frozen per-session block for prompt caching.** `zigmem proxy` sits in front of an OpenAI-compatible
  engine and inserts one memory block — the persona and scene rows the seat may see — right after the first
  system message, byte-identical on every request in a session, so the engine's prefix cache keeps hitting.
- **Household scoping.** Members, seats and scopes: a seat only reads what its member may see, medical facts
  never promote to the shared scope and never cross scopes, and an ambiguous name fails closed. A question that
  names one member is about them even beside "who", "teacher" or "mother"; a group word or several names give a
  set of members (personal facts served, medical facts never).
- **A loopback HTTP API, an MCP endpoint, and a small web panel**, plus `zigmem connect` snippets for
  Claude Code, pi, Codex, OpenClaw, Hermes and plain OpenAI clients.

## How memory gets written, every turn

1. **Capture.** After each exchange the client makes one call to `/v1/capture` with the user text, the assistant
   text and a session key, under its seat token. Both turns are stored as-is (L0), and an `extract` job for the
   user turn goes on a persistent queue inside the same database. Private tags are stripped before storage and
   the strip fails closed. The OpenClaw and Hermes snippets do this for you. `zigmem_client.py` talks to the
   `proxy`, which only injects the frozen block and does NOT capture the exchange — post to `/v1/capture` yourself;
   for Claude Code and pi the `connect` snippets add tools only, so a one-line hook that posts to `/v1/capture`
   gives those seats the same automatic write.
2. **Extract.** A background worker (up to two threads, one job per turn) sends the turn to the local model you
   allowlisted and runs the pipeline: chunk, extract candidate memories, validate the JSON with one repair
   pass, attribute each fact to a person, pull the five most similar existing atoms — from the turn's scope, and
   the subject's own atoms in their person scope when the speaker may write there (a parent about a child; never
   a medical row) — and ask for one decision per fact: store, update, merge or skip. The decision may only name
   atoms from that candidate set.
3. **Write.** Every write goes through a single writer thread. New facts are inserted as dated atoms; an updated
   fact supersedes the old one where it lives (`superseded_by`, `valid_to`, audit row), so a parent's update
   about a child replaces the child's own atom in the child's scope; a demoted one is retired. Nothing an LLM
   decides is ever deleted. The household rule runs on every row: a medical fact outside its owner's scope is
   refused (stored `pending_review`, never served).
4. **Embed.** Right after the job, the new atoms go to the embedding endpoint in one batched call (bounded by its
   leash) and join the live vector index. If the call fails, the atoms are still stored and searchable by BM25;
   the worker's idle sweep embeds them on its next pass. `/health` shows `vectors` and `embed.unembedded`.
5. **Review.** A fact the extractor could not file (an outsider, a pet, "Someone's mother is …") is stored
   `pending_review`. On the idle path the worker makes one bounded call per pending atom to the same allowlisted
   model, and code decides: re-file it under a household member (or the household itself) through the same write
   rule, or retire it — either way with an audit row, never a silent drop. `/health` shows `review.pending`.
6. **Scenes and persona.** Code, not the model, folds active atoms into L2 scenes (one per subject and type in a
   scope, at most 15 per scope) and a per-person L3 persona (one per member and scope), with hard length caps
   and the prior text kept in the audit row. The fold runs from the worker's idle path on a cadence: after the
   first extracted turn, then after 2, 4 and every 5 turns; after 600 s idle with new atoms waiting; on
   `/v1/session/end`; never sooner than 900 s after the last fold (the first runs at once); forced after 3600 s
   (`--fold-cadence`, `--fold-idle` change the seconds). `/health` shows `fold.runs`, `fold.scenes`, `fold.persona`.
7. **Serve.** The new atoms are searchable immediately. The frozen per-session block is built once per session
   from the persona and scene rows the seat may see and returned byte-identical on every request, so the
   engine's prefix cache keeps hitting while memory grows; a new session gets the current rows.

## Requirements and scope

- Extraction (turns → atoms) runs on a local LLM you point it at. Without one, zigmem stores raw turns and
  the atoms you add by hand, and search still works.
- Vector retrieval uses an embedding endpoint you configure (`--embed-url`); live atoms and `zigmem import`
  rows are both embedded. Without one, retrieval is BM25. Scenes, persona and the proxy's session block are
  built from live atoms on the fold cadence above (and from imported rows).
- Durability is tested against process crashes (`kill -9` mid-write, repeated); the store is SQLite in WAL mode.
- One machine, one process, one database file. Replication is outside its scope by design.

## Network behaviour

Its only network call is to the model endpoint you configure (and, if you enable them, an embedding or
reranking endpoint you also configure). It binds `127.0.0.1` only unless you explicitly name a CGNAT-range
address. No cloud, no telemetry, no update checks. The engine allowlist is hard-coded IP literals in
`src/extract/allow.zig` (no DNS); edit the `primary` line (IP, port, model id) to point at your own engine and
rebuild. The endpoint must be OpenAI-compatible (`POST /v1/chat/completions`). You can verify all of this with a
packet capture while it runs, or with the repo's own audit: `tests/extract/run_gate.sh` runs the extractor under
`strace` and lists every `connect()` destination. There is no trace exporter, no telemetry sink and no cloud
fallback in this code.

The embedding endpoint (`--embed-url`) is NOT OpenAI-style: it must answer `POST <url> {"inputs":[...]}` with a bare
JSON array of float arrays (nomic-embed-text-v1.5, 768-d), e.g. a fastembed proxy. The reranker (`--rerank`) must answer
`POST <url> {"query":"…","docs":[…]}` with `{"scores":[…]}`. Both accept IPv4 literals only (no hostnames).

## Quickstart

Requires Zig 0.17.

```sh
zig build -Drelease            # -> zig-out/bin/zigmem  (always -Drelease; plain `zig build` is Debug)
zig build test -Drelease       # unit tests (also: test-store test-extract test-phase3 test-api test-panel test-household)
                               # Zig prints nothing on success; add --summary all to see counts. `zig build test` alone does
                               # NOT run the per-module steps above — run each one.

export ZM=~/.zigmem
cat > household.json <<'EOF'
{"members":[{"id":"sam","display":"Sam","role":"principal"}],"seats":[{"name":"sam-laptop","member":"sam"}]}
EOF
zig-out/bin/zigmem household bootstrap --file household.json --home $ZM
zig-out/bin/zigmem token add --seat sam-laptop --scopes '*' --writes --trusted --home $ZM   # prints the seat token
# --trusted matters: without it the privacy screen refuses any capture that mentions family, medical or money
# words ("my husband", "mom", "mg", "salary", a phone number, ...) with HTTP 403. A personal/household seat needs it.
zig-out/bin/zigmem serve --home $ZM --port 8470 --extract none --embed-url none --rerank none --ledger none
```

First write and first query (another shell; `TOK` is the token printed above):

```sh
curl -s http://127.0.0.1:8470/health
curl -s -X POST http://127.0.0.1:8470/v1/capture -H "Authorization: Bearer $TOK" -H 'content-type: application/json' \
  -d '{"user_content":"I switched to oat milk in my coffee.","session_key":"demo"}'
curl -s -X POST http://127.0.0.1:8470/v1/atoms/add -H "Authorization: Bearer $TOK" -H 'content-type: application/json' \
  -d '{"scope":"person:sam","subject":"sam","text":"Prefers oat milk in coffee."}'
curl -s -X POST http://127.0.0.1:8470/v1/search/memories -H "Authorization: Bearer $TOK" -H 'content-type: application/json' \
  -d '{"query":"coffee","limit":5}'
```

The last call returns the atom inside a `<relevant-memories>` block ready to paste into a prompt.
`/v1/search/conversations` searches raw turns the same way. Point `--extract` at a configured engine to have atoms
written for you, and run `zigmem proxy --upstream http://IP:PORT --memory block.txt` to put the frozen block in
front of an engine.

## Layout

```
build.zig / build.zig.zon     Zig build (compiles vendor/sqlite with FTS5)
src/                          proxy, store, extract, retrieve, privacy, household, api, mcp, panel, adapters
adapters/                     client-side snippets written by `zigmem connect`
tests/                        gate scripts and synthetic fixtures used during the build (Python 3 + bash)
deploy/                       user-unit template, release/qualify/rollback scripts
SPEC.md                       the design: every subsystem, its decisions and reasons, and the boundaries
PHASE1..8.md, INTEGRATION.md, RESULT.md   per-phase build receipts (predictions, gates, what was not run and why)
```

## Notes on this export

- All names, addresses, ports and fixture text in this tree are placeholders.
- Several scripts under `tests/` import a Python reference module (`reference_filters`) and bench lanes
  (`bench_lane`, `bench_eval`) that are not included; they document how the gates were measured and will not
  run as-is. The Zig test steps are self-contained.
- The phase documents reference receipt files (`receipts/…`) that are not part of this repository.

## License

Apache License 2.0. See `LICENSE` and `NOTICE`. Copyright 2026 Chad Hurley.
