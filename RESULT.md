# zigmem phase 0 (tf-memproxy): RESULT, 2026-10-12

**Verdict:** A PASS (one noisy run, explained below) · B PASS · C PASS (8/30 → 15/30).
Engine: the primary engine vLLM GLM-5.3-Flash NVFP4 TP2 at `127.0.0.1:18080` (`glm-5.3-flash`), one request at a time,
temperature 0, seed 7, thinking off (`chat_template_kwargs.enable_thinking=false`), `return_token_ids=true`, no `reasoning_effort`.
the local inference server: **not run on the inference server.** the Mac box had no the inference server server listening (probed /v1/models on the usual engine ports
and the process list over the fleet bus: no engine running). We do not start engines, so it stays untested on the inference server.

## Design
- `src/main.zig` (54 lines): the CLI. `zigmem proxy --upstream http://IP:PORT [--port 18140] [--memory FILE]`.
- `src/proxy.zig` (355 lines with 6 unit tests). Contents:
  - Loopback listener and one thread per connection, using raw Linux syscalls. This is the the inference server `listener.zig` pattern, and it avoids the std.Io net churn in 0.17.
  - Per request: read the head and the Content-Length body. Remove `Host`, `Connection` and `Keep-Alive`, then add `Host`, `Content-Length` and `Connection: close`.
  - Forward to the upstream, then relay the reply bytes unchanged until EOF. SSE is not parsed, only copied. TCP_NODELAY is set on both sockets.
  - Injection uses a byte-offset JSON walker and never re-serializes. It finds `messages` and the first element whose top-level `role` is `"system"`, then splices `,{block}` after that element. With no system message, the block goes first.
  - Interface for the later core: `MemorySource.memoryBlock(session) []const u8`. The session comes from the `x-zigmem-session` header. Phase 0 uses `Frozen`: one file is read once at startup and its sha256 is logged. That file is wrapped as `<memory>…</memory>`, has its `<|`, `|>` and `<memory`/`</memory` sequences neutralized, is JSON-escaped, and gives one identical byte string for every request.
  - A request that is not chat, or has no messages, or has malformed JSON is forwarded unchanged (fail-open passthrough).
- `build.zig` + `build.zig.zon`: build with `PATH=~/tools/zig-aarch64-linux-0.17.0:$PATH zig build`, which produces `zig-out/bin/zigmem` in ReleaseSafe (4.8 MB static). Run the tests with `zig build test`, 6/6 green.
- Red/green check of the escape: `receipts/unit_RED_no_escape.txt` (escape removed, exit 1) and `receipts/unit_GREEN.txt`.
- Harness: `tests/gates.py` (stdlib only). Each stage starts the proxy by hand, stops it with SIGTERM, and asserts the PID is gone. All stops logged `alive_after=False`. No proxy is running now, and ports 18140/18141 are free.
- Line count: 409 lines of Zig (54 + 355), plus 12 lines of `build.zig`.

Predictions were written before the engine runs and are in `receipts/PREDICTIONS.md`.

## Gate A: identity (empty memory)
**A0, bytes (local echo upstream, `receipts/A0.json`):**
- 6/6 request bodies were byte-identical at the upstream, including indented JSON and `\u` escapes.
- A chunked SSE reply (50 events in 97-byte chunks with gaps) came back byte-identical through the proxy.
- With the seed memory on:
  - the block sat at index 1, right after the system message;
  - its raw bytes were identical across 4 requests;
  - every other message was unchanged.

**Real engine:** each prompt (5 prompts × {non-stream, stream}) was compared on sha(content, reasoning, finish, usage, token_ids).

| run | design | proxy == direct | control (same route, repeated) |
|---|---|---|---|
| 1 (old single-file build) | D, P, D | 10/10 | 10/10 |
| 2 | D, P, D | 7/10 | 9/10 |
| 3 (final, `receipts/A.json`) | D, P, D, P, with an engine-busy probe before each call | **20/20** | 20/20; quiet rows 10/10 all four identical |

Prediction: 10/10. **Result: PASS on runs 1 and 3, plus the A0 byte proof.**

Run 2 is the noisy one, and its pattern was mixed:
- One non-stream prompt differed on all three calls, the control included.
- Two stream rows differed only on the proxy call.
- `num_requests_running` was 1 right after the run, so the engine had other traffic around then. I did not measure that during the run.

The proxy forwarded the same bytes (A0), so I attribute run 2 to vLLM batch nondeterminism (TP2 + speculative decoding with a co-batched request). That is an inference, not proven. Run 3 adds the busy probe so a future failure can be split cleanly. Across all three runs the proxy matched direct on 37/40 calls, and the direct-vs-direct control on 39/40.

## Gate B: cache and speed (seed block 2,889 tokens, 6 turns)
**Finding first:** this engine runs `--block-size 2304` and only caches whole 4,608-token chunks.
- A probe sent an identical ~2.9K prompt twice and a 4.5K prompt twice: 0 hits.
- A 6.4K prompt sent twice hit 4,608 tokens, and TTFT went from 2,779 to 997 ms.
- The first B run (`receipts/superseded/B_below_4608_chunk.json`) therefore showed 0 hits for both routes.

So the final B uses a fixed seat-sized frame: about 2.6K tokens of a non-family genome file as the system prompt, plus the block, for about 5.5K prompt tokens. A fresh session nonce at the start of the frame makes each run start cold.

ABBA: direct (block pasted by hand at index 1, the exact bytes the proxy inserts, taken from A0) → proxy → proxy → direct, then a control. The control is direct with a per-turn timestamp inside the block.

| route | TTFT turn 1 (ms) | TTFT p50, turns 2–6 (ms) | decode tok/s p50 | prefix-cache hit rate, turns 2–6 (vLLM /metrics deltas) |
|---|---|---|---|---|
| direct, hand-pasted | 2469, 2516 | 817.8 | 43.9 | 0.795 (4,608 tokens every turn) |
| proxy | 2607, 2565 | 784.0 | 44.8 | 0.801 (4,608 tokens every turn) |
| control: block stamped each turn | 2573 | 2586.8 | 40.3 | **0.000** |

- Proxy overhead is measured inside the proxy, from request read to body fully sent upstream, including the TCP connect to the primary engine 6. Over 12 requests: **p50 520 µs, max 767 µs.** That is under the 5 ms bar.
- The hit rates are equal: exactly one 4,608-token chunk per turn on both routes. The stamped control misses every turn, and its TTFT stays around 2.6 s against about 0.8 s.
- **PASS.**

Fixed on the way: the previous B run (`receipts/superseded/B_run2_*`) showed proxy decode p50 at 35.2 against 42.0 direct. The client socket had no TCP_NODELAY, so small SSE writes could wait on Nagle plus delayed ACK. After setting it, decode was 44.8 against 43.9. That cause is likely but not isolated: one run each.

Decode tok/s is noisy here (runs ranged from 31 to 54), because each run's replies differ with the nonce and speculative-decoding acceptance follows the content.

## Gate C: quality (30 of the 130-question bench)
- **Questions:** `qs[i*130//30]` over bench.py's own order (FAMILY 93, BENCH91 15, HISTORY 22), imported read-only from `bench.py`. Graded with the same truth regex and `dead_hits` leak check.
- **System prompt:** "answer in 1–2 sentences, say so if unknown".
- **Block:** the synthesis cartridge seed tier, `~/seed/block.seed.md`. It is 8,653 B / 2,889 tokens, sha256 `cb3e6353…010e34`, built 10/12 05:59. It went only to the primary engine.

| | hits | dead-value leaks |
|---|---|---|
| (i) no memory, direct | 8/30 | 0 |
| (ii) frozen block via proxy | **15/30** | 0 |

- Gained 7, lost 0.
- Prediction: 4–8 without memory and 12–18 with it. The result fell inside both ranges.
- **PASS.**
- Misses with memory are mostly facts the 2.9K seed does not carry: SPX floor level, Rowan's diagnosis, Gamma, the Keep drive, Alex's first line. That is the case for per-turn retrieval in phase 2.
- The raw answers hold family text and stay only in `receipts/C.json` on the dev box.

## Limits
- One request per connection (`Connection: close` upstream). HTTP/1.1 keep-alive from clients is not reused, which costs one TCP connect per request (about 0.3 ms on LAN).
- Request bodies with `Transfer-Encoding: chunked` get a 411 reply. curl, httpx, OpenAI SDKs and pi send Content-Length.
- The upstream must be an IP literal. Names-not-numbers would need resolution in phase 1.
- Linux only, because it uses raw `std.os.linux` syscalls. That is fine for the dev box and the engine hosts; the Macs would need a `posix.system` port.
- `/v1/chat/completions` only. No Anthropic `/v1/messages` or `/v1/responses` injection yet.
- Graceful shutdown is not implemented: SIGTERM kills it.
- Gate C has one seed and one block, and its regexes are loose in places: some no-memory "hits" come from generic wording.
- Gate B covers one engine. Cache granularity depends on the engine: on the inference server, `shared_prefixes` cuts at len−2048/len−512 instead.

## Next: the 1,200–1,800-line version (module plan; the full spec is the other worker's `SPEC.md`)
1. `store.zig`: an append-only `facts.log` holding id, valid_date, text, source, prompt_sha and sha256, with an fsynced index. It refuses `<private>` at write.
2. `bm25.zig`: BM25 over the log. Vectors and the reranker stay in our `:8081`/`:18098` services, called from the sidecar.
3. `extract.zig`: local extraction through the engine itself at idle, gated yes/no (the inference server `/v1/decisions`), with nothing cloud.
4. `gate.zig`: ports of the ledger firewall and the medical person-scope gate, held to a shared test-vector file against the Python originals.
5. Per-session freeze: `MemorySource` becomes a core that builds the block once per `x-zigmem-session`, keeps it byte-identical for that session, and places per-turn hits last.
6. the prefix-cache bank tie-in: build the frozen [frame + block] prefix once and bank it as a the prefix-cache bank frame. On this engine it must be cut on a 4,608-token boundary (the CHUNK-BOUNDARY LAW, now seen from the HTTP side too), so a cold seat attaches it instead of prefilling.

## How it would go to the maintainer
- Keep it a **separate repo / sidecar** first. A sidecar that talks HTTP needs nothing from him, and his recent closes (#557/#574/#575) were for their own server, files over 600 lines, env switches, and names in code.
- If he wants it in the inference server, offer an issue first, with these receipts and ABBA timing. Then a single small PR adding a `--memory FILE` flag modelled on `--compact-memory`:
  - replies byte-identical when the flag is off (gate A as a golden test);
  - no env vars and no external calls;
  - every file under 600 lines.
