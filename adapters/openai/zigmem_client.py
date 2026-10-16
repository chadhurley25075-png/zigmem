#!/usr/bin/env python3
"""zigmem proxy-mode client example (phase 7). Any OpenAI-compatible client works the same way: change the base URL
to the zigmem proxy, send the seat token as the API key (Authorization: Bearer — the proxy consumes it and never
forwards it upstream) and add one header, `x-zigmem-session`. Standard library only, so it runs anywhere.

    python3 zigmem_client.py --base http://127.0.0.1:18141/v1 --token-file ~/.config/zigmem/SEAT.token --session s "hello"

With the openai SDK instead:
    OpenAI(base_url="http://127.0.0.1:18141/v1", api_key=<seat token>,
           default_headers={"x-zigmem-session": "my-session"})
"""
import argparse, json, os, stat, sys, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--base", default="http://127.0.0.1:18141/v1")
ap.add_argument("--session", default="default")
ap.add_argument("--token-file", required=True, help="0600 file holding the seat token (zm_ + 64 hex)")
ap.add_argument("--model", default="glm-5.3-flash")
ap.add_argument("--system", default="You are a helpful assistant. Answer in one short sentence.")
ap.add_argument("--max-tokens", type=int, default=128)
ap.add_argument("--no-thinking", action="store_true", help="send chat_template_kwargs.enable_thinking=false (GLM)")
ap.add_argument("prompt")
a = ap.parse_args()
if not a.base.startswith(("http://127.0.0.1:", "http://100.")):
    sys.exit("refusing: the zigmem proxy listens on loopback (or a tailnet 100.x) only")
st = os.stat(a.token_file, follow_symlinks=False)
if not stat.S_ISREG(st.st_mode) or st.st_mode & 0o077 or st.st_uid != os.getuid():
    sys.exit("refusing: the token file must be a regular 0600 file we own")
tok = open(a.token_file).read().strip()
if not (tok.startswith("zm_") and len(tok) == 67):
    sys.exit("refusing: not a zigmem seat token")
body = {"model": a.model, "temperature": 0, "max_tokens": a.max_tokens,
        "messages": [{"role": "system", "content": a.system}, {"role": "user", "content": a.prompt}]}
if a.no_thinking:
    body["chat_template_kwargs"] = {"enable_thinking": False}
req = urllib.request.Request(a.base.rstrip("/") + "/chat/completions", data=json.dumps(body).encode(),
                             headers={"Content-Type": "application/json", "x-zigmem-session": a.session, "Authorization": f"Bearer {tok}"})
with urllib.request.urlopen(req, timeout=120) as r:
    out = json.load(r)
print(out["choices"][0]["message"].get("content") or "")
