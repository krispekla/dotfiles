#!/bin/sh
# Port registry: one dev-server port per worktree, unique across all repos, from 3100 up.
#   worktree-port.sh assign <worktree>   print its port, reserving a new one if it has none
#   worktree-port.sh get <worktree>      print its port, if any
#   worktree-port.sh free <worktree>     release it (cmd+/ x does this)
# Registry: ${XDG_STATE_HOME:-~/.local/state}/herdr/ports, one "port<TAB>worktree" per line.
# A port stays reserved while its worktree folder exists, even if nothing is listening; entries
# for deleted folders are dropped on every assign. essentials.zsh exports it as $PORT in shells
# inside the worktree.
set -eu

reg="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/ports"
mkdir -p "$(dirname "$reg")"
touch "$reg"
tab=$(printf '\t')

cmd=${1:-}
[ $# -eq 2 ] || { echo "usage: $0 assign|get|free <worktree>" >&2; exit 2; }
# Same form the zsh hook compares against: the worktree's top level, if it still exists
dir=$(git -C "$2" rev-parse --show-toplevel 2>/dev/null || echo "$2")

lookup() { awk -F'\t' -v d="$dir" '$2 == d { print $1; exit }' "$reg"; }

# One writer at a time, so two worktrees created together can't get the same port
lock() {
  n=0
  until mkdir "$reg.lock" 2>/dev/null; do
    n=$((n + 1)); [ $n -gt 50 ] && rm -rf "$reg.lock"  # stale after ~5s
    sleep 0.1
  done
  trap 'rmdir "$reg.lock" 2>/dev/null' EXIT INT TERM
}

rewrite() { # keep lines for which "$1 <port> <path>" succeeds
  tmp=$(mktemp "$reg.XXXXXX")
  while IFS="$tab" read -r port path; do
    [ -n "$port" ] && "$1" "$port" "$path" && printf '%s\t%s\n' "$port" "$path"
  done < "$reg" > "$tmp" || true
  mv "$tmp" "$reg"
}
exists() { [ -d "$2" ]; }
not_this() { [ "$2" != "$dir" ]; }

case "$cmd" in
  get) lookup ;;
  free) lock; rewrite not_this ;;
  assign)
    lock
    port=$(lookup)
    if [ -z "$port" ]; then
      rewrite exists
      port=3100
      while cut -f1 "$reg" | grep -qx "$port" || lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; do
        port=$((port + 1))
      done
      printf '%s\t%s\n' "$port" "$dir" >> "$reg"
    fi
    echo "$port"
    ;;
  *) echo "usage: $0 assign|get|free <worktree>" >&2; exit 2 ;;
esac
