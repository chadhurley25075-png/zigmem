#!/bin/sh
# zigmem headersHelper for Claude Code (phase 7). Claude Code runs this at connect time and sends the JSON it prints
# as HTTP headers, so the seat token is never stored in ~/.claude.json.
# Usage (inside the headersHelper string): zigmem_headers.sh /abs/path/to/<seat>.token
# Refuses (exit 1, nothing printed) unless the token file is a regular file owned by us with mode 0600 and holds
# exactly one zigmem token (zm_ + 64 hex). Reads nothing else, writes nothing.
f="$1"
[ -n "$f" ] && [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ] || { echo "zigmem_headers: bad token file" >&2; exit 1; }
[ "$(stat -c %a "$f")" = "600" ] || { echo "zigmem_headers: token file must be mode 0600" >&2; exit 1; }
t=$(head -c 200 "$f" | tr -d '\n')
case "$t" in
  zm_*) ;;
  *) echo "zigmem_headers: not a zigmem token" >&2; exit 1 ;;
esac
h=${t#zm_}
[ ${#h} -eq 64 ] && [ -z "$(printf %s "$h" | tr -d 0-9a-f)" ] || { echo "zigmem_headers: not a zigmem token" >&2; exit 1; }
printf '{"Authorization": "Bearer %s"}\n' "$t"
