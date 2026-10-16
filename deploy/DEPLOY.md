# zigmem — deploy in one command, undo in one command

**Status, 10/14 morning: the staged release in `deploy/release` is 5f8f13c (binary `4c44b28b…`; merge of the fix batch +
the /health fresh-connection fix). It is stamped for **SHADOW**: every safety gate is green, and the one leak line is a ruled
false positive (seat item 160, BOARD 10/13 14:35). Gate 3 is RED at **hub 121/130 vs live 122/130 (gap 1)**, so `--wire` refuses.
**Installed (Alex's order, 10/13 21:12): 22af993** as user unit `zigmem.service` on 127.0.0.1:8470 (data `~/zigmem_data`). Upgrading
it to the staged release is the supervisor's call; it has not been done.

## Which command needs which gate (Alex's law: "nothing goes live in a seat until it beats what they have now and leaks nothing")

| Gate | `deploy.sh` (shadow: zigmem runs and holds copies, **no seat reads it**) | `deploy.sh --wire <seat>` (a seat starts reading it) |
|---|---|---|
| 0 leaks on every set (family 93, the bench, 300 real seat prompts) | **required** | **required** |
| auth matrix · bind 127.0.0.1 only · fuzz · kill -9 durability | **required** | **required** |
| 2-hour soak (0 acked rows lost across a process crash (kill -9), no crash, no memory LEAK: see the leak gate below). Durability: an acked write survives a process crash; a power loss may drop the last commits, never corrupts | **required** | **required** |
| deploy → rollback round trip (your config files come back byte-identical) | **required** | **required** |
| **gate 3: quality**, i.e. the hub scores ≥ live on the 130 questions, same night | shown as a **WARNING** only | **required**. If it is RED, `--wire` refuses and prints the gap, e.g. "hub 120/130 vs live 124/130 (gap 4)" |

So zigmem can run in shadow while it is still a few questions behind. No seat reads from it until it catches up.
The gate receipts themselves are unchanged. This table only decides which command looks at which gate.

## The memory check, old and new side by side (supervisor ruling 10/13)
| | OLD memory check (kept as is, **RED**) | NEW leak gate (what qualify uses now) |
|---|---|---|
| Question | "late RSS ≤ 1.10 × early RSS" | "is memory unbounded, i.e. a leak?" |
| How | median of minutes 10–25 vs the last 15 min of each process life | (1) a ceiling computed from the binary's real settings and written down **before** the run: start RSS + connections × (SQLite cache + mmap) + the search index + HTTP buffers; RSS may never exceed it. (2) The last 60 min of a ≥ 2 h soak must have a fitted slope ≤ 1 MB/h. (3) After the kill -9, the restart stays within the ceiling. |
| Note | Measured from a cold start, so it counts cache warm-up as growth. | A plateau test. qualify soaks for **3 h with the kill -9 at 30 min**, so the last-60-min window starts 90 min after the restart. One-sample spikes stay in the data: no filtering, no smoothing. If the slope fails only because of spikes, it is reported RED with the raw series (`leak.last60_series_t_s_rss_mb` in the receipt). |
| e912 (3b0ca58) | RED: 38 → 70 MB and 69 → 194 MB (ratio 1.83 / 2.80), max 334 MB. Receipt `soak_e912.json` | Informational retrospective only, not a gate run, because that soak killed at 60 min so its last hour was a cold restart. Ceiling 1,799 MB ✓, restart ✓, slope 210 MB/h ✗. Receipt `soak_e912_leak_retrospective.json` |
| Integration binary | — | First real run comes from `qualify.sh`. Its ceiling includes the index: ≈ 395,789 × 3 KB ≈ 1.2 GB. |

## The morning commands (the dev box, as user)

```bash
# THE install (ready, awaiting Alex — it enables a user unit that starts at boot via linger):
~/zigmem/deploy/deploy.sh
# its undo:
~/zigmem/deploy/rollback.sh

# for a NEW commit later (about 3.5 h, nothing goes live):
# 0. only while the release is unstamped — after the integration commit lands (about 3.5 h, nothing goes live):
~/zigmem/deploy/qualify.sh <integration-commit>    # ends "GREEN — deploy/release = …" or "RED: … stopped"

# 1. optional look first (changes nothing):
~/zigmem/deploy/deploy.sh --dry-run

# 2. THE deploy:
~/zigmem/deploy/deploy.sh

# 3. THE undo:
~/zigmem/deploy/rollback.sh
```

## What `deploy.sh` does
1. Checks everything first. If any check fails it prints `REFUSED` and changes nothing. The checks: the binary is the exact
   one the gates ran on (sha256), built with `-Drelease`, built for this CPU; every SAFETY gate in the table above is green
   (gate 3 is printed as a warning and repeated at the end); not already
   deployed; port 8470 is free; the unit binds only 127.0.0.1; extraction is off; there is enough disk; and
   `systemctl --user` works.
2. Copies the binary and tonight's shadow store (395,789 memories, sha-checked) into `~/zigmem_data/` (folder 0700).
3. Creates one read-only seat token, `~/.config/zigmem/shadow.token` (0600).
4. Installs `~/.config/systemd/user/zigmem.service`, enables it, and starts it. Linger is on, so it also runs at boot.
5. Checks it is healthy: `/health` answers, a recall with the token answers 200, a recall without the token gets 401, it
   listens on 127.0.0.1:8470 only, and the running process is our binary. If any of that fails, it rolls itself back.
6. Records everything it did in `~/.local/state/zigmem-deploy/manifest.json`, with the sha of your config files before
   it started.

## What it does NOT do
It does not touch `~/.claude.json`, `~/.claude/settings.json`, `~/.pi`, Codex, OpenClaw, the typed store, the vector store, the cloud store, the
journal, the session log, the shared workspace, or any seat. It adds no hooks and no MCP registrations. No engine is called, because extraction is
off. It runs in **SHADOW**: it holds the memories, and no seat reads from it.

## What `rollback.sh` does
It undoes any `--wire` registration, then stops and disables the unit. It deletes the unit file only if that file is still
byte-for-byte what deploy wrote; if you edited it, it moves it aside and says so. It revokes the seats it created, deletes
their token files, and checks that nothing is listening and no zigmem process is left. Finally it compares your config
files with their pre-deploy sha and prints `sha-identical`. The data folder `~/zigmem_data` is kept; delete it by hand if
you want it gone.
Tested end to end on a scratch home (fake systemctl, port 18190), with and without the 2.4 GB seed, and with a gate-3-RED
release. On that release the shadow deploy goes ahead with the warning, and `--wire` refuses with "gap 4". 28/28 checks are
green, and the config files are sha-identical after rollback.

## Wiring a seat later (Alex's call, not part of the deploy)
`--wire` first re-checks the release, this time with gate 3 required. If gate 3 is RED it prints `REFUSED`, names the score
gap, and changes nothing.
`~/zigmem/deploy/deploy.sh --wire claude-code` **prints** the Claude Code hookup and changes nothing.
`~/zigmem/deploy/deploy.sh --wire claude-code --apply` registers it: a user-scope MCP server `zigmem`, with the token read
by a headersHelper so it is never written into `~/.claude.json`. The registration goes into the manifest, so `rollback.sh`
removes it. For pi, openai, codex, openclaw and hermes, `--wire` only prints the lines; you run them yourself.
Note: the `claude` CLI rewrites `~/.claude.json` when it adds or removes a server. After a wire + rollback that file is
therefore not byte-identical; rollback checks it key by key instead (no zigmem entry, no token) and prints what changed.

## What to watch
```bash
systemctl --user status zigmem          # active (running)
journalctl --user -u zigmem -f          # its log
curl -s http://127.0.0.1:8470/health    # rows, retriever name, uptime
cat ~/.local/state/zigmem-deploy/deploy.log
```
Expect about 40 MB of RAM with the placeholder search. Expect more once the real retriever loads its vector index
(395,789 × 768 floats ≈ 1.2 GB).
