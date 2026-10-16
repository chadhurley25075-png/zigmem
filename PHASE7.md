# zigmem PHASE 7 — the adapters (receipts)

Worker: Claude Code subagent (a Claude model), 2026-10-12. Scope: `adapters/`, `src/adapters/connect.zig`, `tests/phase7/`,
`receipts/phase7/`, one additive dispatch in `src/main.zig`, this file. Synthetic data only (`syn-*` scopes, invented
facts). Test ports 18160–18169, scratch `scratch/p7/`.

## 0. Predictions (written BEFORE any gate run; nothing had been built or run yet)

| Gate item | Prediction | Why / risk |
|---|---|---|
| `zigmem connect <tool> --print` + unit tests | GREEN: prints for all 6 tools, refuses without `--print` (exit 2, nothing on stdout), hostile url/path/name values refused. | Pure string code; risk = Zig 0.17 API drift in my first compile (1–2 compile REDs). |
| Claude Code, headersHelper form (`claude mcp add-json --scope local` in a scratch dir) | GREEN after 0–2 REDs: `claude mcp list` Connected; `claude -p` #1 stores a synthetic fact with `memory_add`; extraction on the primary engine (1 worker) turns it into an atom; `claude -p` #2 (fresh process) recalls it with `memory_search`; token never appears in `~/.claude.json`; removal leaves no `zigmem` entry. | Risk: headersHelper with an argument in the command string; the extractor may not produce an atom from a one-line fact (fallback: `include_turns`). |
| Claude Code, plain `--header` form | GREEN: same round trip; token present in `~/.claude.json` only while registered, absent after remove. | Already proven in phase 4 for search. |
| pi, staged extension in a throwaway run | GREEN after 0–2 REDs: `PI_CODING_AGENT_DIR` = scratch, `--no-session --no-extensions -e adapters/pi/zigmem_memory.ts`, model = the primary engine direct; the model calls `zigmem_memory_add` then `zigmem_memory_search` and quotes the fact. | Risk: async tool registration may land after `-p` starts (tools missing); GLM tool-calling through pi with thinking off. |
| Proxy: python + curl client → zigmem proxy → the primary engine | GREEN: with a synthetic persona codeword in the seat's block, the answer through the proxy contains it; the same request direct to the primary engine does not. | Proven shape in phase 0/4; ≤ 1 request in flight. |
| Codex / OpenClaw | Snippets only. I will parse-check them in ISOLATED homes (`CODEX_HOME`, `OPENCLAW_CONFIG_PATH`/`OPENCLAW_STATE_DIR` in scratch) — no model run. | Both CLIs are installed; their real config dirs must stay untouched. |
| Hermes | Not run: `~/.local/bin/hermes` points at `~/.hermes/hermes-agent/venv`, which does not exist. | Documented snippet only. |
| No other tool's files modified | `~/.claude/settings.json`, `~/.pi/` (tree), `~/.codex/` (tree), `~/.openclaw/` (tree) sha256 identical before/after; `~/.claude.json` differs only by Claude Code's own bookkeeping for the scratch project (no `zigmem` key, no token). | Other Claude sessions on the dev box can also write `~/.claude.json` during the window; I diff by key and report everything. |

## 1. Verdict: PHASE 7 GATE **PASS** (40/40 rows GREEN on run 3; two REDs on the way, both explained in §2)

Binary: `zig build -Drelease --prefix scratch/p7/out` (ReleaseSafe), sha256 `c8400f396113766889b62d3b436e06eca75f609ba11db66569bf00b758955842`.
Harness: `tests/phase7/gate.py` (stdlib only). Final run: `receipts/phase7/gate_run3_GREEN.log` + one JSON per stage.

| Gate item | Result | Receipt |
|---|---|---|
| `zigmem connect` + unit tests | **PASS.** `zig build test -Drelease` 9/9 (6 phase-0 + 3 connect). 6/6 tools print; no `--print` → rc 2, empty stdout; `--url http://0.0.0.0:8470` → rc 2, empty stdout. Hostile values refused (non-loopback/LAN/https/trailing-slash/injected URLs, relative/space/`$()`/quote/`..` paths, bad seat/session/scope names, hostname upstream). **RED shown:** path check disabled → 8/9, rc 1. | `unit_GREEN.txt`, `unit_RED_no_path_check.txt`, `connect.json`, `connect_all.txt` |
| Claude Code, headersHelper form | **PASS.** `claude mcp add-json --scope user zigmem {type:http, url, headersHelper: adapters/claude-code/zigmem_headers.sh <token file>}` → `claude mcp list` "✔ Connected"; token **absent** from `~/.claude.json` while registered; `claude -p` #1 called `memory_add` → `l0_recorded:1`; the the primary engine worker made atom `ana / syn-cc / "Ana keeps the copper kettle in the green attic."`; `claude -p` #2 (fresh process) `memory_search "kettle"` → `FOUND=Ana keeps the copper kettle in the green attic.`; `claude mcp remove --scope user zigmem` → not listed, no `zigmem` key in user or project `mcpServers`. | `cc_helper.json` |
| Claude Code, plain `--header` form (`--scope local`, scratch dir) | **PASS.** Same round trip (`ben / syn-cc2 / "Ben parks the red canoe behind the old mill."`, recalled by a fresh `claude -p`); token present in `~/.claude.json` only while registered, absent after `remove --scope local`. | `cc_header.json` |
| pi, staged extension in a throwaway run | **PASS.** `PI_CODING_AGENT_DIR=scratch/p7/piagent` (own models.json → the primary engine direct), `--offline --no-session --no-extensions … -e adapters/pi/zigmem_memory.ts --thinking off --tools zigmem_memory_add`: run #1 stored; atom `ana / syn-pi / "Ana hides the brass whistle inside the cedar box."`; run #2 (fresh process, `--tools zigmem_memory_search`) → `FOUND=Ana hides the brass whistle inside the cedar box.` The extension has no `pi.on`. pi wrote only into the scratch agent dir (`auth.json`, `models-store.json`). | `pi.json` |
| Proxy (OpenAI-compatible) | **PASS.** Synthetic persona row in the proxy seat's scope ("codeword PELICAN-4471"). `adapters/openai/zigmem_client.py` → proxy :18161 → the primary engine: `PELICAN-4471`; curl → proxy: `PELICAN-4471`; the same body direct to the primary engine: `UNKNOWN` (control). the primary engine `num_requests_running` 0 at both samples, 1 request in flight from us at a time. | `proxy.json` |
| Codex (snippet) | **PASS (config only, no model run).** In an isolated `CODEX_HOME=scratch/p7/codexhome`, Codex's own `codex mcp add zigmem --url … --bearer-token-env-var ZIGMEM_TOKEN` wrote a `[mcp_servers.zigmem]` table equal (parsed TOML) to `adapters/codex/config.toml.snippet`; `codex mcp get zigmem --json` reads it back. | `iso_codex_openclaw.json` |
| OpenClaw (snippet) | **PASS (config only, no gateway, no model).** In an isolated `OPENCLAW_CONFIG_PATH`/`OPENCLAW_STATE_DIR`, `openclaw mcp set zigmem <adapters/openclaw/mcp-server.json>` rc 0, saved `{url, transport: streamable-http, headers}` (placeholder bearer `zm_SYNTHETIC_NOT_A_REAL_TOKEN`), `unset` rc 0. | `iso_codex_openclaw.json` |
| Hermes | **Not run, and why:** `~/.local/bin/hermes` execs `~/.hermes/hermes-agent/venv/bin/python`, and `~/.hermes` does not exist on the dev box. Snippet only (`adapters/hermes/config.yaml.snippet`, and `connect hermes --print`). | — |
| No other tool's files modified | **PASS.** sha256 of every file, before vs after: `~/.claude/settings.json` 0 changed · `~/.pi/` (30,017 files) 0 · `~/.codex/` (5,500) 0 · `~/.openclaw/` 0 · `~/.hermes` absent before and after. `~/.claude.json`: one changed path, `/cachedGrowthBookFeaturesAt` (Claude Code's own feature-flag cache timestamp); 'zigmem' count equal before/after; no diff under any `mcpServers`; none of the 4 test tokens anywhere after. | `foreign_files.json` |

Stops: the hub (pid 2392229) stopped by SIGTERM and verified gone; no listener on 18160–18169 or 8470 afterwards. The gate script exits when done; nothing else was started (no services, crons, hooks or lasting registrations).

## 2. Predictions vs results (receipt-style)

- connect / unit: predicted GREEN after 1–2 compile REDs; got **1 compile RED** (Zig 0.17 renamed `@typeInfo(enum).fields` to `field_names/field_values`; replaced by an explicit tool list).
- **Claude Code headersHelper: 2 REDs, then GREEN.**
  1. Run 1 (`gate_run1_RED.log`, `cc_helper_RED_local_scope_missing_trust.json`): registered with `--scope local` in the scratch dir → `✘ Failed to connect … 401 missing bearer token`. Cause, read from the Claude Code 2.1.287 binary: a headersHelper from local/project scope is "repo-resident" and runs only in a trusted workspace; otherwise it is skipped with reason `missing_trust`. The scratch dir (and `~/` itself) is not trusted, and `claude -p` cannot accept trust. The helper script itself was fine (run by hand: valid JSON). **Fix: the helper form is printed and tested at `--scope user`** (like the the handoff gateway headersHelper, which is user scope). The plain `--header` form keeps `--scope local`.
  2. Run 2 (`gate_run2_RED.log`): user scope → `✔ Connected`, but `claude -p --setting-sources project,local` does not load user-scope MCP servers, so the model had no zigmem tools. Fix: for the user-scope stage only, `--setting-sources user,project,local` (still `disableAllHooks`, user settings are read, not written).
  The first run also had an over-broad check ("'zigmem' appears nowhere in ~/.claude.json" — a phase-4 project key already contains the word); replaced by "count unchanged + no diff under mcpServers + no token".
- Plain `--header`, pi, proxy, Codex, OpenClaw: predicted GREEN; GREEN on the first run. The pi async tool registration (my main risk) landed before the prompt ran.
- The extractor turned each one-line synthetic fact into exactly one atom with the right subject; the `include_turns` fallback was never needed.

## 3. What was built

| File | What |
|---|---|
| `src/adapters/connect.zig` (351 lines incl. 3 tests) | `zigmem connect claude-code\|pi\|openai\|codex\|openclaw\|hermes\|all --print [--url --seat --scopes --token-file --scope --proxy-port --upstream --session --adapters --zigmem]`. Pure text: opens no file, no network, no child process. Refuses without `--print`. Every printed value passes a strict charset/URL check first (hub URL = 127.0.0.1 or 100.64/10, same rule as `serve --bind`). Defaults derive from `$HOME`: token file `~/.config/zigmem/<seat>.token`, adapters `~/zigmem/adapters`. |
| `src/main.zig` (additive, 3 lines) | `connect` dispatch, usage text, test reference. |
| `adapters/claude-code/zigmem_headers.sh` | headersHelper: refuses unless the token file is a regular, non-symlink file we own with mode 0600 holding exactly `zm_` + 64 hex; prints `{"Authorization": "Bearer …"}`. |
| `adapters/pi/zigmem_memory.ts` | Tools-only pi extension (no `pi.on`), staged, not installed. MCP `initialize` + `tools/list` from the hub, registered as `zigmem_<tool>`; token read per call (0600 + format checked); base URL limited to loopback/tailnet. |
| `adapters/openai/zigmem_client.py` | Stdlib example client for proxy mode (base URL + `x-zigmem-session`). |
| `adapters/codex/config.toml.snippet`, `adapters/openclaw/mcp-server.json`, `adapters/hermes/config.yaml.snippet` | Documented snippets; the bearer lives in an env var (Codex) or is pasted by the person (OpenClaw/Hermes). |
| `tests/phase7/gate.py` | The gate above. |

## 4. Not run, and why

- **Hermes**: not runnable here (missing `~/.hermes/hermes-agent/venv`). No third-party memory plugin is installed in it either (SPEC §1.5, B6).
- **Codex / OpenClaw end-to-end with a model**: not run. The task asked for snippets only. Their config acceptance was checked in isolated homes, so their real config dirs stayed untouched.
- **A capture hook for Claude Code** (the SPEC phase-7 row says "optional"): not built. Adding a hook means editing `settings.json`, and BOARD law 4 forbids hooks in these 3 days.
- **headersHelper at local/project scope in a trusted workspace**: not tested (that needs an interactive trust acceptance).
- **The proxy with a token**: still tokenless (phase-4 known issue 3, phase 8).

## 5. Side effects outside ~/zigmem (all Claude Code's own bookkeeping; synthetic content only)

- `~/.claude.json` `/cachedGrowthBookFeaturesAt` changed (feature-flag refresh). In run 1, other GrowthBook cache keys also refreshed.
- `claude -p` transcripts under `~/.claude/projects/-home-user-zigmem-scratch-p7-cc-{helper,header}-client/`.
- Scratch: `scratch/p7/` (hub home, tokens 0600, isolated pi/codex/openclaw homes), all synthetic.
