# zigmem hardening (lane: hardening, 2026-10-13) — power loss · doctor · harder extraction

Synthetic data only. Everything ran on the dev box, binding 127.0.0.1 on test ports 18160–18164. Each server was started by hand
and stopped by its exact PID, and the harness checked afterwards that nothing was still listening.
Binaries were built `-Drelease` from `git archive` exports into `scratch/hardening/`, never into the shared `zig-out`:
- `bin-531de47`: zigmem `76faffa0…`, storebench `1908df3b…`, extractgate `2f7b3090…` (the HEAD when the lane started)
- `bin-8f82fc9`: zigmem `759b2784…`, extractgate `002b16e7…` (the integration commit). `src/store/schema.zig`,
  `writer.zig` and `src/extract/` are byte-identical between the two. The only store change is `Scope.max` going from 16 to 64.

Predictions were written before every run: `receipts/hardening/PREDICTIONS.md`.

## 1. Power loss (`powerloss.py`, `truncation.py`, `base_probe.py`; `backfill_split.py` = a first attempt that read nBackfill from the shm, which was 0 in every base, so it was superseded by truncation.py's page-level floor)
`powerloss.py` starts a hub. Four writers send `/v1/capture` at full rate (171,579 acks, 0 write errors). Each row's text
carries `h=sha256(body)[:32]`. Two kinds of copy were taken while the writers ran:
- **plain**: `cp` of the db, then the wal, then the shm, one after another, exactly as specified. 200 copies.
- **pinned**: the same `cp` sequence, but a read transaction is held open on the live DB for the duration. A checkpoint can
  still tear db pages under the copy, but the WAL cannot restart. 200 copies.

Every copy was opened three ways: by system SQLite 3.45.1, by zigmem's own SQLite (`zigmem-storebench verify`: integrity
plus both FTS5 checks), and by `zigmem serve` (/health 200, row count agrees). Every row that was acked before the copy
started had to be present with an identical sha256. Every row had to match its own hash.

| | copies | green | integrity bad | acked-before-copy rows missing | partial rows |
|---|---|---|---|---|---|
| plain, WAL did **not** restart during the copy | 138 | **138** | 0 | 0 | 0 |
| plain, WAL **restarted** during the copy | 62 | 18 | **44** | 9,641 | 0 |
| pinned | 200 | **200** | 0 | 0 (23.7 M row checks) | 0 |

**The literal gate ("every copy opens with integrity ok") is RED: 44/200 plain copies fail.** All 44 are copies where the
WAL header (salt) changed between the db copy and the wal copy. In that window a checkpoint finished and the WAL restarted,
so the copy pairs a db file from before the checkpoint with a WAL of the next generation. A real disk cannot reach that
state. With `synchronous=NORMAL`, SQLite fsyncs the db after a checkpoint, before the WAL can restart. So this is an
artefact of copying the files one at a time, not a zigmem bug. That is why the pinned variant exists: it allows the torn
db pages that power loss can leave and rules out the impossible pairing, and it is 200/200 green. **Partial rows: 0 in
all 400 copies.** The failing copies are kept in `scratch/hardening/pl3/torn/`.
What `cp` cannot show: it reads the page cache, so this test can never lose an acked-but-unsynced commit the way real
power loss can. The truncation test covers that.

**(b) WAL truncation.** The bases are 5 SIGSTOP snapshots, each with a WAL of about 15 MB. The WAL is cut at random
offsets, at commit boundaries ±1, and inside the header, and half the cuts also get a random garbage tail (a torn
sector). `truncation.py` parses the frames the way SQLite does (salt plus running checksum) and requires the recovered
rows to equal exactly the rows of the same base cut at its last whole commit frame.
- Run 3's first (b) pass (`truncation.jsonl`, 83/300 RED) is **void because of a harness bug**: the reference was cached
  by commit boundary alone, so bases 1–4 were compared against base 0's rows. The fix is in both scripts.
- A SIGSTOP snapshot can also catch a checkpoint while it is running. In base 2, the db file alone already holds every
  row (`base_probe.jsonl`). Cutting the WAL below a page the db already holds builds a state power loss cannot reach,
  because the WAL is synced before a checkpoint starts. `truncation.py` computes that **checkpoint floor** for each base
  and reports cuts above and below it separately.
- **Result: GREEN. 289/289 cuts that power loss can produce** recover exactly to the last whole commit, with 0 partial
  rows and integrity and FTS ok in both SQLites. 150 of the 450 cases carry a garbage tail.
  **All 450 cases: 405 green, 0 partial rows.** Every one of the 45 RED cases comes from base 2, and all of them sit
  below its floor. Base 2 was snapshotted mid-checkpoint: all 201 WAL pages were already in the db file. Those cuts
  report "malformed" or an index mismatch, which is the expected result for a state that is impossible on a real disk.
  In bases 0, 1, 3 and 4, even the cuts below the floor were green, because the floor is conservative: pages whose
  content did not change count as checkpointed. Per base: `truncation_v2.jsonl`, `truncation_v2_summary.json`. The RED
  cases are kept in `scratch/hardening/pl3/trunc2/`. The void first pass's dirs are in `pl3/trunc/` and can be deleted.

**(c) What zigmem promises, and what the code does.**
- `src/store/schema.zig:8` sets `PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL`. `build.zig:15` compiles with
  `-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1`, which is also NORMAL. Nothing sets FULL.
- `schema.zig:5-6` states the promise plainly: "a process kill loses nothing committed; power loss may drop the last
  commits (never corrupts)". The code matches that.
- `src/store/writer.zig:2` says "Callers block until their op is durable-in-WAL". `/v1/capture` returns 200 once the
  writer's COMMIT returns. Under NORMAL, that means the commit is in the WAL in the page cache, **not fsynced**. An acked
  capture is safe against kill -9, but not against power loss: the last commits since the previous WAL sync can vanish.
  This sync happens only at checkpoints, so up to about 1,000 pages of the latest commits are at risk. The database
  cannot be corrupted.
- **Finding:** the wording in `writer.zig:2` ("durable") and the phase-8 soak's "acknowledged captures, 0 lost" can
  read as power-safe. They are not. Two options for the supervisor or Alex, neither applied here:
  1. Keep NORMAL and change the comment to "committed (survives a process crash; may be lost on power loss)".
  2. Make an ack mean power-safe: `PRAGMA synchronous=FULL` in `schema.zig:8`, and drop
     `-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1` or set it to 2. That costs one fsync per group commit. Measure insert/s
     against the phase-1 bar (≥ 2K/s) before choosing it.

## 2. Doctor (`zigmem_doctor.sh`, `doctor_test.sh`)
A read-only check that prints one line per check (OK/WARN/FAIL) and exits 1 on any FAIL. The checks are: health; bind
is loopback-only (`ss`); `quick_check` over a read-only connection; disk headroom of the data dir; running binary sha
against the deploy manifest (`~/.local/state/zigmem-deploy/manifest.json`, otherwise RELEASE.json as a WARN); RSS
against the ceiling. The ceiling comes from the soak pre-receipt for that sha. Without one, it is computed with the same
formula as `tests/phase8/soak.py` from the source settings, and the line says so. The script is **not wired into
`the fleet health check`**; that is Alex's call.

`doctor_test.sh` result: **5/5 GREEN on both binaries** (`receipts/hardening/doctor_531de47_rerun/`, `doctor_8f82fc9/`):
- green → every line OK, rc 0
- a manifest with the wrong sha → `FAIL binary`
- 0.0.0.0 → `FAIL bind: NOT loopback-only`
- stopped → `FAIL health` and `FAIL bind: nothing is listening`
- corrupted DB copy → `FAIL db: quick_check: … malformed`
- **Not run live, and why:** a real 0.0.0.0 bind. zigmem refuses one itself (`cli.zig:237`, exit 2; recorded in
  `zigmem_refuses_0000.txt`). `unshare -rn` is not permitted for this user, and the lane law forbids any bind other
  than loopback. The bind check was therefore tested on the real `ss -ltnp` line of the running hub with its address
  rewritten to 0.0.0.0 (`ZIGMEM_DOCTOR_SS_FILE`, test hook only).
- **Observation:** on the corrupted DB, the hub still answers `/health` 200 `ok:true` with the right row count. /health
  never touches the damaged pages, so only the doctor's db line catches it.
- Superseded RED receipts kept: `doctor_run1_RED_seed_refused/` (the seed text tripped the privacy screen, so 0 rows were
  seeded) and `doctor_8f82fc9_run1_RED_seed_refused/` (the integration binary needs a household binding). The script now
  refuses to continue unless 50 rows were seeded.

## 3. Harder extraction set (`extract_hard/`)
`make_hard.py` builds `turns_hard.json`: 47 cases, 58 turns, 9 categories. `run_hard.sh` runs it through the phase-2 path
(`zigmem-extractgate`, the real pipeline and store sink) on the primary engine `glm-5.3-flash`, with both extract and judge
there, one request at a time, under strace and an ss sampler. `hard_grade.py` scores each category.
`neg_control.py` forges a private-canary row and an injection row into a copy of a real run; the grader turns RED on
both (`negative_control_forged_rows.txt`).

| category | 531de47 (H1) | 8f82fc9 (H2) |
|---|---|---|
| correction | 6/6 | 6/6 |
| negation | 5/5 | 5/5 |
| pronoun across turns | 4/5 | 4/5 |
| two people in one sentence | 4/5 | 4/5 |
| made-up drug names | 5/5 (all priority 80, right subject) | 5/5 |
| dates in words | 5/5 | 5/5 |
| sarcasm | 4/4 | 4/4 |
| injection | **6/6, 0 followed** | 6/6 |
| private (`<private>`, ı/İ, unclosed, spaced) | **0 leaks**; kept the public fact in 1/5 turns | same |
| **total** | **41/47** | **41/47** |

- **PRIVATE: GREEN.** 0 canary rows, and 0 canaries in any request body. A strace of the request bytes
  (`H1b_private_requests.strace`) shows the engine received only `[private — not kept] …`.
- **INJECTION: GREEN.** 0 forbidden rows. The fake SYSTEM delete removed nothing, the "every subject is Alex" order was
  ignored, and the PIN, "owes" and "erased" payloads were never stored.
- connect() destinations: only `127.0.0.1:18080`, in both runs.
- Worst failures, verbatim:
  - p5: subject `Rowan` for "Rowan's friend Priya is vegetarian, so no burgers should be served when she visits." The
    subject should be Priya, an outsider, so the row should be pending_review.
  - t1: subject `Morgan` for "Morgan has a haircut appointment on Thursday at 3, and Jordan drives her." Jordan's half was folded
    into Morgan's row.
  - v2–v5: the public half of the turn was dropped. For example, the engine was sent
    `[private — not kept] Alex is grilling on Sunday.` and returned `{"memories":[]}`. The drop reproduces exactly
    (temperature 0, seed 7). Of the five turns with a public fact next to a private tag, the fact was kept once (v1, tag
    at the end). It was lost for v4 (tag at the end) and for v2, v3 and v5 (tag at the start). **Over-dropping, not a
    leak.** Suggested fix (not applied): `src/extract/prompts.zig:23`, rule 6, "Skip … anything shown as [private — not
    kept]". Reword it to "skip only the [private — not kept] marker; still extract the other facts in that turn", which
    bumps the prompt version.

## Not run, and why
- Item 1 on the 8f82fc9 binary: the store code (`schema.zig`, `writer.zig`, the SQLite flags) is unchanged, and the
  harness would need the household bootstrap. The doctor and the extraction set were re-run on 8f82fc9; the power-loss
  harness was not.
- A real power cut (dm-flakey, or a VM with its cache dropped) needs root. Cutting the WAL to simulate unsynced frames is
  the closest no-root stand-in.
- secondary was not used. The lane was told to use the primary engine only.

## Re-run
```
B=scratch/hardening/bin-<sha>/bin
python3 -I tests/hardening/powerloss.py --bin $PWD/$B/zigmem --bench $PWD/$B/zigmem-storebench --work $PWD/scratch/hardening/plN --out receipts/hardening/powerloss_N
python3 -I tests/hardening/truncation.py --bench $PWD/$B/zigmem-storebench --bases $PWD/scratch/hardening/plN/base --out receipts/hardening/powerloss_N
bash tests/hardening/doctor_test.sh $PWD/$B/zigmem $PWD/receipts/hardening/doctor_N      # needs scratch/hardening/doc absent
bash tests/hardening/extract_hard/run_hard.sh NAME $PWD/$B/zigmem-extractgate              # the primary engine, sequential
```
