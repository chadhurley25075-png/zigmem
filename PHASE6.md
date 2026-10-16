# zigmem PHASE 6 — the minimal web panel (receipts)

Worker: Claude Code subagent (a Claude model), 2026-10-12. Scope: `src/panel/` (+ `assets/` embedded with `@embedFile`),
`tests/phase6/`, `receipts/phase6/`, this file; minimal additive hunks in `build.zig`, `src/main.zig`, `src/api/cli.zig`
(the serve handler hook) and `src/api/http.zig` (the query string + a 303 reason). Phases 3/5 files untouched.
All data synthetic (`syn-*` scopes, invented people "ana"/"ben", hostile strings). Test ports 18171–18179, scratch `scratch/p6/`.

## 0. Predictions (written BEFORE any gate run; nothing of the panel had been built yet)

| Gate item | Prediction | Why / risk |
|---|---|---|
| CSRF: cross-origin / forged POSTs rejected | GREEN: every state-changing POST (login, logout, supersede, status, token create, token revoke) without the session's CSRF token, with a foreign `Origin`, `Origin: null`, `Sec-Fetch-Site: cross-site`, a foreign `Host` (DNS rebinding) or a non-form content type is refused (403/415) and the DB, audit table and token file are byte-for-byte unchanged. A real browser page on another origin that auto-submits a retire form gets 403. A RED control build (checks patched out) fails the same suite. | SameSite=Strict alone is not enough here: `127.0.0.1:18179` and `127.0.0.1:18171` are the SAME site (ports do not count), so the cookie IS sent cross-port — the token + Origin check must carry it. Risk: getting the browser case wrong (Chromium may omit Origin on some navigations). |
| No secret in any served page or JSON | GREEN: 0 hits for any seat token, any token sha256 (hex), the session id, or `zm_[0-9a-f]{64}` in every body and header served during the run, except (a) the one token-creation page, which carries exactly the new token once, and (b) the session id only inside its own `Set-Cookie` header. `localStorage`/`sessionStorage` empty and `document.cookie` = "" in the browser (HttpOnly). | Token hashes live only in the 0600 token file and the server's memory; sessions are keyed by sha256(session id). Risk: the health JSON or an audit/job row echoing something sensitive. |
| XSS: hostile memory text escaped | GREEN: hostile rows (`<script>`, `"><img onerror>`, `</textarea>`, `javascript:` links, attribute breakouts, bad UTF-8) in atom text/subject/type/lineage, L0 turns, run model/outcome, audit detail and job errors render as text; 0 dialogs / 0 `window.__xss` in Chromium on every page; exactly one `<script` per page (ours, nonce'd); CSP forbids inline handlers anyway. RED control (escaping patched out) fires. | One `esc()` for every dynamic value, attributes always double-quoted, URLs percent-encoded then escaped, a strict nonce CSP as a second wall. |
| Auth on every route except the login page | GREEN: every `/panel/*` GET without a valid session → 303 to `/panel/login` with an empty body; every POST → 401/403; a session whose seat token is revoked (CLI or panel) dies on its next request. | Session → seat is re-checked against the live token table on every request. |
| Works at 390 px | GREEN after 0–2 CSS rounds: `scrollWidth ≤ 390` on every page at 390×844 (light + dark), screenshots in receipts. | Long hashes/ids are the overflow risk → `overflow-wrap:anywhere`, no tables wider than the card. |
| Function (not a gate, but checked) | browse/search/one atom with provenance + lineage + audit, supersede, demote, approve, queue, health, token create (shown once, works on the API) / revoke (401 on the API); atoms row count only grows. | |

## 1. Verdict: PHASE 6 GATE **PASS** (every item GREEN on the final binary; one RED on the way, explained in §2)

Final binary: `zig build install -Drelease`, `zig-out/bin/zigmem` sha256 `5c7cc50dbe99eb2eb7d27e8d4014e56af3ae9872becbf28bb908ebc9d8208e67`
(copy `scratch/p6/zigmem`). Harness `tests/phase6/gates.py all` → `receipts/phase6/panel.json`: **auth 80/80 · csrf 31/31 · xss 15/15 ·
mobile 26/26 · function 26/26 · secrets 17/17 → GREEN.** Every server and the "evil" page server were stopped by PID and verified gone.

| Gate item | Result |
|---|---|
| CSRF | **PASS 31/31.** Refused (403/415/401), with the DB atoms+statuses, audit row count and token-file sha256 identical before/after: no csrf, wrong, short, another session's csrf, `Origin` evil / `null` / other port on the same site / https variant, `Sec-Fetch-Site` cross-site and same-site, foreign `Host` (DNS rebinding), no Host, text/plain / JSON / multipart bodies, supersede / seat-create / seat-revoke / logout without csrf, valid csrf without a cookie (401); login CSRF: no pre-cookie, csrf from another form, no csrf, evil Origin → 403 and no session cookie. A refused logout leaves the session alive. **GREEN control:** the same request with the token + same-origin headers → 303, atom retired. **Chromium:** logged-in browser opens an auto-submitting retire form from `127.0.0.1:18179` (same site, cross-origin: the SameSite cookie IS sent) → 403; from `localhost:18179` (cross-site) → 401 (no cookie); from `127.0.0.1:18179` holding the browser session's **real** csrf (leak simulation) → 403 by the Origin check alone; atom unchanged each time. |
| No secret served | **PASS 17/17.** Every response (python client + every response Chromium saw; bodies and headers) grepped for every seat token, every token sha256 (lower and upper hex) and every session id: 0 hits; `zm_<64 hex>` appears only on the one creation page (exactly once, the new token), never again (seats page re-checked); session ids only in their own `Set-Cookie`. `localStorage`/`sessionStorage` length 0 and `document.cookie` "" on all 12 pages (HttpOnly). `audit.log` has no token, hash or session id. Token file 0600, hash only. |
| XSS | **PASS 15/15.** Hostile rows (11 payloads: `<script>`, `"><img onerror>`, `<svg onload>`, `</textarea>`/`</title>` breakouts, `javascript:` text + links, `<iframe srcdoc>`, `<style>`, `<meta refresh>`, bidi/entities, plus bad UTF-8) in atom text, subject (also used in URLs), type, lineage, valid_from, src_l0, extractor, run id/model/outcome, L0 turns, audit seat/action/detail and job errors: Chromium on 12 pages → 0 dialogs, `window.__xss` never set, exactly 1 `<script>` (ours, nonce), no raw markup in the DOM, 0 CSP violations; all 40+ raw HTML bodies: exactly one `<script` and no raw hostile markup. |
| Auth on every route but login | **PASS 80/80.** 9 GET routes × {no cookie, random 64-hex, junk, non-hex, pre-cookie only} → 303 `/panel/login`, empty body; 6 POST routes × same → 401; login page 200; a CLI-revoked seat's panel session → 303 on its next request; `/v1/recall`, `/v1/atoms/list`, `/mcp` without bearer still 401 behind the wrapper. Phase-4 auth matrix re-run on this binary (receipts in `scratch/p6/p4rerun_rec`, not over phase 4's): **199/199 GREEN**. |
| 390 px | **PASS 26/26.** Chromium 390×844, mobile, light + dark: login + 12 pages, `scrollWidth ≤ 390` and no element's right edge past 390. Screenshots `receipts/phase6/shots/*_{light,dark}.png` (eyeballed: atoms list, atom detail in dark). Not tested on a real iPhone/Safari. |
| Function (26/26) | list, word search, subject filter; atom page with provenance (source, extractor, prompt sha, run row, content sha, lineage), source L0 turn, history, audit; supersede → new active version, old `superseded` with `superseded_by`, same lineage, extractor `panel`; demote → review → approve (trusted only; untrusted 403); untrusted privacy screen 403; read-only 403; retire = status flip + audit row, cannot come back (409); other-scope atom 404 and absent from search/chips; queue (states, jobs, dead error, awaiting-review count); health; non-admin sees only its own seat and cannot create; admin create → token shown once, works on `/v1/recall`, panel revoke → API 401 at once and that seat's panel session ends; a seat cannot revoke itself; every atom id still present (nothing deleted); logout ends the session. |
| RED control | Scratch copy with `esc()` → raw and the Origin + CSRF checks patched out (`receipts/phase6/RED_unsafe_control.json`): **csrf 9/31, xss 4/15 → RED** (Chromium attacks retired atoms, scripts ran). Copy deleted. |
| Unit tests | `zig build test-panel -Drelease` 6/6; `test-api` 8/8 and `test` 6/6 still pass. |

## 2. Predictions vs results

- Auth, XSS, secrets, 390 px: predicted GREEN, got GREEN (390 px with 0 CSS rounds).
- **CSRF: one RED round, the predicted risk.** First run: Chromium's own login POST was refused. Its request carried `Origin: null`, because the page set `Referrer-Policy: no-referrer`, and under that policy Chromium serialises Origin as `null` on form posts. The guard was right to refuse `null`. The fix was the policy, not the guard: `Referrer-Policy: same-origin` (and the meta tag), which still sends nothing cross-origin. Run 2: one function check RED from a test bug (the search page echoes the query `zebra` into the search box; the check now looks for the row's own text). Run 3 = the receipts above.

## 3. What was built (`src/panel/`, Zig 1,375 lines incl. tests + 56 lines CSS + 30 lines JS; every file ≤ 600 lines)

| File | What |
|---|---|
| `panel.zig` | `wrap(hub, rest_handler)`: `/panel` and `/panel/*` here, everything else passes through untouched. Guards: Host allowlist (`127.0.0.1:port`, `localhost:port`, bind:port), GET/POST only; POST: `Sec-Fetch-Site` same-origin when present, `Origin` (when present) = `http://<Host>`, form content type, session CSRF token (constant-time). Headers: nonce CSP (`default-src 'none'`, `form-action 'self'`, `frame-ancestors 'none'`, `base-uri 'none'`), XFO DENY, nosniff, `Referrer-Policy: same-origin`, COOP/CORP, `Cache-Control: no-store`. Panel calls go to the hub's `audit.log` (seat, route, status, denied; never arguments). |
| `session.zig` | 64 in-memory sessions: cookie `zm_sess` = 32 random bytes (HttpOnly, SameSite=Strict, Path=/panel); server keeps sha256(id), the seat's token hash and a per-session CSRF secret; 2 h idle / 12 h absolute; seat re-checked on every request against the live token table (revocation is immediate). Login CSRF: `zm_pre` cookie + HMAC-SHA256(per-process secret, pre). |
| `pages.zig` | Memories (subject chips, status filter, search, paging), one memory (provenance, run, source turn, lineage history, audit, forms), queue, health. Every query takes the seat's `Scope`. |
| `actions.zig` | login/logout, supersede (`store.atoms.supersede`), status (`setStatus` + reason row; approve = trusted only), seats page, create (token shown once, file rewritten atomically under a lock from a fresh read), revoke (stamps `revoked_ms`, ends that seat's panel sessions, refuses self). Untrusted seats pass the phase-4 privacy screen. |
| `html.zig` | `esc` (text + attributes, bad UTF-8 → U+FFFD, controls dropped), URL coding, form/query/cookie parsing, page shell. `assets/panel.css` (light/dark via `prefers-color-scheme`, phone-first) + `assets/panel.js` (confirm on Retire/Revoke, copy the new token; no storage, no network), both `@embedFile`, no CDN, no fonts, works offline. |

Shared files (additive hunks only): `build.zig` phase-6 block (`panel` module, `zig build test-panel`); `src/main.zig` imports `panel` and passes `.panel = panel.wrap`; `src/api/cli.zig` gets an optional `panel` hook in `ProxyHooks` that wraps the REST handler; `src/api/http.zig` adds `Request.query` (raw query string, default "") and the `303 See Other` reason.

## 4. Not run, and why

- **A real iPhone / Safari**: only Chromium in a 390 px mobile viewport. Safari's Origin and SameSite behaviour is expected to match (it sends Origin on POST) but is unproven here.
- **Tailnet bind (`--bind 100.x`)**: not run (BOARD law 4). The Host allowlist includes the bind address, so a tailnet name such as a MagicDNS host would be refused (403). An iPhone over the tailnet must use the 100.x address.
- **Login brute-force rate limit**: none (256-bit tokens). Every failure is in `audit.log` as `login failed`.
- **Phase-3 retriever in panel search**: the panel search uses the store's FTS5 directly (scope-filtered, inactive rows included on demand), not `hub.ret`. When phase 3 is wired, the panel search stays plain FTS5.
- **Phase 5 household scopes**: the panel uses whatever scopes a seat token carries; no phase-5 code existed when this was built.

## 5. Known issues

1. **No `Secure` cookie flag**: the panel is plain HTTP on loopback/tailnet (Secure would break the iPhone over `http://100.x`). Tailscale encrypts the wire.
2. Sessions live in memory: a server restart logs everyone out (by design).
3. Panel token writes and the `zigmem token` CLI share no lock. Each does a fresh read plus an atomic rename, so a truly simultaneous CLI + panel write could lose one of the two edits (detectable: the token is missing from `token list`).
4. Atoms inserted outside the store API (the synthetic seed) have no audit rows, so their Audit card is empty.

Nothing of this lane is running (stops recorded in each receipt). Scratch: `scratch/p6/`.
