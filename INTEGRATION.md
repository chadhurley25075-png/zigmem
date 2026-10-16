# zigmem INTEGRATION — one binary: API + MCP + /panel + proxy on the phase-3 retriever/gates and phase-5 household (receipts)

Worker: Claude Code subagent (a Claude model), integration lane, 2026-10-12/13. Base commit `3b0ca58`. Built and tested in an isolated
copy of the tree (`scratch/integ/tree`, so concurrent lanes never saw a half-wired file), then the same hunks committed to the repo.
Binary: always `zig build -Drelease` (Law 8). Synthetic data for gates 1, 2, 4, 5; real family text only in gate 3, on the dev box,
local engines only (embed :8081, reranker 127.0.0.1:18098 — NOT the LAN reranker). Test ports 18180-18199.

## 0. Predictions (written BEFORE any gate run; only unit tests 65/65 and a 2-seat smoke test had run)

| Gate | Prediction | Why / risk |
|---|---|---|
| 1 auth matrix (ported, + 8 new routes ×6 = 247 rows) | GREEN after 0-1 RED | Same checks; identity now token→seat→household. Risk: a phase-4 expectation that leaned on token scopes (admin retire across scopes). |
| 1 bind 14/14 | GREEN first run | parseBind untouched. |
| 1 fuzz 0 crashes | GREEN | New code paths (household routes, gates) are hit with garbage; ReleaseSafe panics would show. Risk: an `.?` on a missing field. |
| 1 latency p95 ≤ 10 ms seq / ≤ 25 ms ×8 @100K | **coin flip on sequential**: p50 4-7 ms, p95 8-14 ms | Per query now: registry load (3 small SELECTs), an xread writer commit (principal reads 2 cross scopes), 40 FTS candidates each loaded + household-gated + medical-gated, firewall/stamp/escape on ≤10 served rows. No network (no vectors → no embed; list mode → no rerank). |
| 1 kill -9 durability | GREEN | Write path unchanged (capture → L0). |
| 1 extract ≤2 in flight | GREEN | Worker unchanged except the household write rule. |
| 2 phase-5 through the API, 0 leaks | GREEN after 1-2 RED rounds, all in harness bookkeeping (expected xread count for get/list) — never a leak | Row gate runs inside recall's row filter; get/list judge rows by their own subject; turns by owner. |
| 2 permission matrix, flows, token cases | GREEN | Policy = phase 5's; token flags can only narrow. |
| 3 family eval 0/93, 130-q ≥ live (re-measured today) | 0/93 likely; **130-q: 118-124 vs live ~124 → risk of RED** | The household row gate withholds personal rows about someone other than the question's target (Alex's seat asking about the home deployment sees Morgan's/kids' personal facts only when the question names them). If the bench store's facts carry member subjects, some answers disappear. Honest either way. |
| 4 panel (ported) + adapters round trip | GREEN after 0-2 harness REDs | Panel uses household scopes now; new seats must be bound in the household. Proxy now needs a seat token per request. |
| 5 mutations ≥ 5 caught | each caught by ≥ 1 gate | Listed in §5. |

## 1. Verdict: SAFETY gates GREEN on one binary; QUALITY gate 3 (130-q ≥ live) RED (119 vs 123), reported, not weakened

Final run: `tests/integration/final_run.sh` (log `receipts/integration/final_run.log`), every gate on ONE build (`zig build -Drelease`, ReleaseSafe):
`zigmem` sha256 `a90f85593926778d81b892afe339789b69650c0245707158d9f6e12a953e3cd1` (also zigmem-gate `0c93c073…`, zigmem-recall `317dc9ab…`,
zigmem-household-gate `9fda6009…`, zigmem-hh-fixture `d8c0a498…`, zigmem-storebench `f637282b…`). Unit tests: 55/55 across 7 steps.

| Gate | Result | Receipt |
|---|---|---|
| 1 auth matrix (ported + 8 new routes) | **PASS 247/247** | `receipts/integration/p4/auth.json` |
| 1 bind refusal (0.0.0.0, LAN, ::, …) | **PASS 14/14** | `p4/bind.json` |
| 1 fuzz | **PASS** 3,228 hostile requests, 0 deaths, 0 panics, /health 200 after, integrity ok | `p4/fuzz.json` |
| 1 p95 @100K atoms | **PASS** sequential p50 2.60 / **p95 6.64** ms; 8 clients p50 3.00 / **p95 7.51** ms @ 2,156 q/s (stub was p95 7.31 / 8.63) | `p4/latency.json` (RED runs kept: `latency_RED_run1.json`) |
| 1 kill -9 durability | **PASS** 44,291 acked captures, 0 missing/altered, integrity ok each round, restart 200 | `p4/crash.json` |
| 1 extraction worker | **PASS** ≤2 engine connections / in flight, 0 other peers, 8/8 jobs | `p4/extract.json` |
| 2 phase-5 THROUGH THE API, real seat tokens | **PASS 0 leaks** in 2,642 judged rows (1,370 questions × search, 1,024 reranked recalls, 96 MCP, 1,584 get-by-id, 18 listings, 216 conversation searches over captured turns); matrix **684/684**; flows **25/25**; token cases **33/33** (forged, byte-flipped, CLI-revoked, unbound seat 403, household-revoked seat/member 403, narrowing token, forged seat header); audit **8,403 xread = 8,403 expected**, 0 question text in audit table or audit.log | `p5/gate.json` |
| 2 phase-5 in-process gate (unchanged harness, integrated tree) | **PASS** 0 leaks / 7,013 rows, 4,921/4,921 useful, 684/684, 25/25, 3,585 = 3,585 | `p5/inprocess_gate.json` |
| 3 family eval through the API | **PASS 0/93 leaks** (live-local: 1/93 — item 77, the known `ticker_shares` line) | `bench/bench_final_leash8s.json` |
| 3 130-q ≥ live (same day) | **RED: zigmem-api 119/130** vs live-local **123/130** vs phase-3 CLI **124/130** (see §3) | `bench/*` |
| 3 phase-3 parity differential on the changed privacy code | **PASS 1,111,926 calls, 0 mismatches** (same 14 runs as phase 3; RED control 746) | `p3diff/` |
| 4 panel (ported) | **PASS** auth 80/80 · csrf 31/31 · xss 15/15 · 390px 26/26 · function 26/26 · secrets 17/17 | `p6/panel.json` |
| 4 adapters round trip (ported) | **PASS 42/42** (40 phase-7 rows + proxy refuses no/wrong token): Claude Code headersHelper at `--scope user`, plain header, pi, proxy codeword PELICAN-4471 (python + curl), Codex/OpenClaw isolated; registrations removed: no zigmem key in any `mcpServers`, no test token in `~/.claude.json`, `~/.claude/settings.json` / `~/.pi` / `~/.codex` / `~/.openclaw` sha256 identical before/after | `p7/*.json` |
| 4 proxy token probe (no engine) | **PASS 6/6**: no/wrong token → 401 and the upstream saw nothing; seat token → block injected, token never forwarded | `p7/proxy_probe.json` |
| 5 mutations | **9/9 CAUGHT** (§5) | `receipts/integration/mutations.json` |
| x86_64-linux-gnu cross build | **builds** (`-Drelease -Dtarget=x86_64-linux-gnu`, 49 s, zigmem sha256 `ee9d8a2c…` at the pre-final tree); not installed or run anywhere | — |

Nothing left running: every server stopped by PID (stops in each receipt), no listener on 18180-18199 after the run.

## 2. What changed (all in `src/`, additive where the old phase code allowed)

- **Identity** (`src/api/access.zig`, new): token → seat → household member/role → readable scopes = household policy ∩ the
  token's scope list (`*` = no narrowing; a token can narrow, never widen). Writes need `w` + token scope + policy; household
  admin needs the `a` flag AND a principal. A seat not bound in the household, or revoked there, → 403 (audited deny).
- **Retrieval** (`src/api/retrieval.zig`, new): the phase-4 BM25 stub is deleted (`retriever.zig` keeps only the hit shapes).
  Search routes and MCP `memory_search` = phase-3 hybrid recall in a new LIST MODE (fused order, no rerank, lazy chunked
  gating); `/recall` and `memory_recall` = the full phase-3 path (rerank, keep 4, fact-fill, the block). The household row gate
  runs as recall's row filter BEFORE the medical gate and any rerank; then phase 3's private-tag drop, medical person-scope
  gate (text + subject column), firewall, strict stamp and escape run on every served row. get/list judge each row by its
  own subject (members only). **Conversation turns** are person-gated by their OWNER (the member of their person/seat scope)
  with the same row gate + phase-3 medical gate (phase 5 left them scope-only). The phase-3 name-only subject filter yields
  to the household resolver when it names exactly one member (tells the two Taylors apart).
- **Read audit** moved to `audit.log` (`xread` + 8-hex query hash per line): writing it to the store made every read commit
  and reset every reader's page cache (p95 17.7 → 6.6 ms). Denials still also go to the store's `audit` table.
- **Writes**: `/v1/atoms/add`, supersede, the panel and the extraction worker all apply phase 5's write rule (medical outside
  its owner's scope or unknown subject → pending_review; medical tag recorded). New `/v1/household/*` routes: whoami,
  promote/request|decide, member/add|revoke, seat/bind|revoke. CLI: `zigmem household bootstrap --file F | list`.
- **Panel**: household scopes + the same by-row gates on every page; an atom's source turn and the queue's turns are
  turn-gated; changing a memory needs household write permission; seats page admin = token admin + principal.
- **Proxy**: every request needs `Authorization: Bearer <seat token>` (consumed, never forwarded); the block is that
  seat's household-scoped, phase-3-gated persona/scene block, cached per seat+session. `--proxy-seat` is gone.
  `adapters/openai/zigmem_client.py` takes `--token-file`; `zigmem connect openai --print` updated.
- **Phase-3 privacy code, performance only, parity re-proven**: regex start-position prefilter (sound first-set) and
  native-stack backtrack frames (`re.zig`); per-fact ledger memo + an ASCII "no fact can hit this line" prefilter
  (`ledger.zig`); weekday / relative-date literal prefilters (`calendar.zig`); escaper inert fast path (`escape.zig`,
  tested == full rewrite on 3,000 generated rows); strict-stamp digit-run prefilter (`strict.zig`, tested == full pass).
- `store.Scope.max` 16 → 64 (a household's readable set is household + every person + every seat).

**Memory ceiling (for phase 8's soak)**: fixed in `src/store/schema.zig`: `cache_size=-65536` (64 MiB page cache per
connection), `mmap_size=134217728` (128 MiB per connection, shared file pages). The hub opens 1 writer + 8 readers + 1 per
extraction worker (≤2) = ≤11 connections → page cache ≤ 704 MiB, mmap ≤ 128 MiB resident. Plus the in-RAM vector
index: rows × 768 × 4 B (≈1.2 GB on the 395K-row bench store; 0 when the store has no vectors), plus 8 per-reader gate
contexts (compiled regexes + parsed ledger, a few MB).

## 3. Gate 3 in detail (RED, honest)

Same day, same box, sequential (`--par 1`) unless noted; reranker the dev box 127.0.0.1:18098 only; "live" = **live-local**:
the live hook code `rerank_lane_plus.py` with its knobs, but `BLEND_RERANK_URL` = the dev box (not the LAN reranker) and
`BLEND_EXTRA_SOURCES=""` (no the cloud store cloud), so family questions never left the dev box. The exact live lane was NOT run.

| Lane | FAMILY | BENCH91 | HISTORY | ALL | family leaks |
|---|---|---|---|---|---|
| zigmem-api, 8 s leash (default for a local reranker) | 84/93 | 14/15 | 21/22 | **119/130** | 0/93 |
| zigmem-api, live 3 s leash | 84/93 | 14/15 | 21/22 | **119/130** | 0/93 |
| zigmem-api, 3 s leash, 4 clients at once | 75/93 | 13/15 | 20/22 | 108/130 (32 reranker timeouts → ≤2-row path) | 0/93 |
| zigmem-api, 8 s leash, 4 clients | 84/93 | 14/15 | 21/22 | 119/130 | 0/93 |
| zigmem-cli (phase-3 CLI, integrated privacy code, no household) | 88/93 | 15/15 | 21/22 | 124/130 | 0/93 |
| live-local | 86/93 | 15/15 | 22/22 | **123/130** | 1/93 (item 77) |

Per-question loss (questions live-local or the CLI answer and the API does not): **22, 28, 42, 60, 78, 99, 113**.
- 22, 42 — **strict rule (resolver)**: the question names one member AND says "I" → "several people" → no target → that
  member's personal/medical rows are withheld (fail closed).
- 78, 99 — **strict rule (resolver)**: one member named plus a pronoun ("her"/"she") → pronoun → no target → withheld.
- 28 — **ranking/gating mix**: the API returns a block (2 KB) without the answering line; the CLI's answering line could not
  be mapped to a single row (not attributed further).
- 60, 113 — **ranking**: neither zigmem lane answers them (live-local only, its own sources).
- Leash: only matters under concurrency (3 s @ 4 clients −11; sequential identical).
The supervisor's principal-exemption ruling (principals see every non-medical personal row) was tested and WITHDRAWN: it
re-opened 2,354 leaks in the in-process gate (and API leaks), all from medical rows the classifier cannot recognise
("[SYNTHETIC] Takes dunavexine at night…") plus mixed lines; kept as mutant `principal_personal_exemption` (caught).

## 4. Predictions vs results
- Auth/bind/fuzz/crash/extract: predicted GREEN → GREEN first run.
- Latency: predicted a coin flip → **RED twice** (17.7 ms p95, then 11.2 after the gate speed-ups), cause found by profiling:
  the per-read xread audit write reset reader page caches; moved to audit.log → 6.6 ms.
- Phase-5 through the API: predicted 1-2 bookkeeping REDs → **1 RED** (a flow: a principal could not find the revoked
  guest's rows — the phase-3 name-only subject filter mapped "Taylor Kessler" to the daughter); fixed by letting the
  household resolver supply the subject; never a leak.
- Gate 3: predicted 118-124 with risk of RED → **119, RED by 4**.
- Panel / adapters: predicted 0-2 harness REDs → panel GREEN first run; adapters 1 RED (harness pointed at the repo's old
  client; plus one run where the live text messaging seat wrote its own `~/.pi` session file mid-run — re-run clean).
- Mutations: predicted all caught → 9/9 (2 needed rewriting because the first patch did not compile; not counted).

## 5. Mutations (each a one-patch copy of the tree, -Drelease, the named gate must exit non-zero)
scope check skipped (p4 auth, p5) · household row filter keeps everything (p5) · seat-name header trusted (p4 auth, p5) ·
turns not person-gated (p5) · token narrowing ignored (p5) · principals exempt from the personal-row rule (p5 API + p5
in-process) · get-by-id ungated (p5) · proxy forwards without a token (proxy probe) · privacy screen off (p4 auth).
All 9 CAUGHT. `tests/integration/mutate.py`; mutant trees deleted after each run.

## 6. Not done, and why
- The exact live lane (the LAN reranker + the cloud store) — would send family questions off the dev box.
- x86 binary not run on the x86 box (build only; phase 8 runs `tests/phase8/x86_build.sh`).
- Vector index is loaded at start: atoms written later are FTS-only until a restart (extraction writes no vectors).
- The extractor's people list (household members) is read when a worker thread starts.
- "today" for the gates is fixed at server start (restart daily, or pass `--today`).
- Gap work on gate 3 (pronoun coreference etc.) follows in a separate commit, time-boxed.

## 7. Gap work (time-boxed, second commit): principal pronoun resolution → gate 3 still RED, 121/130 (+2)

Supervisor 10/13: try to close gate 3 without loosening a gate. Change (`src/household/resolve.zig`): for a PRINCIPAL's
question only, a third-person pronoun resolves to the ONE member the question names (by name; no relative word, no self
word, not two people). Children, guests and shared seats keep the phase-5 fail-closed rule unchanged. Unit tests: the
phase-5 case "Rowan takes her meds…" from morgan-air now resolves to rowan (changed expectation, documented); added: the same
question from a child seat → no target; two names + pronoun → none; self word + pronoun → none.

| Check (gap binary `zigmem` sha256 `4d5c9fa7…`) | Result |
|---|---|
| in-process phase-5 gate | GREEN — 0 leaks / 7,013, 4,921/4,921 useful, 684/684, 25/25, 3,585 = 3,585 |
| phase-5 through the API | GREEN — 0 leaks, matrix/flows/tokens/audit all pass |
| mutations (all 9 re-run on the gap tree) | 9/9 CAUGHT (`receipts/integration/mutations.json`; the pre-gap run kept as `mutations_commit1.json`) |
| p4 auth | 247/247 |
| p4 latency | 1 RED (p95 11.4 / 16.8 ms) then 2 GREEN (7.9 / 9.6 and 8.1 / 9.5 ms) — all three under load average ~14-15 from other lanes' jobs on the dev box; the RED is reported, not discarded |
| panel | all GREEN |
| bench through the API (8 s leash, sequential) | **121/130** (FAMILY 85/93, BENCH91 15/15, HISTORY 21/22), 0/93 family leaks — vs live-local 123/130 |

Remaining gap (2 vs live-local): 22 and 42 ("I" + one named member → several people). Resolving them would also resolve
"is Alex's dose higher than mine" from Morgan's seat to Alex, which the phase-5 oracle scores as a LEAK (its ground truth for
that question is "no single person") — so not done. 28 (unattributed), 60, 113 (ranking; live-only sources). Stopped here
per the time box.
