# zigmem PHASE 3 — retrieval + the privacy gates (receipts)

Worker: Claude Code subagent (a Claude model), 2026-10-12. Scope: `src/privacy/`, `src/retrieve/`, `src/phase3_test.zig`, `tests/phase3/`,
`receipts/phase3/`, an additive block in `build.zig`, this file. Phase 2 (`src/extract/`, PHASE2.md) untouched. Python references read-only.

## 0. Predictions (written BEFORE any phase-3 code — 18:05)

| Gate | Prediction | Why |
|---|---|---|
| (a) differential, Zig gates vs Python on thousands of lines | GREEN after 2–4 RED rounds. First-run mismatches expected in: Unicode case folding / \\w tables, Python round-half-even in money_tokens_k, str.lower() length changes (U+0130), lookbehind in _CLAUSE_RE, re.split edge cases (empty pieces), and the weekday/yearless calendar notes. | Zig has no regex; I am writing a Python-sre-compatible backtracking engine (codepoints, IGNORECASE, DOTALL, lookarounds) so the patterns are copied VERBATIM rather than re-expressed — the mismatch surface becomes the engine, testable on its own. |
| (b) family eval through the Zig gates: 0/93 leaks | GREEN (0/93). | Zig retrieval + Zig ledger_scrub + Zig medscope; same CORRECTION/dead_hits metric imported from the eval. Risk: zigmem retrieval surfaces a dead value the Python lanes never saw, in a phrasing the ledger cannot stamp (no dead_keywords match) — that would be a REAL leak, reported, not hidden. |
| (c) 130-q bench: zigmem retrieval vs the reranked lane control | FALL SHORT by ~5–15 hits on first run (control ~120/130). | Same sources + same reranker, but no focus windowing, no source cap, no fact-fill, no date-window search, and nomic+BM25 RRF over one mixed store instead of 4 tuned engines. Honest report either way. |
| reranker-down run | ≤ 2 rows, every time. | Coded as a hard rule. |
| Lines | ~2,000–2,600 Zig (regex engine ~600 of it). | SPEC row: 1,700. The regex engine is the overrun. |

### Prediction for the first bench run (19:10, written before it ran)
Store = 395,763 rows from journal+synth+vault+facts+notes (no agi/osmem: their live lane passes rows through a per-question privacy gate
that is not ported; no the cloud store extras: cloud, fallback-only). Expect: zigmem 105–120/130 vs live ~120–125; family leaks 0/93 for
zigmem (firewall stamps dead values the same way); zigmem-down ≤ 2 rows every question and well under 100/130; zigmem-wide (24 rows,
every candidate through the gates) 0 leaks or a handful the ledger cannot see (reported, not hidden).

### Run 1 → finding → prediction for run 2 (19:35)
Run 1: zigmem 124/130 = live 124/130 (same-sources 122); family leaks: zigmem 1/93, live 1/93, same-sources 1/93 — the SAME line in all three
(item 77, a fact-fill row). Root cause (structural check, no text printed): ledger fact ticker_shares has 51 dead phrasings and no
derivable dead_core, so a bare dead share count in a new phrasing is never stamped. Python and Zig agree (faithful port), so the live
lane leaks it today. Fix in zigmem (not in the parity gates): privacy/strict.zig screens OPTIONAL fill rows stricter than the firewall.
Prediction run 2: zigmem 0/93 family leaks, 123–124/130; zigmem-lenient reproduces the 1/93; live/same unchanged (1/93).

### Run 2 → change → prediction for run 3 (19:50)
Run 2: zigmem 0/93 leaks but 123/130 (live 124): dropping the row also dropped the answer it carried. House law is annotate, never
delete, so strict.zig now STAMPS such lines (same note as the firewall) in a second pass after ledger_scrub, and the fill screen is
back to blend parity (ledger_reject + dead $K). Prediction run 3: zigmem 124/130 (= live) with 0/93 leaks; zigmem-lenient
(= exactly the live gates) 124 with 1/93; down/wide unchanged.


## 1. Verdict (20:05)

| Gate | Result | Receipt |
|---|---|---|
| (a) differential, Zig vs Python gates | **PASS. 1,111,926 calls over 14 runs (59,518 generated + real-shaped lines; synthetic, malformed and REAL ledger; 114 queries incl. the 93 family-eval questions): 0 mismatches.** One listed divergence class, 1144 cases, all in `private_line`: tags spelled `<prıvate>`/`<prİvate>` that the Python FAST PATH lets through (`"rivate" not in line.lower()` misses U+0131/U+0130 although its own regex matches them). The Zig strips them (stricter, never looser). Every case is listed in `diff_*_mismatches.jsonl`. RED control (Zig given a wrong date + self-echo off) goes red (746 mismatches). Coverage: every op has hundreds of non-trivial results. | `receipts/phase3/diff_*.json` |
| (b) family eval through the Zig gates | **PASS: 0/93 leaks** (run 3; metric = `family_memory_eval.dead_hits`, imported). The live family eval (its own lanes) today: 0/93, safety 63/65. In the bench the live the reranked lane lane leaks **1/93** (item 77, see section 2); zigmem runs 1 and 2 showed the same leak, fixed in run 3. Stress lane (24 rows, every candidate through the gates): 0/93. | `bench_run1..3.json`, `scratch/p3/live_family_eval.txt` |
| (c) 130-q bench vs the reranked lane | **PASS (tie): zigmem 124/130 vs live 124/130** (FAMILY 88/93 vs 87/93, BENCH91 15/15 vs 15/15, HISTORY 21/22 vs 22/22); 3 questions each way. Same-sources blend control: 122/130 (run 2). zigmem p50 241 ms/query in one process vs live 1828 ms (subprocess per question incl. Python start-up: not a like-for-like latency claim). | `bench_run3.json` |
| reranker-down run | **PASS: at most 2 rows on all 130** (35 inject nothing); 79/130, 0 leaks. Defined path: only rows BOTH engines found, cosine >= 0.60, fused >= 0.60. | `bench_run3.json` lane zigmem-down |
| forged-scope fuzz | **PASS: 500 random queries (forged scope words, header names, SQL-ish text) x 3 seat scopes, 0 rows outside the seat's scope.** Scope is a typed argument, never read from the query. | `unit_GREEN.txt` |
| unit tests | **10/10** (`zig build test-phase3`) | `unit_GREEN.txt` |

## 2. Predictions vs results (receipt-style)
- (a) Predicted 2-4 RED rounds; got **0 mismatches on the first run** apart from the Python fast-path class (unpredicted: a second
  `private_line` leak beside the mixed-case one phase 1 found). Why so clean: the engine reproduces sre (code points, sre's own
  IGNORECASE classes generated from `_sre.unicode_tolower` + `_EXTRA_CASES`, Unicode word/digit/space tables generated from this
  Python), and every pattern is read from the live module by `gen_patterns.py`, so nothing was hand-transcribed.
- (b) Predicted 0/93 first time; **wrong**: run 1 = 1/93, the same line the live lane leaks. Ledger fact `ticker_shares` has 51 dead
  phrasings and no number shared by all of them, so `_dead_core` is empty and a bare dead count in a new phrasing is never stamped
  (structural check only; no family text printed). Run 2 dropped such optional rows: 0/93 but 123/130 (the dropped row carried the
  answer). Run 3 STAMPS instead (annotate, never delete): `privacy/strict.zig`, a zigmem-only second pass after the firewall,
  documented as outside the parity set; it added 2 stamps on 2 of 130 questions. Off = `--no-strict` (= exactly the live gates, 1/93).
- (c) Predicted 5-15 short; **wrong, it tied** (124 = 124). One store + RRF + the same reranker + ports of blend's focus, fact-fill,
  dedup and source cap carry it.
- Reranker-down: predicted at most 2 rows; got it.

## 3. What was built (4,213 Zig lines + 57 generated; every file under 600 lines)
- `privacy/re.zig` + `re_compile.zig`: Python-sre-compatible backtracking engine over code points (classes, lazy/greedy quantifiers,
  word boundaries, look-ahead, fixed-width look-behind, IGNORECASE via sre equivalence classes, DOTALL). The gates use the Python
  patterns verbatim (SPEC risk #2: glibc ERE would have needed every pattern re-expressed).
- `privacy/unitab.zig`, `patterns.zig`: GENERATED from this Python (`tests/phase3/gen_unitab.py`, `gen_patterns.py`; the reference
  file's sha is stamped in). Regenerate when the Python changes; the differential test catches drift.
- `privacy/ledger.zig` + `calendar.zig`: ledger_scrub, ledger_reject, ledger_lines, weekday_check, resolve_relative, money_tokens_k,
  with Python exception semantics modelled (error.Py caught exactly where the Python catches). `echo.zig`: is_self_echo, dated,
  transcript, tool-log, rejection_reason, is_machine_traffic. `medscope.zig`: named_family, medical_cross_person / mixed_others /
  subject_gate + the subject-COLUMN check. `escape.zig` (add-on #4): template tokens, role headers, override phrasing, block marker.
  `strict.zig` (section 2).
- `retrieve/`: `recall.zig` (scope + subject filtered FTS5 and vectors, RRF k=60, per-engine minimum + fused floor, medical gate on
  text + column, rerank the LAN reranker then the dev box with blend's leash, dedup, source cap, fact-fill, escape, firewall, strict pass);
  `util.zig` (focus, date_window, cite ages, Jaccard); `http.zig` (connect/read leash); `embed.zig` (:8081 proxy at query time; Ollama
  format for the bulk import, same nomic weights, cosine 0.9999996); `rerank.zig`; `rrf.zig`; `block.zig` (SPEC §3.6 frozen block,
  `Frozen.blockFn` fits `proxy.MemorySource`); `load.zig` + `cli.zig` (`zigmem-recall load|query|block|stats`).
- Bench store: `scratch/p3/zm.db` (395,763 rows: journal 81,056, facts 250,964, vault 41,257, synth 18,906, notes 3,580; 2.4 GB;
  the dev box only, 0700 dir), exported read-only by `tests/phase3/export_sources.py` with the live lanes' own cleaning.

## 4. For the supervisor / Alex
1. **Live leak, today:** the the reranked lane lane serves an unstamped dead share count on bench item 77. Fix = add an explicit
   `dead_core` to ledger fact `ticker_shares` (the ledger already supports the field). Not done here: the ledger is live memory.
2. **Second Python `private_line` leak:** `<prıvate>`/`<prİvate>` pass the fast path. Fix = drop the fast path, or also test for
   U+0131/U+0130. The Zig already strips them.
3. zigmem does NOT import the agi-graph or os-memory sources: their live lane filters rows with a per-question privacy gate
   (`hindsight_gate.privacy_reason`) that is not ported. Port it before those sources come in.
4. House gates (family names, ledger schema) are compiled in; the `-Dhouse` split for the public tree is phase 8.

## 5. Not run, and why
- x86_64 (the x86 box) build: not assigned this phase; nothing architecture-specific in the new code.
- No the primary engine / secondary traffic: phase 3 needs no LLM, so no rewarm was needed.
- the cloud store extras and the agi/osmem sources: see section 4.3. The live control keeps them and still only ties.
- Frozen block with REAL personas: the import has no persona/scene rows yet (phase 2 writes them). Tested on synthetic personas:
  byte-identical within a session and across a restart; a new session sees the new revision.
- Nothing left running: the loader, evals and benches were run by hand and have exited. No services, crons, hooks or seat changes.
