# zigmem PHASE 5 — household (team/shared) memory (receipts)

Worker: Claude Code subagent (a Claude model), 2026-10-12. Scope: `src/household/` (new), an additive phase-5 block in
`build.zig`, this file, `receipts/phase5/`. Phase 0–4 and the running phase-3/6 lanes untouched (no `src/api`, `src/main.zig`
edit was needed). All data SYNTHETIC: invented drug names, colours and notes under our family names, labelled `[SYNTHETIC]`,
written only to throwaway SQLite files under `scratch/p5/` and `.zig-cache/tmp/` — never a live store, never an engine.

## 0. Predictions (written BEFORE the first gate run; only `zig build test-household` 7/7 had run)

| Gate item | Prediction | Why / risk |
|---|---|---|
| Adversarial suite (9 seats × ~68 questions × 2 phases, real search + scope-blind rows) | **0 leaks** first run. ≥ 200 queries (expect ~1,200). | Scope comes only from policy; the row gate re-checks scope, status and the medical subject column even on rows from a scope-blind list. Risk: the classifier missing a synthetic drug name, or resolver edge cases (contractions, "mine"). |
| Usefulness (no over-blocking) | 1–3 RED rounds likely: some legitimate own-medical or plain row not served (fixture/oracle disagreement or a resolver miss), fixed without loosening a leak rule. | The oracle is strict both ways. |
| Permission matrix (9 seats × 18 scopes × read/write + admin + principal-revoke cells, before and after revocation) | GREEN 100 %. | Literal oracle table vs policy.zig; both small. |
| Audit: one `xread` row per cross-scope read, no query text | GREEN, exact count. | Risk: miscounting my own expected number (matrix + flow reads). |
| Promotion / admin flows | GREEN. | |
| Broken builds caught | Each of ~8 single-line mutations (kid reads sibling, medical gate off, pronoun defaults to asker, revocation ignored, audit skipped, household writable, ambiguity ignored, subject column ignored) → gate exit 1; most also fail a unit test. | A mutation the gate misses = a hole in the suite → add a case, never weaken. |

## 1. Verdict: PHASE 5 GATE **PASS** (every item GREEN on the final binary; 3 RED gate runs on the way, explained in §2)

Final: `zig build household-gate -Drelease` → `zigmem-household-gate` sha256 `3d97fdfb02374d1430f08819617f6a4123374bc6d8a5ad2413fc4f4a539a99d3`;
`zig build test-household` 7/7 (`-Drelease` and Debug). Gate re-run on a fresh DB after the last code change: `receipts/phase5/gate_final.json`.

| Gate item | Result | Receipt |
|---|---|---|
| ≥ 200 adversarial queries, 0 cross-person leaks | **PASS: 1,370 questions** (9 seats × ~76, two phases: before and after live revocation), each run twice: the real scoped search (A) and a **scope-blind** list of every row in the file (B, a broken/future retriever) → **7,013 served rows judged, 0 leaks**. Traps: "what meds does Morgan take" from every kid seat; bare "Taylor" (daughter vs the guest Taylor Kessler) vs "Taylor Harper"/"Tay"/"Taylor Kessler"/"Taylor K"; he/she/her/they; "my mom"/"dad" (resolve only from a child seat; Alex's "mom" is not a member), "my wife"/"my husband"; "my sister", "grandma", who/whose/everyone; two people in one question; mis-attributed rows ("Morgan takes…" stored under Jordan; "Mom takes…" in Rowan's scope with subject Morgan; "User has oral surgery" with subject unknown; "Quinn and Jordan both take…"); an outsider "Taylor from work"; household-scope medical rows; an unknown `work` scope; retired/pending rows; 187 forged scope requests (all refused, audited); a revoked member (the guest) and a revoked seat (285 denials, 0 rows). Leak oracle = per-row ground truth (who the fact is really about, medical or not) + a literal per-seat scope table (`oracle.zig`), sharing no code with the gates. | `gate_final.json` |
| Usefulness (not a stated gate item, held to 100 % anyway) | 4,921 legitimate (seat, question, row) expectations, **0 missed medical, 0 over-blocked plain**. | same |
| Permission matrix | **PASS 684/684**: 9 seats × 18 scopes × {read, write} + admin + "revoke a principal" cells, before and after revocation. | same |
| Promotion / admin flows | **PASS 25/25**. | same |
| Audit | **PASS**: 3,585 `xread` rows = 3,585 expected (one per cross-scope scope searched, computed by the oracle); **0 audit rows contain query text** (scope + 8-hex query hash only). Denials audited (`deny`). | same |
| A deliberately broken build is caught | **PASS 19/19** single-line mutations, each on a scratch copy, each compiling, each makes the gate exit 1 (most also fail a unit test). | `mutations.jsonl`, `mutations_round2.jsonl`, `mutate.sh`, `mutate2.sh` |

Mutations (gate leaks / matrix fails / flow fails): kid reads sibling 5037/148/1 · medical gate off 1842 · pronoun defaults to asker 398 · member revocation ignored 176/4 · seat revocation ignored 298/5 (unit tests pass; only the gate sees it) · cross-scope audit skipped (0 leaks, audit count RED) · household writable 441/16/1 · ambiguity ignored 285 · subject column ignored 538 · "text names someone else" ignored 128 (unit tests pass) · personal-row rule off 3241 · per-row scope re-check off 2975 (only scope-blind mode B finds it) · inactive rows served 263 · guest reads household 131/1/1 · child may approve promotion 102/0/4 · principal revocable 265/41/9 · medical promotable 0/0/2 · requested scopes unchecked 171/171/1 · classifier blind 1876/0/3. Round 1 had 3 mutants that did not compile (rc 99: unused constant/parameter, error-set change); they were **not** counted, were rewritten as compiling mutants (round 2), all caught.

## 2. Predictions vs results

- Leaks: predicted 0 on the first run → **RED, 3,241 leaks** (`gate_run1.json`). Cause: synthetic drugs ending "-vexine" with no cue word and no tag ("Takes dunavexine at night to help with sleep") are invisible to the classifier, so they were served as plain rows for questions about someone else. Fixed in code, fixture untouched: **every row whose subject is a household member is a personal row and answers only a question about that member**, so a classifier miss can no longer cross people. Run 2: 75 leaks: "Quinn and Jordan both take quorvexine" (subject Quinn, no cue) served to Quinn; fix: a personal line that names anyone else is withheld like a medical one. Run 3+: 0 leaks.
- Usefulness: predicted 1–3 RED rounds → 2. Run 2: 38 misses = Morgan's medical seat note in her own seat scope was demoted to pending_review (rule too strict) → medical rows are live in `person:<subject>` or a seat bound to that subject. Run 3: 555 "over-blocks" = matrix probe rows whose text says "wrote seat:morgan-air" (names Morgan); the code was right to withhold them, so the oracle's usefulness expectation was updated to the documented rule with an independent substring check (it can only make the oracle expect less; no leak rule touched). Run 4 + final: green.
- Matrix, audit, flows: predicted GREEN; GREEN from run 1.
- Broken builds: predicted ~8 caught; ran 19, all caught. Surprise: 5 mutants pass the unit tests (seat revocation, text-names-other, scope re-check, inactive rows, medical promotion); only the gate sees them.

## 3. What was built (`src/household/`, Zig, every file ≤ 600 lines with a `//!` header)

| File | What |
|---|---|
| `policy.zig` | Roles `principal` (Alex, Morgan: full and equal authority), `child`, `guest`; seats bound to a member or shared (kitchen). Scopes `household`, `person:<id>`, `seat:<name>`; anything else unreadable. Read: principals everything known; child/guest own person + own seat (+ household, not for guests); a shared seat household + itself. Write: never `household` (promotion only, principals included); own person/seat; principals any person/seat. `isCross` for audit. Seat → actor refuses revoked seats and seats of revoked members. |
| `resolve.zig` | Who a question is about: names/display/aliases with longest match ("Taylor" inside "Taylor Kessler"), ambiguous spans kept as candidate sets; asker-relative words (mom/dad only from a child seat, wife/husband only from the matching principal); pronouns, group words, unresolved relatives, two people, self + someone else → **no target** (fail closed). A question naming nobody is about the asker (or the one person scope the request narrowed to). |
| `medical.zig` | Cue words, dose units ("20mg"), INN drug suffixes; biased to "medical". A writer can mark a row medical, never unmark one. |
| `house.zig` | The layer over the store. Registry read live on every call (revocation takes effect on the next request). `recall`: scopes only from policy (requested ⊆ readable, else Forbidden + audit), one `xread` audit row per cross scope, store search chunked to the store's 16-scope limit, then the row gate. **Row gate** (also run on scope-blind lists): active only; scope readable; medical rows only for the one target person, subject column = target, the seat may read `person:<target>`, the line names no one else; every other personal row only when the question is about its subject and the line names no one else. `write`: a medical row outside its own person/seat scope, or an unknown subject ("User"), lands `pending_review`. Promotion: request (owner, non-medical, active) → a principal approves (new household atom, original untouched) or refuses; one-shot. Members/seats: principals add/bind/revoke; a member may revoke their own seat; **principals cannot be revoked through the API** (neither can lock the other out). `personas`: readable scopes; a medical-looking persona only for its own subject. |
| `schema.zig` | `hh_members`, `hh_seats`, `hh_tags` (medical flag per atom), `hh_promotions` beside the phase-1 schema (own `meta` key). Triggers: no DELETE on any, revocations permanent, tags immutable. |
| `fixture.zig` | SYNTHETIC household (7 members incl. the guest Taylor Kessler, 9 seats) with per-row ground truth. |
| `oracle.zig` | Literal per-seat read/write table + question generator with ground-truth targets. |
| `gate.zig` | `zigmem-household-gate --db NEW_FILE`. |
| `tests.zig`, `root.zig` | 7 unit tests (policy, resolver traps, ambiguous row names, store-backed kid-vs-Morgan + live revocation + audit, no `DELETE FROM` in household code). |

`build.zig` (additive): phase-5 block, own store module instance, `zig build test-household`, `zig build household-gate`.

## 4. Token → seat → household (wiring note for the supervisor)

The phase-4 token file binds a token to a **seat name**; the household layer takes only that verified seat name and derives
member, role and scopes from `hh_seats`/`hh_members` live (the token file's own `scopes` column is not trusted for household
reads). To wire: in `rest.zig`'s `search`, call `House.recall(a, c.seat.name, q.text, .{ .requested = ... })` (or run
`House.gate` over phase 3's rows), route seat writes through `House.write`, and add `zigmem household bootstrap|member|seat`
verbs over `House.bootstrap/addMember/bindSeat/revokeSeat/revokeMember`. Not done here: the phase-6 lane had uncommitted
edits in `src/api/cli.zig`, `src/api/http.zig` and `src/main.zig` while this lane worked. After wiring, re-run the phase-4
auth matrix and this gate.

## 5. Not run, and why

- **HTTP/MCP end-to-end with a real token**: not wired (§4). The gate drives `House` in-process by seat name.
- **L0 conversation turns**: household gating covers atoms; turns carry no subject column. They stay scope-limited by the store but are not person-gated.
- **Phase-3 privacy gates (ledger, regex medscope)**: not composed (their lane is running). The household column rule can run before them.
- **Real family data, engines, network**: none. Synthetic only, no LLM.
- **x86_64 (the x86 box) build**: not run.

## 6. Known limits

1. A personal row answers only a question about its subject, so a vague question ("what does she like") gets household rows only. Fail-closed by design.
2. A shared seat (kitchen) never gets medical or personal rows.
3. `hh_members` is separate from phase 1's `people` table; merging is later cleanup.
4. Relative words resolve only through the two principals flagged `relation=mother|father`; anything else is unresolved → no target.

Nothing of this lane is running: the gate is a one-shot process; no server, port, cron or service was started. Scratch
`scratch/p5/` holds the synthetic `final.db` and mutation logs; mutation tree copies were deleted.
