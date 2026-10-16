#!/usr/bin/env bash
# zigmem deploy — ONE command. Default = SHADOW: the hub runs on 127.0.0.1 with an imported copy of the memory stores;
# no live seat reads from it (no MCP registration, no hook, no seat config touched).
#
#   ~/zigmem/deploy/deploy.sh                 preflight → install unit → start → health → print what changed
#   ~/zigmem/deploy/deploy.sh --dry-run       preflight only, changes nothing
#   ~/zigmem/deploy/deploy.sh --wire claude-code           PRINT the per-seat adapter (changes nothing)
#   ~/zigmem/deploy/deploy.sh --wire claude-code --apply   register it (Alex's call; recorded so rollback.sh undoes it)
#   SHADOW needs every SAFETY gate green (leaks, auth, bind, fuzz, kill -9, soak, round trip); gate 3 (hub 130-q >= live) is a
#   printed warning. --wire ALSO needs gate 3 green and refuses otherwise, naming the score gap.
#   undo everything: ~/zigmem/deploy/rollback.sh
#
# Options: --port N (default 8470) · --data DIR (default ~/zigmem_data) · --no-seed (start with an empty store)
# Test hooks (env): ZIGMEM_SYSTEMCTL (fake systemctl for the scratch round trip), ZIGMEM_MIN_FREE_GB (default 10).
# Refuses (exit 1, nothing changed) if ANY preflight fails. Paths derive from $HOME. Never needs root.
set -uo pipefail
umask 077
ZM="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
REL_DIR="${ZIGMEM_RELEASE_DIR:-$ZM/deploy/release}"; REL="$REL_DIR/RELEASE.json"; RBIN="$REL_DIR/zigmem"
export ZM_ROOT="$ZM"; KIT="/usr/bin/python3 -I $ZM/deploy/zm_kit.py"
DATA="${ZIGMEM_DATA:-$HOME/zigmem_data}"; PORT=8470
STATE="$HOME/.local/state/zigmem-deploy"; MAN="$STATE/manifest.json"
UNIT_DIR="$HOME/.config/systemd/user"; UNIT_NAME=zigmem.service; UNIT="$UNIT_DIR/$UNIT_NAME"
TOKDIR="$HOME/.config/zigmem"
SC="${ZIGMEM_SYSTEMCTL:-systemctl}"
CLAUDE="${ZIGMEM_CLAUDE:-$(command -v claude || ls -1 "$HOME"/.nvm/versions/node/*/bin/claude 2>/dev/null | tail -1)}"; MIN_FREE_GB="${ZIGMEM_MIN_FREE_GB:-10}"
WIRE_SCOPES=household   # zigmem connect accepts only named scopes; the shadow import lives in scope household
SHADOW_SEAT=shadow; SHADOW_SCOPES="*"   # read-only; the household binds seat shadow to alex (deploy/household.json)
DRY=0; WIRE=""; APPLY=0; SEED=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --port) PORT="$2"; shift ;;
    --data) DATA="$2"; shift ;;
    --no-seed) SEED=0 ;;
    --wire) WIRE="$2"; shift ;;
    --apply) APPLY=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "deploy.sh: unknown option $1" >&2; exit 64 ;;
  esac; shift
done
case "$PORT" in ''|*[!0-9]*) echo "deploy.sh: bad --port" >&2; exit 64 ;; esac
case "$DATA" in /*) ;; *) echo "deploy.sh: --data must be absolute" >&2; exit 64 ;; esac
BASE="http://127.0.0.1:$PORT"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$STATE/deploy.log"; }
mkdir -p -m 700 "$STATE"

# ---------------- --wire: per-seat adapter (prints by default; --apply registers and records it) ----------------
if [ -n "$WIRE" ]; then
  [ -f "$MAN" ] && [ "$($KIT mget "$MAN" status)" = deployed ] || { echo "deploy.sh --wire: zigmem is not deployed (run deploy.sh first)"; exit 1; }
  BIN="$DATA/bin/zigmem"; TOK="$TOKDIR/$WIRE.token"
  # Alex's law: a seat reads zigmem only when it beats what the seat has now AND leaks nothing → gate 3 is REQUIRED here.
  echo "zigmem --wire $WIRE — release check (wire: safety + gate 3 quality)"
  $KIT release-check "$REL" "$RBIN" wire | tee "$STATE/preflight-wire.txt"
  if [ "${PIPESTATUS[0]}" != 0 ]; then echo "REFUSED: --wire needs every gate green, including gate 3 (hub 130-q >= live, same night). Nothing changed."; exit 1; fi
  [ "$(sha256sum < "$BIN" | cut -d' ' -f1)" = "$($KIT mget "$REL" sha256)" ] || { echo "REFUSED: the running binary is not the qualified release (redeploy first). Nothing changed."; exit 1; }
  case "$WIRE" in
    claude-code)
      "$BIN" connect claude-code --print --url "$BASE" --seat "$WIRE" --scopes "$WIRE_SCOPES" --token-file "$TOK" --scope user --adapters "$ZM/adapters" --zigmem "$BIN" || exit 1
      [ $APPLY = 1 ] || { echo; echo "# (printed only — nothing changed. Add --apply to register it; rollback.sh undoes it.)"; exit 0; }
      [ -x "$CLAUDE" ] || { echo "deploy.sh --wire: claude CLI not found"; exit 1; }
      $KIT snapshot "$STATE/pre-wire-$WIRE.json"
      install -d -m 700 "$TOKDIR"
      [ -e "$TOK" ] && { echo "deploy.sh --wire: $TOK exists; refusing to overwrite"; exit 1; }
      "$BIN" token add --seat "$WIRE" --scopes "$WIRE_SCOPES" --home "$DATA" > "$TOK.tmp" && chmod 600 "$TOK.tmp" && mv "$TOK.tmp" "$TOK" || { echo "token add failed"; exit 1; }
      $KIT madd "$MAN" seats "\"$WIRE\""; $KIT madd "$MAN" token_files "\"$TOK\""
      json="{\"type\":\"http\",\"url\":\"$BASE/mcp\",\"headersHelper\":\"$ZM/adapters/claude-code/zigmem_headers.sh $TOK\"}"
      "$CLAUDE" mcp add-json --scope user zigmem "$json" || { echo "claude mcp add-json failed"; exit 1; }
      $KIT madd "$MAN" registrations '{"kind":"claude-mcp","scope":"user","name":"zigmem"}'
      log "wired claude-code (user-scope MCP 'zigmem', headersHelper, token $TOK)"
      "$CLAUDE" mcp get zigmem 2>&1 | head -8; exit 0 ;;
    pi|openai|codex|openclaw|hermes)
      "$BIN" connect "$WIRE" --print --url "$BASE" --seat "$WIRE" --scopes "$WIRE_SCOPES" --token-file "$TOK" --adapters "$ZM/adapters" --zigmem "$BIN"
      [ $APPLY = 1 ] && echo "# --apply is only automated for claude-code; for $WIRE the lines above are what you run (nothing changed)."
      exit 0 ;;
    *) echo "deploy.sh --wire: unknown seat '$WIRE' (claude-code|pi|openai|codex|openclaw|hermes)"; exit 64 ;;
  esac
fi

# ---------------- preflight (no changes) ----------------
FAIL=0
chk() { if [ "$1" = 0 ]; then echo "  PASS  $2"; else echo "  FAIL  $2"; FAIL=1; fi; }
echo "zigmem deploy — preflight ($(hostname), HOME=$HOME, port $PORT, data $DATA)"
[ "$(id -u)" != 0 ]; chk $? "not root"
$KIT release-check "$REL" "$RBIN" shadow | tee "$STATE/preflight-release.txt"; chk "${PIPESTATUS[0]}" "release: binary, -Drelease, arch, tested sha, every SAFETY gate green (gate 3 quality = warning only in shadow)"
if [ -f "$MAN" ] && [ "$($KIT mget "$MAN" status)" = deployed ]; then chk 1 "not already deployed (manifest says deployed — run rollback.sh first)"; else chk 0 "not already deployed"; fi
[ ! -e "$UNIT" ]; chk $? "no $UNIT yet"
[ -z "$(ss -Hltn "sport = :$PORT" 2>/dev/null)" ]; chk $? "port 127.0.0.1:$PORT free"
RENDER="$STATE/zigmem.service.rendered"
sed -e "s#@DATA@#$DATA#g" -e "s#@PORT@#$PORT#g" "$ZM/deploy/zigmem.service" > "$RENDER"
EXEC=$(sed -n 's/^ExecStart=//p' "$RENDER")
{ [ "$(grep -o -- '--bind [^ ]*' <<<"$EXEC")" = "--bind 127.0.0.1" ] && ! grep -q '0\.0\.0\.0' "$RENDER" && [ "$(grep -c '^ExecStart=' "$RENDER")" = 1 ]; }; chk $? "unit binds 127.0.0.1 only ($EXEC)"
grep -q -- "--extract none" <<<"$EXEC"; chk $? "shadow: extraction off (no engine traffic)"
SEED_DB=""; [ $SEED = 1 ] && SEED_DB=$(/usr/bin/python3 -I -c 'import json,os,sys
try: v=json.load(open(sys.argv[1])).get("seed_db")
except Exception: v=None
print(os.path.expanduser(v) if v else "")' "$REL")
need=$(( MIN_FREE_GB * 1024 * 1024 * 1024 )); [ -n "$SEED_DB" ] && [ -f "$SEED_DB" ] && need=$(( need + $(stat -c %s "$SEED_DB") ))
mkdir -p "$(dirname "$DATA")"; free=$(df -B1 --output=avail "$(dirname "$DATA")" | tail -1 | tr -d ' ')
[ "$free" -ge "$need" ]; chk $? "disk: $((free/1024/1024/1024)) GB free ≥ $((need/1024/1024/1024)) GB needed"
if [ -e "$DATA/zigmem.db" ]; then echo "  NOTE  $DATA/zigmem.db exists (kept from an earlier deploy; not re-seeded)"; SEED_DB=""; fi
[ ! -e "$TOKDIR/$SHADOW_SEAT.token" ]; chk $? "no $TOKDIR/$SHADOW_SEAT.token yet"
$SC --user show-environment >/dev/null 2>&1; chk $? "systemctl --user reachable ($SC)"
command -v curl >/dev/null; chk $? "curl present"
if [ $FAIL != 0 ]; then echo "REFUSED: preflight failed — nothing was changed."; exit 1; fi
if [ $DRY = 1 ]; then echo "DRY RUN: preflight green — would install $UNIT (sha $(sha256sum < "$RENDER" | cut -c1-16)), data $DATA, seed ${SEED_DB:-none}, seat $SHADOW_SEAT. Nothing changed."; exit 0; fi

# ---------------- act ----------------
log "deploy start (port $PORT, data $DATA)"
$KIT snapshot "$STATE/pre.json"
$KIT mset "$MAN" status '"deploying"'; $KIT mset "$MAN" started "\"$(date -Is)\""; $KIT mset "$MAN" host "\"$(hostname)\""
$KIT mset "$MAN" port "$PORT"; $KIT mset "$MAN" data "\"$DATA\""; $KIT mset "$MAN" unit "\"$UNIT\""
$KIT mset "$MAN" seats '[]'; $KIT mset "$MAN" token_files '[]'; $KIT mset "$MAN" registrations '[]'
$KIT mset "$MAN" data_created "$([ -e "$DATA" ] && echo false || echo true)"
abort() { log "deploy FAILED: $1 — rolling back"; "$ZM/deploy/rollback.sh" --auto; exit 1; }
install -d -m 700 "$DATA" "$DATA/bin" || abort "mkdir $DATA"
install -m 700 "$RBIN" "$DATA/bin/zigmem.tmp" && mv "$DATA/bin/zigmem.tmp" "$DATA/bin/zigmem" || abort "install binary"
BSHA=$(sha256sum < "$DATA/bin/zigmem" | cut -d' ' -f1)
[ "$BSHA" = "$($KIT mget "$REL" sha256)" ] || abort "installed binary sha mismatch"
$KIT mset "$MAN" bin_sha256 "\"$BSHA\""
if [ -n "$SEED_DB" ]; then
  log "seeding store from $SEED_DB ($(du -h "$SEED_DB" | cut -f1))"
  cp --reflink=auto "$SEED_DB" "$DATA/zigmem.db.tmp" && chmod 600 "$DATA/zigmem.db.tmp" || abort "copy seed"
  [ "$(sha256sum < "$DATA/zigmem.db.tmp" | cut -d' ' -f1)" = "$($KIT mget "$REL" seed_sha256)" ] || abort "seed copy sha mismatch"
  mv "$DATA/zigmem.db.tmp" "$DATA/zigmem.db"; $KIT mset "$MAN" seeded_from "\"$SEED_DB\""
fi
# integrated binary: identity = token → seat → household member. Bootstrap the household once (seats shadow + claude-code → alex).
if "$DATA/bin/zigmem" household list --home "$DATA" 2>&1 | grep -q '^seat shadow'; then log "household already bootstrapped"; else
  "$DATA/bin/zigmem" household bootstrap --home "$DATA" --file "$ZM/deploy/household.json" >>"$STATE/deploy.log" 2>&1 || abort "household bootstrap"
  $KIT mset "$MAN" household_bootstrapped true; fi
install -d -m 700 "$TOKDIR"
"$DATA/bin/zigmem" token add --seat "$SHADOW_SEAT" --scopes "$SHADOW_SCOPES" --home "$DATA" > "$TOKDIR/$SHADOW_SEAT.token.tmp" 2>"$STATE/token.err" || abort "token add: $(cat "$STATE/token.err")"
chmod 600 "$TOKDIR/$SHADOW_SEAT.token.tmp" && mv "$TOKDIR/$SHADOW_SEAT.token.tmp" "$TOKDIR/$SHADOW_SEAT.token"
grep -qE '^zm_[0-9a-f]{64}$' "$TOKDIR/$SHADOW_SEAT.token" || abort "token format"
$KIT madd "$MAN" seats "\"$SHADOW_SEAT\""; $KIT madd "$MAN" token_files "\"$TOKDIR/$SHADOW_SEAT.token\""
install -d -m 700 "$UNIT_DIR"; install -m 644 "$RENDER" "$UNIT" || abort "install unit"
$KIT mset "$MAN" unit_sha256 "\"$(sha256sum < "$UNIT" | cut -d' ' -f1)\""
$SC --user daemon-reload || abort "daemon-reload"
$SC --user enable --now "$UNIT_NAME" >>"$STATE/deploy.log" 2>&1 || abort "enable --now"
$KIT mset "$MAN" enabled true
# health: /health 200, an authenticated recall 200, listening on 127.0.0.1:PORT only, the PID is systemd's MainPID
ok=0; for i in $(seq 1 600); do [ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$BASE/health")" = 200 ] && { ok=1; break; }   # the vector index loads first
  st=$($SC --user is-active "$UNIT_NAME" 2>/dev/null); [ $i -gt 4 ] && { [ "$st" = failed ] || [ "$st" = inactive ]; } && abort "service is $st before /health answered"
  sleep 0.5; done
[ $ok = 1 ] || abort "/health never answered 200 in 300 s"
H=$(curl -s -m 5 "$BASE/health")
R=$(curl -s -o /dev/null -w '%{http_code}' -m 30 "$BASE/v1/recall" -H "Authorization: Bearer $(cat "$TOKDIR/$SHADOW_SEAT.token")" -H 'Content-Type: application/json' -d '{"query":"deploy health check"}')
[ "$R" = 200 ] || abort "authenticated /v1/recall returned $R"
U=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$BASE/v1/recall" -H 'Content-Type: application/json' -d '{"query":"x"}')
[ "$U" = 401 ] || abort "unauthenticated /v1/recall returned $U (want 401)"
L=$(ss -Hltnp 2>/dev/null | grep -E ":$PORT\b" | awk '{print $4}' | sort -u | tr '\n' ' ')
[ "$L" = "127.0.0.1:$PORT " ] || abort "listening on '$L' (want 127.0.0.1:$PORT only)"
MAINPID=$($SC --user show -p MainPID --value "$UNIT_NAME"); EXE=$(readlink "/proc/$MAINPID/exe" 2>/dev/null)
[ "$EXE" = "$DATA/bin/zigmem" ] || abort "MainPID $MAINPID runs '$EXE'"
$KIT mset "$MAN" status '"deployed"'; $KIT mset "$MAN" deployed "\"$(date -Is)\""
log "deploy OK pid $MAINPID"
cat <<MSG

zigmem DEPLOYED (SHADOW). What changed:
  + $UNIT  (enabled; starts at boot via linger; Restart=on-failure)
  + $DATA/  (binary sha ${BSHA:0:16}, store$( [ -n "$SEED_DB" ] && echo " seeded from tonight's shadow import" ), token table)
  + $TOKDIR/$SHADOW_SEAT.token  (0600, read-only seat '$SHADOW_SEAT', scopes $SHADOW_SCOPES)
  + $STATE/  (manifest + pre-deploy shas + log)
What did NOT change: ~/.claude.json, ~/.claude/settings.json, ~/.pi, the typed store, the vector store, the cloud store, the journal, any seat.
Listening: 127.0.0.1:$PORT only (pid $MP). /health: $H
Watch:    systemctl --user status zigmem · journalctl --user -u zigmem -f · curl -s $BASE/health
Undo:     $ZM/deploy/rollback.sh
MSG
grep -q '^  WARN' "$STATE/preflight-release.txt" && { echo; echo "⚠ GATE 3 (quality) is RED — shadow only. '--wire <seat>' will refuse until zigmem beats live:"; grep '^  WARN' "$STATE/preflight-release.txt"; }
exit 0
