# zigmem PHASE 8 — shadow run + deploy kit (receipts)

Worker: Claude Code subagent (a Claude model), 10/12 22:59 → 10/13. Scope: `deploy/`, `tests/phase8/`, `receipts/phase8/`, this file,
`scratch/p8*`. Nothing under `src/` or `build.zig` touched. Nothing switched live. Predictions: `receipts/phase8/PREDICTIONS.md`.
(The session was suspended ~00:00→08:00; work resumed at 08:00 with the import already finished.)

## 0. Verdict

**Deploy kit: GREEN.** **Release: NOT stamped. `deploy.sh` refuses until a candidate passes every gate.**
The integration commit (phase-3 retriever + phase-5 household wired into the hub) had not landed by 04:30, or by the time this
was written. The newest green commit is 3b0ca58. Its hub still serves the phase-4 FtsStub, and that stub fails the shadow
leak gate. The real retriever from the same commit passes when run standalone.

| Gate | Result | Receipt |
|---|---|---|
| deploy + rollback round trip, sha-identical | **GREEN 24/24**, both unseeded and seeded with the real 2.4 GB store. Six RED preflight cases each refuse and leave the home untouched: port busy, sha mismatch, missing gate receipt, tested-sha mismatch, not built `-Drelease`, service dies on start (auto-rollback). Guarded files (`~/.claude.json`, `~/.claude/settings.json`, `~/.pi`, `~/.codex`, `~/.openclaw`, `~/.config/systemd/user`) are sha-identical after rollback. The whole scratch HOME is sha-identical apart from the documented leftovers. | `roundtrip_testrel_run3.json`, `roundtrip_e912_seeded_testrel.json` (RED history: `roundtrip_run2.json`) |
| shadow: 0 leaks, all sets | **zigcli (phase-3 retriever) GREEN:** 0/93 family, 0/37 other bench, 0/300 seat. **Hub (FtsStub) RED:** 1/93 family, 23/300 seat. **Live lane:** 1/93 family (item 77) and 2/300 seat. | `shadow_bench_e912.json` |
| shadow 130-q ≥ live, same night | **zigcli GREEN: 124 = 124.** **Hub RED: 103 < 124.** | same |
| soak: 0 acked rows lost across a process crash (kill -9), no crash, no leak | **GREEN on 0 lost / no crash / kill -9 (0.25 s restart).** The old cold-start RSS ratio is RED; the receipt is kept and §3a explains why it misleads. The new LEAK gate is defined in §3a and runs from qualify on the integration binary. | `soak_e912.json` |
| nothing left running | **GREEN.** Every test hub was stopped by PID and :18190/18191/18192/18199 are closed. No unit was installed on the dev box or the x86 box. | — |

## 1. Shadow import (same sources + exclusions as phase 3)
`tests/phase8/shadow_import.sh`: `tests/phase3/export_sources.py` (journal/synth/vault/facts, run through the live lanes' own
cleaning, with reader_rejects applied) plus `tests/phase8/export_notes.py` (NOTES·TV). Local nomic embeddings via Ollama, as in
phase 3. Loaded into `scratch/p8/shadow/zigmem.db`.
**395,789 rows** (journal 81,082 · facts 250,964 with 105 rejected · vault 41,257 · synth 18,906 · notes 3,580), 0 embed failures,
23:13→23:58. Seed sha256 `56e5a889…c849`. Dir 0700. The text never left the dev box.

## 2. Shadow bench (sequential, one request at a time; tonight, 10/13 08:10)
Sets: the 130-q bench (FAMILY 93 with dead values, BENCH91 15, HISTORY 22) imported from `bench.py`, plus 300 real seat
prompts. The seat prompts are the newest Claude Code main-session user turns on the dev box (10/08 → 10/13), run through
`strip_private` (fail-closed), `is_machine_traffic`, command/system-tag filters, length 15–1500 and dedup
(`tests/phase8/seat_prompts.py`, counts only).
Live lane = the exact UserPromptSubmit command, read from `~/.claude/settings.json` at run time (`rerank_lane_plus.py` with its
flags).

| lane | 130-q | FAMILY | BENCH91 | HISTORY | leaks (bench / seat*) | p50 / p95 ms (bench, seat) | avg block chars (bench, seat) |
|---|---|---|---|---|---|---|---|
| live the reranked lane | 124 | 87 | 15 | 22 | 1 / 2 | 842–882 / ≤1,240 · 950 / 2,146 | ~1,960 · 2,239 |
| zigcli (phase-3 retriever, tonight's store) | **124** | 88 | 15 | 21 | **0 / 0** | 242–291 / ≤338 · 288 / 448 | ~1,800 · 1,832 |
| zigmem hub, HTTP (FtsStub in 3b0ca58) | 103 | 74 | 12 | 17 | 1 / 23 | 40–56 / ≤106 · 68 / 126 | ~3,600 · 5,123 |

\* Seat leaks are counted with the ledger's own 170 `dead_keywords` through `family_memory_eval.dead_hits`, plus `<private` tags
and zigmem tokens (`tests/phase8/rescore_seat.py`). My first screen used the union of the 93 items' dead answers. That union
includes non-ledger answers such as "do not have|don't have", which match ordinary prose, so the screen produced false
positives. It is kept as a RED receipt: `shadow_bench_e912_v1_unionmetric_RED.json`.
Seat prompts with any block: live 281/300, zigcli 268/300, hub 300/300 (the stub always returns something).
Latency is not like-for-like across lanes. Live pays a Python subprocess per prompt, as a real seat does. zigcli is one
process for all prompts. The hub is an HTTP call to a warm process.

## 3. Soak (hub = deploy/release/zigmem e912f9b0…, a copy of the shadow store, 127.0.0.1:18192, 2 h, kill -9 at 60 min)
**Process-crash durability GREEN** (an acked write survives a process crash; a power loss may drop the last commits, never corrupts; ruling BOARD 10/13 ~15:25), **RSS gate RED (by the metric I set in advance).** Over 7,200 s: **14,356 acknowledged captures, 0 missing
or altered**, `integrity_check ok`, 0 write errors, 1,417 recalls with 0 errors (p50 89 ms), and `/health` 200 at all 240
samples. kill -9 at 3,605 s: the old PID was gone, and the restart on the same files took **0.25 s** with nothing lost. At the end
it was stopped by SIGTERM and nothing was listening on :18192.
**RSS: RED.** I predicted late/early ≤ 1.10. Life 1 went 38 → 70 MB (spike to 204), ratio 1.83. Life 2 went 69 → 194 MB,
ratio 2.80. Max 334 MB. The growth comes in **steps with plateaus and some drops** (204 → 70, 69 → 43); it does not climb
steadily. The likely cause is in the store config (`schema.zig:9`): `cache_size=-65536` (64 MiB of SQLite page cache per
connection) × 9 connections (1 writer + 8 readers), plus `mmap_size` 128 MiB. Each reader's cache fills in turn as it touches
new pages, which puts a ceiling of roughly 0.7 GB on it. My prediction ("≤ 200 MB, flat") was wrong because I did not model
this. The gate stays as written, so the receipt says RED. Whether "bounded by config" counts as stable is the supervisor's
call, and it will come up again on the integration binary, whose vector index adds about 1.2 GB on top.

### 3a. Memory: old check vs new leak gate (supervisor ruling 10/13 ~10:30)
The old ≤ 1.10× receipt stays exactly as it was, **RED**. It was measured from a cold start, so it counts cache warm-up as
growth. qualify now uses the LEAK gate (`tests/phase8/soak.py`; the ceiling is written to `soak_<tag>.pre.json` before the
workload; prediction P5).
| | OLD memory check (kept as is, **RED**) | NEW leak gate (what qualify uses now) |
|---|---|---|
| Question | "late RSS ≤ 1.10 × early RSS" | "is memory unbounded, i.e. a leak?" |
| How | median of minutes 10–25 vs the last 15 min of each process life | (1) a ceiling computed from the binary's real settings and written down **before** the run: start RSS + connections × (SQLite cache + mmap) + the search index + HTTP buffers; RSS may never exceed it. (2) The last 60 min of a ≥ 2 h soak must have a fitted slope ≤ 1 MB/h. (3) After the kill -9, the restart stays within the ceiling. |
| Note | Measured from a cold start, so it counts cache warm-up as growth. | A plateau test. qualify soaks for **3 h with the kill -9 at 30 min**, so the last-60-min window starts 90 min after the restart. One-sample spikes stay in the data: no filtering, no smoothing. If the slope fails only because of spikes, it is reported RED with the raw series (`leak.last60_series_t_s_rss_mb` in the receipt). |
| e912 (3b0ca58) | RED: 38 → 70 MB and 69 → 194 MB (ratio 1.83 / 2.80), max 334 MB. Receipt `soak_e912.json` | Informational retrospective only, not a gate run, because that soak killed at 60 min so its last hour was a cold restart. Ceiling 1,799 MB ✓, restart ✓, slope 210 MB/h ✗. Receipt `soak_e912_leak_retrospective.json` |
| Integration binary | — | First real run comes from `qualify.sh`. Its ceiling includes the index: ≈ 395,789 × 3 KB ≈ 1.2 GB. |
Code smoke of the new gate (180 s, `soak_smoke_leakgate.json`, not a gate run): ceiling 1,798 MB written before the workload,
with 9 connections measured on the live pid. The run correctly fails `soak_at_least_2h`.

## 3b. Supervisor ruling (10/13 ~09:30): the preflight is split
`deploy.sh` (shadow) requires every SAFETY gate: leaks, auth, bind, fuzz, kill -9, soak and the round trip. Gate 3 (hub 130-q
≥ live) is printed as a WARNING there. `deploy.sh --wire` also requires gate 3, and when it is RED it refuses and names the gap.
The receipts are unchanged; the split lives in `zm_kit.split_gates`. `build_release.sh stamp` requires the safety gates and
records gate 3 under `quality`. `tests/phase8/p4_safety.py` re-runs the phase-4 auth/bind/fuzz/crash gates on the exact
candidate binary, writing to separate receipt dirs. The round trip, including RT3 (a gate-3-RED release: shadow deploy goes
ahead with the warning, `--wire` refuses with "gap 4"), is **28/28** (`roundtrip_testrel_run5_split.json`).

## 4. Deploy kit (`deploy/`)
- `zigmem.service`: systemd **user** unit template. 127.0.0.1:8470, `--extract none`, `Restart=on-failure`, `UMask=0077`,
  `NoNewPrivileges`. Staged only; it is never enabled here.
- `deploy.sh`: preflight, then act, then health check, then the "what changed" printout. Covered in DEPLOY.md.
  `--dry-run`, `--wire <seat>` (prints only) and `--wire claude-code --apply` (recorded in the manifest).
- `rollback.sh`: undoes exactly what the manifest records, then verifies the pre-deploy sha.
- `zm_kit.py`: snapshots, compare (whole files, whole trees, and per-key hashes of `~/.claude.json`), release-check, manifest.
- `build_release.sh`: builds from `git archive <commit>` (never the working tree) with `-Drelease`, then stamps the release
  with `tested_sha256`, the gate receipts and the seed sha.
- `qualify.sh <commit>`: the whole pipeline for a new commit (build, homes, shadow bench, soak, stamp, seeded round trip,
  stamp, install as `deploy/release`). It stops at the first RED.
- `DEPLOY.md`: the one page for Alex.
- **Build is not bit-reproducible:** three `-Drelease` builds of 3b0ca58 gave three different shas (b8e9…, 878a…, e912…).
  Every gate is therefore bound to the exact file in the release dir, never to "the commit".

## 5. Not run, and why / nothing left running
- **Integration commit:** not landed, so the hub path could not be qualified. Run `deploy/qualify.sh <commit>` when it lands.
- **the inference server sidecar (C): not run.** the Mac box (192.0.2.3) answers on none of the usual engine ports (read-only curl), and
  `a process listing` shows no the local inference server/oMLX process. inference-server dirs exist on disk (`inference-server-066`, `-native`, `-serve`). BOARD
  law: no the Mac box, start nothing. The ABBA TTFT gate needs a the inference server serve that someone else brings up.
- **x86 for the x86 box (D): GREEN on 3b0ca58.** Cross-compiled on the dev box (`-Drelease -Dtarget=x86_64-linux-gnu`), copied to the x86 box
  `~/zigmem_x86/3b0ca58d8c82/`. 9/9 unit-test executables pass on the x86 box (85 tests). The 127.0.0.1:18199 smoke passed: health,
  capture, search, 401 without a token, 0.0.0.0 refused with no home created. Stopped by PID; nothing listening afterwards.
  No unit was installed on the x86 box. Receipt `x86_hq_3b0ca58.txt`. The integration commit needs its own x86 build
  (`tests/phase8/x86_build.sh <commit>` on the dev box, then `~/zigmem_x86/x86_run.sh <dir>` on the x86 box).
- **Proxy-mode token, public generic tree, a foreign-store importer, doctor** (SPEC phase-8 row): not built. The scope was the shadow
  run and the deploy kit, and those features need `src/` changes.
- Not run against live config: no real `systemctl --user enable`, no real `--wire --apply`. Both were tested only in the scratch
  HOME.

## 6. QUALIFY of 22af993 (integration + gap work) — the release staged in deploy/release (10/13)
Candidate built by `build_release.sh` from `git archive 22af993` with `-Drelease`: **zigmem sha256
`9fdf6c449a5ef23e592b3d4fde34bb7f7f1c8749a9f5e57904154bd1a143a0ea`**. The integration lane's own build was a90f8559…; builds
are not bit-reproducible, so every receipt below binds to 9fdf6c44…. 8f82fc9 was stopped mid-import when it was superseded:
`qualify_8f82fc919ddf_SUPERSEDED_partial.json`, no gate ran on it.

| Gate | Result | Receipt |
|---|---|---|
| shadow import | 396,099 rows, 0 embed failures (12:51→13:35); seed sha `cf969f19…` | `scratch/p8/shadow-22af993e523a/` |
| leaks, family 93 | **0/93** hub and phase-3 CLI; live-local 1/93 (item 77) | `shadow_bench_22af993e523a.json` |
| leaks, 300 seat prompts | hub 1, CLI 1. Both are item 160: the ledger keyword "oct 1" matched "Oct 12", a **known metric FALSE POSITIVE** (BOARD 10/13 14:35). The receipt stays RED as measured. The release carries the recorded ruling, which passes only while the leak items are exactly {160} (4 RED controls). live-local: 2. | same + `leak_160_analysis_22af993e523a.json` + `deploy/rulings_22af993e523a.json` |
| HTTP | 430/430 = 200 | same |
| **gate 3 (quality)** | **RED: hub 121/130 vs live-local 123/130 (gap 2)**; CLI 124. Shadow deploys with a WARN; `--wire` refuses with "gap 2". | same |
| auth / bind / fuzz / latency / kill -9 | **GREEN 5/5.** auth 247/247 · bind · fuzz 3,228 requests, 0 deaths · **p95 7.19 ms sequential / 7.71 ms ×8** (100K atoms, load 2.8–3.8) · crash 44,775 acked / 0 lost | `safety_22af993e523a.json`, `p4_22af993e523a/` |
| soak #1 | **VOID / RED.** 0 writes acked: my harness wrote to scope `syn-soak`, which the household identity refuses (21,519 × 403 "scope not writable by this seat"). Not the binary, not the token. | `soak_22af993e523a_RED_writes403.json` + `_VOID.json` |
| **soak #2: 3 h, kill -9 at 30 min, LEAK gate** | **GREEN.** 21,490 acked / 0 lost / 0 write errors, integrity ok, restart 1.01 s. **Ceiling 2,154.4 MB, written before the workload** = process 253.9 + index 396,099 × 3,080 B = 1,163.5 + page cache 9 × 64 = 576 + mmap 128 + http 33. Max RSS 1,615 MB. **Last-60-min slope −9.84 MB/h** (121 samples, 1,399.9–1,614.1 MB, spikes kept; raw series `leak.last60_series_t_s_rss_mb`). Restart stayed within the ceiling. Load over the last 60 min: min 0.51, median 0.93, max 2.9. | `soak_22af993e523a.json` (+ `.pre.json`) |
| deploy/rollback round trip, seeded, scratch HOME | **GREEN 26/26.** This release has gate 3 RED, so RT2 checks that `--wire --apply` is REFUSED with "gap 2" and changes nothing. Guarded files are sha-identical after rollback. | `roundtrip_22af993e523a.json` |
| x86 the x86 box | **GREEN.** 9/9 test executables (88 tests) and the 127.0.0.1 smoke, on 22af993 | `x86_hq_22af993.txt` |

**Stamped for SHADOW: yes** (`deploy/release/RELEASE.json`: tested_sha = 9fdf6c44…, 4 gate receipts, quality = gate 3 RED, rulings =
item 160). A real-home `deploy.sh --dry-run` gives preflight green plus the gate-3 WARN, and changes nothing.
**Not installed.** Per supervisor order: no unit, no service, no MCP registration, nothing running. Installing is Alex's call.
