// zigmem_memory.ts — zigmem adapter for pi seats (phase 7, 2026-10-12). STAGED, NOT INSTALLED.
//
// TOOLS ONLY. This file registers NO event handlers (no pi.on(...) of any kind): nothing is captured on its own,
// no prompt, tool call or session event leaves the seat unless the model calls one of these tools.
// Pattern copied from an earlier pi memory extension of ours (the handoff gateway extension).
//
// Talks ONLY to the zigmem hub's MCP endpoint (default http://127.0.0.1:8470/mcp; ZIGMEM_URL overrides the base,
// which must be http://127.0.0.1:PORT or a tailnet http://100.x:PORT). Token: ZIGMEM_TOKEN_FILE (default
// ~/.config/zigmem/pi.token), read per call, must be mode 0600. Tool list + schemas come from the hub's tools/list,
// so the hub stays the single source of truth; names are prefixed `zigmem_` so they never collide with the handoff gateway's.
//
// Load explicitly per run:   ZIGMEM_URL=... ZIGMEM_TOKEN_FILE=... pi -e <this file> ...
// (`zigmem connect pi --print` prints the exact line.) Nothing here writes to ~/.pi.

import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const BASE = (process.env.ZIGMEM_URL ?? "http://127.0.0.1:8470").replace(/\/+$/, "");
const ENDPOINT = `${BASE}/mcp`;
const TOKEN_FILE = process.env.ZIGMEM_TOKEN_FILE ?? join(homedir(), ".config", "zigmem", "pi.token");
const TIMEOUT_MS = 20000;
const PREFIX = "zigmem_";
let rpcId = 0;

function allowedBase(u: string): boolean {
  const m = /^http:\/\/(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3}):(\d{1,5})$/.exec(u);
  if (!m) return false;
  const [a, b, c, d] = m.slice(1, 5).map(Number);
  if (a === 127 && b === 0 && c === 0 && d === 1) return true;
  return a === 100 && b >= 64 && b <= 127 && c <= 255 && d <= 255;
}

function token(): string {
  const st = statSync(TOKEN_FILE);
  if ((st.mode & 0o777) !== 0o600) throw new Error("zigmem token file must be mode 0600");
  const t = readFileSync(TOKEN_FILE, "utf8").trim();
  if (!/^zm_[0-9a-f]{64}$/.test(t)) throw new Error("zigmem token file does not hold a zigmem token");
  return t;
}

async function rpc(method: string, params: unknown, signal?: AbortSignal): Promise<any> {
  if (!allowedBase(BASE)) throw new Error("ZIGMEM_URL must be http://127.0.0.1:PORT or http://100.64-127.x.x:PORT");
  const t = AbortSignal.timeout(TIMEOUT_MS);
  const anyOf = (AbortSignal as any).any;
  const sig = signal && anyOf ? anyOf([signal, t]) : t;
  const r = await fetch(ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Accept": "application/json", "Authorization": `Bearer ${token()}` },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params: params ?? {} }),
    signal: sig,
  });
  if (!r.ok) throw new Error(`zigmem ${method}: HTTP ${r.status}`);
  const p = await r.json();
  if (p?.error) throw new Error(`zigmem ${method}: ${p.error.message ?? JSON.stringify(p.error)}`);
  return p?.result;
}

async function bootstrap(pi: any): Promise<void> {
  try {
    await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "pi-zigmem", version: "1" } });
    const listed = await rpc("tools/list", {});
    for (const tool of listed?.tools ?? []) {
      const remote = String(tool.name);
      try {
        pi.registerTool({
          name: PREFIX + remote,
          label: PREFIX + remote,
          description: `[zigmem] ${tool.description}`,
          promptSnippet: `${PREFIX}${remote}: ${String(tool.description).split(". ")[0]}`,
          parameters: tool.inputSchema ?? { type: "object", properties: {} },
          execute: async (_id: string, params: unknown, signal?: AbortSignal) => {
            const res = await rpc("tools/call", { name: remote, arguments: params ?? {} }, signal);
            return { content: res?.content ?? [{ type: "text", text: JSON.stringify(res) }], details: { isError: !!res?.isError } };
          },
        });
      } catch (_e) { /* duplicate/shape mismatch must not break the seat */ }
    }
  } catch (_e) { /* hub down or token missing → the seat simply has no zigmem tools this session */ }
}

export default function ZigmemMemory(pi: any): void {
  void bootstrap(pi);
}
