#!/usr/bin/env python3
"""Gates A/B/C for the zigmem proxy (phase 0). One request at a time, temperature 0, thinking off. Usage: gates.py A0|A|B|C"""
import http.client, json, hashlib, os, re, signal, socket, statistics, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.path.expanduser("~")
HERE = f"{HOME}/zigmem"
BIN = f"{HERE}/zig-out/bin/zigmem"
REC = f"{HERE}/receipts"
UP_HOST, UP_PORT = "127.0.0.1", 18080
PX_PORT, ECHO_PORT = 18140, 18141
SEED = f"{HOME}/seed/block.seed.md"
EMPTY = f"{REC}/empty_memory.txt"
MODEL = "glm-5.3-flash"
BASE = {"model": MODEL, "temperature": 0, "seed": 7, "chat_template_kwargs": {"enable_thinking": False}, "return_token_ids": True}
os.makedirs(REC, exist_ok=True)
open(EMPTY, "w").close()


class Proxy:
    """Starts the proxy by hand for one stage; stop() kills it and verifies the PID is gone."""
    def __init__(self, upstream, memory, log):
        self.log = open(log, "w")
        args = [BIN, "proxy", "--port", str(PX_PORT), "--upstream", upstream] + (["--memory", memory] if memory else [])
        self.p = subprocess.Popen(args, stderr=self.log, stdout=self.log)
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", PX_PORT), 0.2).close(); break
            except OSError:
                time.sleep(0.05)
        print(f"proxy pid={self.p.pid} up={upstream} memory={memory}")

    def stop(self):
        self.p.send_signal(signal.SIGTERM); self.p.wait(5)
        alive = os.path.exists(f"/proc/{self.p.pid}") and open(f"/proc/{self.p.pid}/stat").read().split()[2] != "Z"
        print(f"proxy pid={self.p.pid} stopped, alive_after={alive}")
        self.log.close()
        assert not alive


def call(port, host, body, stream=False):
    """POST one chat request; returns dict with parsed reply, ttft, decode tok/s."""
    b = dict(body, stream=stream)
    if stream:
        b["stream_options"] = {"include_usage": True}
    data = json.dumps(b).encode()
    c = http.client.HTTPConnection(host, port, timeout=600)
    t0 = time.perf_counter()
    c.request("POST", "/v1/chat/completions", data, {"Content-Type": "application/json"})
    r = c.getresponse()
    if not stream:
        raw = r.read(); t1 = time.perf_counter()
        j = json.loads(raw)
        ch = j["choices"][0]
        m = ch["message"]
        return {"content": m.get("content") or "", "reasoning": m.get("reasoning") or "", "finish": ch["finish_reason"],
                "ids": ch.get("token_ids"), "usage": {k: j["usage"][k] for k in ("prompt_tokens", "completion_tokens")}, "total": t1 - t0}
    content, reasoning, ids, usage, first, finish, chunks = [], [], [], None, None, None, 0
    while True:
        line = r.readline()
        if not line:
            break
        line = line.strip()
        if not line.startswith(b"data: ") or line == b"data: [DONE]":
            continue
        j = json.loads(line[6:]); chunks += 1
        if j.get("usage"):
            usage = {k: j["usage"][k] for k in ("prompt_tokens", "completion_tokens")}
        for ch in j.get("choices", []):
            d = ch.get("delta", {})
            if (d.get("content") or d.get("reasoning")) and first is None:
                first = time.perf_counter()
            content.append(d.get("content") or ""); reasoning.append(d.get("reasoning") or "")
            ids += ch.get("token_ids") or []
            finish = ch.get("finish_reason") or finish
    t1 = time.perf_counter()
    first = first or t1
    ntok = usage["completion_tokens"] if usage else 0
    return {"content": "".join(content), "reasoning": "".join(reasoning), "finish": finish, "ids": ids or None, "usage": usage,
            "chunks": chunks, "ttft": first - t0, "total": t1 - t0, "decode_tps": (ntok - 1) / (t1 - first) if ntok > 1 and t1 > first else 0.0}


def metrics():
    c = http.client.HTTPConnection(UP_HOST, UP_PORT, timeout=10); c.request("GET", "/metrics")
    txt = c.getresponse().read().decode()
    g = lambda n: float(re.search(rf"^vllm:{n}{{[^}}]*}} ([0-9.e+]+)", txt, re.M).group(1))
    return g("prefix_cache_hits_total"), g("prefix_cache_queries_total"), g("num_requests_running")


def sig(r):
    """What 'byte-identical reply' means here: text, reasoning, finish, usage and token ids."""
    return hashlib.sha256(json.dumps([r["content"], r["reasoning"], r["finish"], r["usage"], r["ids"]]).encode()).hexdigest()[:16]


PROMPTS = ["Name three primary colors.", "What is 17 times 23? Answer with the number.", "Write one sentence about the ocean.",
           "List the days of the week in French.", "Explain what a prefix cache is in two sentences."]


def stage_A0():
    """Bytes: the proxy forwards the exact request body when memory is empty; shows the insert position when memory is on."""
    seen = []
    SSE = b"".join(b'data: {"choices":[{"delta":{"content":"tok%d \\u00e9"}}]}\n\n' % i for i in range(50)) + b"data: [DONE]\n\n"
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"])); seen.append(body)
            if b'"stream": true' in body or b'"stream":true' in body:
                self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
                for i in range(0, len(SSE), 97):  # odd-sized chunks with gaps, like a real token stream
                    part = SSE[i:i + 97]; self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part)); self.wfile.flush(); time.sleep(0.002)
                self.wfile.write(b"0\r\n\r\n"); self.close_connection = True; return
            out = json.dumps({"echo_sha": hashlib.sha256(body).hexdigest()}).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
        def log_message(self, *a): pass
    srv = ThreadingHTTPServer(("127.0.0.1", ECHO_PORT), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
    bodies = [json.dumps(dict(BASE, messages=[{"role": "system", "content": "You are brief."}, {"role": "user", "content": p}]), indent=i % 2).encode()
              for i, p in enumerate(PROMPTS)] + [b'{"messages":[{"role":"user","content":"x\\u00e9 \\"q\\""}],"model":"m"}']
    out = {}
    px = Proxy(f"http://127.0.0.1:{ECHO_PORT}", EMPTY, f"{REC}/A0_proxy_empty.log")
    same = 0
    for b in bodies:
        c = http.client.HTTPConnection("127.0.0.1", PX_PORT); c.request("POST", "/v1/chat/completions", b, {"Content-Type": "application/json"})
        got = json.loads(c.getresponse().read())["echo_sha"]; same += got == hashlib.sha256(b).hexdigest()
    sse_body = json.dumps(dict(BASE, stream=True, messages=[{"role": "user", "content": "s"}])).encode()
    raw = {}
    for port in (ECHO_PORT, PX_PORT):  # the raw HTTP reply bytes, read off the socket, direct vs via the proxy
        sk = socket.create_connection(("127.0.0.1", port)); sk.sendall(b"POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % (len(sse_body), sse_body))
        buf = b""
        while (chunk := sk.recv(65536)):
            buf += chunk
        raw[port] = buf.split(b"\r\n\r\n", 1)[1]  # body only: the Date header differs between the two calls
        sk.close()
    out["stream_body_bytes_identical"] = raw[ECHO_PORT] == raw[PX_PORT] and len(raw[PX_PORT]) > len(SSE)
    px.stop()
    out["empty_identical_bodies"] = f"{same}/{len(bodies)}"
    seen.clear()
    px = Proxy(f"http://127.0.0.1:{ECHO_PORT}", SEED, f"{REC}/A0_proxy_seed.log")
    seen.clear()
    for b in bodies[:2] + bodies[:2]:
        c = http.client.HTTPConnection("127.0.0.1", PX_PORT); c.request("POST", "/v1/chat/completions", b, {"Content-Type": "application/json"}); c.getresponse().read()
    px.stop(); srv.shutdown()
    msgs = [json.loads(s)["messages"] for s in seen]
    inserted = [m[1] for m in msgs]
    out["memory_at_index_1_after_system"] = all(m[0]["role"] == "system" and m[1]["content"].startswith("<memory>") for m in msgs)
    out["memory_message_identical_across_requests"] = len({json.dumps(x, sort_keys=True) for x in inserted}) == 1
    out["memory_raw_bytes_identical_across_requests"] = len({s[s.index(b'{"role":"system","content":"<memory>'):].split(b'</memory>"}')[0] for s in seen}) == 1
    out["other_messages_unchanged"] = all(json.loads(b)["messages"] == [m[0]] + m[2:] for b, m in zip(bodies[:2] + bodies[:2], msgs))
    json.dump(inserted[0], open(f"{REC}/memory_message.json", "w"))  # the exact message, for the hand-pasted control in gate B
    print(json.dumps(out, indent=1)); json.dump(out, open(f"{REC}/A0.json", "w"), indent=1)


def stage_A():
    """Identity on the real engine: direct vs proxy (empty memory) vs direct again, non-stream and stream."""
    px = Proxy(f"http://{UP_HOST}:{UP_PORT}", EMPTY, f"{REC}/A_proxy.log")
    rows = []
    for stream in (False, True):
        for p in PROMPTS:
            body = dict(BASE, max_tokens=96, messages=[{"role": "system", "content": "You are brief."}, {"role": "user", "content": p}])
            seq = []
            for kind in ("direct", "proxy", "direct", "proxy"):
                busy = metrics()[2]
                r = call(UP_PORT, UP_HOST, body, stream) if kind == "direct" else call(PX_PORT, "127.0.0.1", body, stream)
                seq.append((kind, sig(r), busy, r["ids"]))
            ref = seq[0][3] or []
            div = [next((i for i, (x, y) in enumerate(zip(ref, s3[3] or [])) if x != y), None) for s3 in seq]
            rows.append({"stream": stream, "prompt": p, "direct": seq[0][1], "proxy": seq[1][1], "direct2": seq[2][1], "proxy2": seq[3][1],
                         "others_running_before": [x[2] for x in seq], "first_divergent_token_vs_direct": div, "ids_present": bool(ref)})
            print(rows[-1])
    px.stop()
    pairs_p = [(r["direct"], r["proxy"]) for r in rows] + [(r["direct2"], r["proxy2"]) for r in rows]
    pairs_d = [(r["direct"], r["direct2"]) for r in rows] + [(r["proxy"], r["proxy2"]) for r in rows]
    quiet = [r for r in rows if not any(r["others_running_before"])]
    res = {"proxy_eq_adjacent_direct": f"{sum(a == b for a, b in pairs_p)}/{len(pairs_p)}",
           "control_same_route_repeat": f"{sum(a == b for a, b in pairs_d)}/{len(pairs_d)}",
           "quiet_rows_all4_identical": f"{sum(len({r['direct'], r['proxy'], r['direct2'], r['proxy2']}) == 1 for r in quiet)}/{len(quiet)}",
           "busy_rows_all4_identical": f"{sum(len({r['direct'], r['proxy'], r['direct2'], r['proxy2']}) == 1 for r in rows if r not in quiet)}/{len(rows) - len(quiet)}",
           "rows": rows}
    print({k: v for k, v in res.items() if k != "rows"}); json.dump(res, open(f"{REC}/A.json", "w"), indent=1)


TURNS = ["In one short paragraph, who are the people in this family?", "What is the family's mission, in one sentence?",
         "Name one machine in the fleet and its job.", "What is the money floor and why does it matter?",
         "Give one rule the assistant must always follow.", "Summarize this conversation in two sentences."]


# the primary engine vLLM runs --block-size 2304 and only caches whole 4608-token chunks (probe 10/12: a 4.5K prompt never hit, a 6.4K
# prompt hit 4608). A 2.9K block alone can never be cached there, so the seat frame is a fixed ~2.5K-token system prompt,
# like a real seat's genome: system + block cross 4608, and the first chunk is the stable part.
FRAME = open(f"{HOME}/.claude/rules/05-activation-layer.md").read()


def conversation(port, host, memory_msg, nonce, stamped=False):
    msgs = [{"role": "system", "content": f"Session {nonce}.\n{FRAME}\nYou are the assistant. Answer briefly."}]
    out = []
    for t, u in enumerate(TURNS):
        msgs.append({"role": "user", "content": u})
        send = list(msgs)
        if memory_msg is not None:
            mm = dict(memory_msg)
            if stamped:  # control: a block that changes every turn must lose the cache
                mm["content"] = f"[built {time.time():.6f}]\n" + mm["content"]
            send.insert(1, mm)
        h0, q0, running = metrics()
        r = call(port, host, dict(BASE, max_tokens=120, messages=send), stream=True)
        h1, q1, _ = metrics()
        out.append({"turn": t + 1, "ttft_ms": round(r["ttft"] * 1000, 1), "decode_tps": round(r["decode_tps"], 1), "prompt_tokens": r["usage"]["prompt_tokens"],
                    "hits": h1 - h0, "queries": q1 - q0, "others_running": running})
        msgs.append({"role": "assistant", "content": r["content"]})
    return out


def stage_B():
    mem = json.load(open(f"{REC}/memory_message.json"))
    px = Proxy(f"http://{UP_HOST}:{UP_PORT}", SEED, f"{REC}/B_proxy.log")
    runs = {}
    stamp = int(time.time())
    for i, kind in enumerate(["direct", "proxy", "proxy", "direct", "control_stamped"]):  # ABBA + control, fresh nonce each run
        nonce = f"{stamp}-{i}"
        if kind == "proxy":
            runs[f"{i}_{kind}"] = conversation(PX_PORT, "127.0.0.1", None, nonce)
        else:
            runs[f"{i}_{kind}"] = conversation(UP_PORT, UP_HOST, mem, nonce, stamped=(kind == "control_stamped"))
        print(kind, runs[f"{i}_{kind}"])
    px.stop()
    lines = open(f"{REC}/B_proxy.log").read().splitlines()
    proxy_us = [int(re.search(r"proxy_us=(\d+)", l).group(1)) for l in lines if "proxy_us=" in l]
    summ = {}
    for kind in ("direct", "proxy", "control_stamped"):
        rs = [v for k, v in runs.items() if k.endswith(kind)]
        later = [t for r in rs for t in r if t["turn"] > 1]
        summ[kind] = {"ttft_ms_p50_turns2_6": statistics.median(t["ttft_ms"] for t in later),
                      "ttft_ms_turn1": [r[0]["ttft_ms"] for r in rs],
                      "decode_tps_p50": statistics.median(t["decode_tps"] for r in rs for t in r),
                      "hit_rate_turns2_6": round(sum(t["hits"] for t in later) / max(1, sum(t["queries"] for t in later)), 4),
                      "prompt_tokens_turn6": [r[-1]["prompt_tokens"] for r in rs]}
    summ["proxy_us_p50"] = statistics.median(proxy_us); summ["proxy_us_max"] = max(proxy_us); summ["proxy_requests"] = len(proxy_us)
    print(json.dumps(summ, indent=1)); json.dump({"runs": runs, "summary": summ}, open(f"{REC}/B.json", "w"), indent=1)


def stage_C():
    sys.path.insert(0, f"{HOME}/bench_eval"); sys.path.insert(0, f"{HOME}/bench_lane")
    import bench  # read-only import: question sets + the same truth/dead regex grading
    qs = [(q, t, d) for q, t, d, _ in bench.ITEMS] + [(q, t, []) for q, t, _ in bench.BENCH91] + [(q, t, []) for q, t in bench.HISTORY]
    pick = [qs[i * len(qs) // 30] for i in range(30)]
    sysmsg = {"role": "system", "content": "You are the assistant, this household's companion. Answer in one or two sentences. If you do not know, say so."}
    px = Proxy(f"http://{UP_HOST}:{UP_PORT}", SEED, f"{REC}/C_proxy.log")
    rows = []
    for q, truth, dead in pick:
        body = dict(BASE, max_tokens=200, messages=[sysmsg, {"role": "user", "content": q}])
        a = call(UP_PORT, UP_HOST, body)["content"]; b = call(PX_PORT, "127.0.0.1", body)["content"]
        g = lambda s: bool(re.search(truth, s, re.I)); l = lambda s: bool(bench.dead_hits(s, dead))
        rows.append({"q": q, "no_mem_hit": g(a), "mem_hit": g(b), "no_mem_leak": l(a), "mem_leak": l(b), "no_mem": a, "mem": b})
        print(rows[-1]["no_mem_hit"], rows[-1]["mem_hit"], q[:60])
    px.stop()
    res = {"n": len(rows), "no_memory_hits": sum(r["no_mem_hit"] for r in rows), "memory_hits": sum(r["mem_hit"] for r in rows),
           "no_memory_leaks": sum(r["no_mem_leak"] for r in rows), "memory_leaks": sum(r["mem_leak"] for r in rows)}
    print(res); json.dump({"summary": res, "rows": rows}, open(f"{REC}/C.json", "w"), indent=1)


if __name__ == "__main__":
    {"A0": stage_A0, "A": stage_A, "B": stage_B, "C": stage_C}[sys.argv[1]]()
