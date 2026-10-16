#!/usr/bin/env bash
# zigmem rollback — ONE command. Undoes exactly what deploy.sh recorded in its manifest:
#   undo any --wire registration (claude mcp remove) → stop + disable the unit → remove the unit file (only if it is
#   byte-for-byte the one deploy.sh wrote) → revoke the seats it minted + remove their token files → verify nothing is
#   listening and no zigmem process runs → verify ~/.claude.json, ~/.claude/settings.json, ~/.pi, ~/.codex, ~/.openclaw and
#   ~/.config/systemd/user are back to the pre-deploy sha.
# The data dir (~/zigmem_data: the shadow store + token table) is KEPT; delete it by hand if you want it gone.
#   ~/zigmem/deploy/rollback.sh        exit 0 = rolled back and sha-identical (or only Claude Code's own bookkeeping
#                                      changed in ~/.claude.json — printed), 1 = something needs a human (printed)
set -uo pipefail
ZM="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
KIT="/usr/bin/python3 -I $ZM/deploy/zm_kit.py"
STATE="$HOME/.local/state/zigmem-deploy"; MAN="$STATE/manifest.json"
UNIT_NAME=zigmem.service; UNIT="$HOME/.config/systemd/user/$UNIT_NAME"
SC="${ZIGMEM_SYSTEMCTL:-systemctl}"
CLAUDE="${ZIGMEM_CLAUDE:-$(command -v claude || ls -1 "$HOME"/.nvm/versions/node/*/bin/claude 2>/dev/null | tail -1)}"
AUTO=0; [ "${1:-}" = "--auto" ] && AUTO=1
mkdir -p -m 700 "$STATE"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$STATE/deploy.log"; }
BAD=0; step() { if [ "$1" = 0 ]; then echo "  OK    $2"; else echo "  FAIL  $2"; BAD=1; fi; }
[ -f "$MAN" ] || { echo "rollback: no manifest at $MAN — nothing recorded to undo."; [ -e "$UNIT" ] && echo "  but $UNIT exists (not written by deploy.sh?) — left alone."; exit 1; }
PORT=$($KIT mget "$MAN" port); DATA=$($KIT mget "$MAN" data)
log "rollback start (status $($KIT mget "$MAN" status), auto=$AUTO)"
# 1. registrations, newest first
while read -r kind scope name; do
  case "$kind" in
    claude-mcp) "$CLAUDE" mcp remove --scope "$scope" "$name" >/dev/null 2>&1; "$CLAUDE" mcp get "$name" >/dev/null 2>&1; [ $? != 0 ]; step $? "removed Claude Code MCP '$name' ($scope scope)" ;;
    *) step 1 "unknown registration kind $kind — undo by hand" ;;
  esac
done < <(/usr/bin/python3 -I -c 'import json,sys;[print(r["kind"],r["scope"],r["name"]) for r in reversed(json.load(open(sys.argv[1])).get("registrations",[]))]' "$MAN")
# 2. unit
if [ -e "$UNIT" ] || $SC --user is-enabled --quiet "$UNIT_NAME" 2>/dev/null; then
  $SC --user disable --now "$UNIT_NAME" >>"$STATE/deploy.log" 2>&1
  ! $SC --user is-active --quiet "$UNIT_NAME"; step $? "unit stopped"
  ! $SC --user is-enabled --quiet "$UNIT_NAME" 2>/dev/null; step $? "unit disabled"
fi
if [ -e "$UNIT" ]; then
  if [ "$(sha256sum < "$UNIT" | cut -d' ' -f1)" = "$($KIT mget "$MAN" unit_sha256)" ]; then
    unlink "$UNIT"; [ ! -e "$UNIT" ]; step $? "removed $UNIT"
  else
    mv "$UNIT" "$STATE/zigmem.service.modified-$(date +%s)"; step 1 "$UNIT was edited after deploy — moved to $STATE, check it"
  fi
fi
$SC --user daemon-reload >/dev/null 2>&1; $SC --user reset-failed "$UNIT_NAME" >/dev/null 2>&1
# 3. seats + token files deploy.sh minted (the token table itself stays in the data dir, seats marked revoked)
for s in $(/usr/bin/python3 -I -c 'import json,sys;print(" ".join(json.load(open(sys.argv[1])).get("seats",[])))' "$MAN"); do
  [ -x "$DATA/bin/zigmem" ] && "$DATA/bin/zigmem" token revoke --seat "$s" --home "$DATA" >/dev/null 2>&1; step 0 "seat '$s' revoked"
done
for f in $(/usr/bin/python3 -I -c 'import json,sys;print(" ".join(json.load(open(sys.argv[1])).get("token_files",[])))' "$MAN"); do
  [ -e "$f" ] && unlink "$f"; [ ! -e "$f" ]; step $? "removed $f"
done
rmdir "$HOME/.config/zigmem" 2>/dev/null
# 4. nothing left running / listening
for i in $(seq 1 50); do [ -z "$(ss -Hltn "sport = :$PORT" 2>/dev/null)" ] && break; sleep 0.2; done
[ -z "$(ss -Hltn "sport = :$PORT" 2>/dev/null)" ]; step $? "nothing listening on :$PORT"
left=""; for p in /proc/[0-9]*; do [ "$(readlink "$p/exe" 2>/dev/null)" = "$DATA/bin/zigmem" ] && left="$left ${p#/proc/}"; done
[ -z "$left" ]; step $? "no process running $DATA/bin/zigmem${left:+ (pids$left)}"
# 5. guarded files back to the pre-deploy sha
if [ -f "$STATE/pre.json" ]; then
  $KIT compare "$STATE/pre.json" | sed 's/^/        /'; rc=${PIPESTATUS[0]}
  case $rc in
    0) step 0 "guarded files sha-identical to pre-deploy" ;;
    2) step 0 "guarded files identical except Claude Code's own bookkeeping keys in ~/.claude.json (no zigmem entry, no token)" ;;
    *) step 1 "guarded files differ from pre-deploy (see lines above)" ;;
  esac
else step 1 "no pre-deploy snapshot to compare"; fi
$KIT mset "$MAN" status "\"$([ $BAD = 0 ] && echo rolled_back || echo rollback_incomplete)\""; $KIT mset "$MAN" rolled_back "\"$(date -Is)\""
mkdir -p -m 700 "$STATE/history"; cp "$MAN" "$STATE/history/manifest-$(date +%Y%m%d-%H%M%S).json"
[ $BAD = 0 ] && { mv "$STATE/pre.json" "$STATE/history/pre-$(date +%Y%m%d-%H%M%S).json"; unlink "$MAN"; }
log "rollback $([ $BAD = 0 ] && echo OK || echo INCOMPLETE)"
echo; [ $BAD = 0 ] && echo "zigmem ROLLED BACK. Data kept at $DATA (shadow store; remove by hand if wanted)." || echo "zigmem rollback INCOMPLETE — read the FAIL lines above."
exit $BAD
