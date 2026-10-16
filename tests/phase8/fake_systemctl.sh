#!/usr/bin/env bash
# Fake `systemctl --user` for the phase-8 scratch round trip. Implements only what deploy.sh / rollback.sh call.
# Launches ExecStart from $HOME/.config/systemd/user/<unit> (%h -> $HOME), tracks the pid in $HOME/.fake_systemd/,
# and creates/removes the default.target.wants symlink exactly like `systemctl --user enable/disable`.
set -u
[ "${1:-}" = "--user" ] || { echo "fake_systemctl: only --user" >&2; exit 1; }
shift
UD="$HOME/.config/systemd/user"; FS="$HOME/.fake_systemd"; mkdir -p "$FS"
alive() { local p; p=$(cat "$FS/$1.pid" 2>/dev/null) || return 1; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
start() {
  local u="$1" f="$UD/$1" cmd
  [ -f "$f" ] || { echo "Unit $u not found." >&2; return 5; }
  alive "$u" && return 0
  cmd=$(sed -n 's/^ExecStart=//p' "$f" | sed "s#%h#$HOME#g")
  [ "${ZIGMEM_FAKE_START_FAIL:-0}" = 1 ] && cmd=/bin/false   # RED test: the service dies on start
  env $(sed -n 's/^Environment=//p' "$f" | sed "s#%h#$HOME#g") setsid bash -c "umask 077; exec $cmd" >"$FS/$u.log" 2>&1 </dev/null &
  echo $! > "$FS/$u.pid"; sleep 0.3
}
stop() {
  local u="$1" p i
  p=$(cat "$FS/$u.pid" 2>/dev/null) || return 0
  kill -TERM "$p" 2>/dev/null
  for i in $(seq 1 100); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null
  : > "$FS/$u.pid"
}
case "${1:-}" in
  daemon-reload|show-environment) exit 0 ;;
  enable) shift; now=0; [ "${1:-}" = "--now" ] && { now=1; shift; }
          mkdir -p "$UD/default.target.wants"; ln -sf "$UD/$1" "$UD/default.target.wants/$1"
          echo "Created symlink $UD/default.target.wants/$1 -> $UD/$1."; [ $now = 1 ] && start "$1"; exit $? ;;
  disable) shift; now=0; [ "${1:-}" = "--now" ] && { now=1; shift; }
          [ $now = 1 ] && stop "$1"; [ -L "$UD/default.target.wants/$1" ] && { unlink "$UD/default.target.wants/$1"; echo "Removed $UD/default.target.wants/$1."; }; exit 0 ;;
  start) start "$2"; exit $? ;;
  stop) stop "$2"; exit 0 ;;
  restart) stop "$2"; start "$2"; exit $? ;;
  is-active) shift; [ "${1:-}" = "--quiet" ] && shift; if alive "$1"; then echo active; exit 0; else echo inactive; exit 3; fi ;;
  is-enabled) shift; [ "${1:-}" = "--quiet" ] && shift; if [ -L "$UD/default.target.wants/$1" ]; then echo enabled; exit 0; else echo disabled; exit 1; fi ;;
  show) # show -p MainPID --value UNIT
        u="${@: -1}"; if alive "$u"; then cat "$FS/$u.pid"; else echo 0; fi; exit 0 ;;
  reset-failed) exit 0 ;;
  *) echo "fake_systemctl: unsupported: $*" >&2; exit 1 ;;
esac
