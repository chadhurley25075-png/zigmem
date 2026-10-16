#!/bin/bash
# Phase-4 gate: a REAL Claude Code client talks to zigmem over MCP (streamable HTTP).
# Registers the server TEMPORARILY with `claude mcp add --scope local` inside a scratch dir only, runs `claude -p`
# there with every hook disabled (user settings not loaded), then removes the registration and proves it is gone.
# Synthetic data only. The server is stopped by PID and verified gone.
set -u
export PATH=$HOME/.nvm/versions/node/v22.22.3/bin:$HOME/.local/bin:$PATH
ROOT=$HOME/zigmem; Z=$ROOT/zig-out/bin/zigmem; PORT=18159; NAME=zigmem-p4test
H=$ROOT/scratch/p4/mcp_home; W=$ROOT/scratch/p4/mcp_client; R=$ROOT/receipts/phase4; mkdir -p $R
rm -rf "$H" "$W"; mkdir -p "$W"
out() { echo "$*" | tee -a $R/mcp_claude.txt; }
: > $R/mcp_claude.txt
out "claude version: $(claude --version 2>&1)"
TOK=$($Z token add --home "$H" --seat seat-mcp --scopes syn-m)
TW=$($Z token add --home "$H" --seat seat-seed --scopes syn-m,syn-other --writes --trusted)
$Z serve --home "$H" --port $PORT > "$H/serve.log" 2>&1 &
SP=$!
sleep 0.5
# synthetic seed: one turn via the API, two atoms (one in a scope the MCP seat cannot see)
curl -s -XPOST localhost:$PORT/v1/capture -H "Authorization: Bearer $TW" -d '{"user_content":"Ana keeps the lantern in the blue shed.","session_key":"seed"}' >/dev/null
python3 - "$H/zigmem.db" <<'EOF'
import sqlite3, sys, os, time
con = sqlite3.connect(sys.argv[1])
for scope, subj, text in [("syn-m", "ana", "Ana keeps the lantern in the blue shed."), ("syn-other", "ben", "Ben keeps the lantern key under the porch step.")]:
    con.execute("INSERT INTO atoms(lineage, subject, scope, type, priority, text, recorded_ms, status, sha256) VALUES (?,?,?,?,?,?,?,?,?)",
                ("Lseed" + subj, subj, scope, "fact", 50, text, int(time.time() * 1000), "active", os.urandom(32)))
con.commit()
EOF
cd "$W"
out "--- claude mcp add --scope local (in $W)"
claude mcp add --scope local --transport http $NAME http://127.0.0.1:$PORT/mcp --header "Authorization: Bearer $TOK" 2>&1 | tee -a $R/mcp_claude.txt
out "--- claude mcp list"
claude mcp list 2>&1 | grep -i "$NAME" | tee -a $R/mcp_claude.txt
out "--- claude -p (hooks disabled, user settings not loaded)"
PROMPT="Use the $NAME MCP server. First call its memory_search tool with query 'lantern'. Then call memory_get with the id of the first hit. Then call memory_block with session_key 'p4'. Reply with exactly three lines: SUBJECT=<subject> TEXT=<text of the atom> HITS=<number of hits memory_search returned>."
timeout 300 claude -p "$PROMPT" --setting-sources project,local --settings '{"disableAllHooks":true}' \
  --allowedTools "mcp__${NAME}__memory_search,mcp__${NAME}__memory_get,mcp__${NAME}__memory_block" \
  --output-format text > $R/mcp_claude_answer.txt 2>&1
echo "claude -p rc=$?" | tee -a $R/mcp_claude.txt
cat $R/mcp_claude_answer.txt | tee -a $R/mcp_claude.txt
out "--- server audit (MCP lines: method/tool/status only, no arguments)"
grep '"/mcp"' "$H/audit.log" | tee -a $R/mcp_claude.txt
out "--- claude mcp remove --scope local"
claude mcp remove --scope local $NAME 2>&1 | tee -a $R/mcp_claude.txt
out "--- verify removal"
if claude mcp list 2>&1 | grep -qi "$NAME"; then out "STILL LISTED: FAIL"; else out "not listed: ok"; fi
if grep -q "$NAME" $HOME/.claude.json; then out "name still in ~/.claude.json: FAIL"; else out "name absent from ~/.claude.json: ok"; fi
if grep -q "$TOK" $HOME/.claude.json; then out "token still in ~/.claude.json: FAIL"; else out "token absent from ~/.claude.json: ok"; fi
cd "$ROOT"
kill $SP; sleep 0.5
if kill -0 $SP 2>/dev/null; then out "server pid $SP STILL ALIVE"; else out "server pid $SP gone"; fi
