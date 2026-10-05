#!/bin/sh
# hunk diff in a pane on the right of the focused pane's repo; focus stays put. Reloads as files change.
#   hunk-pane.sh          live: uncommitted changes (cmd+shift+r, menu r)
#   hunk-pane.sh branch   whole branch: everything since it left the default branch (menu b)
# One hunk pane per tab: same mode again closes it, the other mode swaps it in place.
# q inside hunk closes it too.
set -eu
exec >>"$HOME/.config/herdr/scripts/hunk-pane.log" 2>&1

PATH="/opt/homebrew/bin:$HOME/.local/bin:$HOME/.hunk/bin:$PATH"
herdr="${HERDR_BIN_PATH:-herdr}"
mode="${1:-live}"

notify() { "$herdr" notification show "hunk: $1" --body "${2:-}" --sound none >/dev/null; }

# Pane the user was looking at: provided by herdr when available, else the focused pane
# in the focused workspace's active tab.
pane="${HERDR_ACTIVE_PANE_ID:-}"
if [ -z "$pane" ]; then
  tab=$("$herdr" workspace list | jq -r '.result.workspaces[] | select(.focused) | .active_tab_id')
  pane=$("$herdr" pane list | jq -r --arg t "$tab" '[.result.panes[] | select(.tab_id == $t)] | (map(select(.focused)) + .)[0].pane_id')
fi

info=$("$herdr" pane get "$pane")
tab=$(echo "$info" | jq -r '.result.pane.tab_id')
cwd=$(echo "$info" | jq -r '.result.pane.foreground_cwd // .result.pane.cwd')

# The pane this script opened in this tab is remembered (terminal id + mode), so a second
# press finds it even while hunk is still starting. Terminal ids stay unique across herdr
# restarts, unlike pane ids.
state="${TMPDIR:-/tmp}/herdr-hunk-pane-$(echo "$tab" | tr -c 'A-Za-z0-9\n' '_')"
if [ -f "$state" ]; then
  { read -r term; read -r open_mode; } < "$state" || true
  rm -f "$state"
  open=$("$herdr" pane list | jq -r --arg t "$term" '.result.panes[] | select(.terminal_id == $t) | .pane_id' | head -n 1)
  if [ -n "$open" ]; then
    "$herdr" pane close "$open" >/dev/null
    # Same mode: that was the toggle. Other mode: fall through and reopen in this one.
    [ "${open_mode:-live}" = "$mode" ] && exit 0
    # If the focused pane was the hunk pane, split its neighbour instead
    [ "$open" = "$pane" ] && pane=$("$herdr" pane list | jq -r --arg t "$tab" '[.result.panes[] | select(.tab_id == $t)][0].pane_id')
  fi
fi

if ! git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  notify "not a git repo" "$cwd"
  exit 0
fi

case "$mode" in
  live) target="" ;;
  branch)
    # Base: the remote's default branch (origin/HEAD), else main, else master
    default=$(git -C "$cwd" symbolic-ref -q --short refs/remotes/origin/HEAD) ||
      default=$(git -C "$cwd" rev-parse -q --verify main >/dev/null && echo main || echo master)
    target=$(git -C "$cwd" merge-base HEAD "$default") || { notify "no common base with $default" "$cwd"; exit 0; }
    ;;
  *) echo "unknown mode: $mode"; exit 1 ;;
esac

split=$("$herdr" pane split "$pane" --direction right --cwd "$cwd" --no-focus)
new=$(echo "$split" | jq -r '.result.pane.pane_id')
printf '%s\n%s\n' "$(echo "$split" | jq -r '.result.pane.terminal_id')" "$mode" > "$state"
# exec: quitting hunk ends the shell, so the pane closes
"$herdr" pane run "$new" "exec hunk diff --watch $target" >/dev/null
