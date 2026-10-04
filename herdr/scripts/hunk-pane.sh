#!/bin/sh
# Toggle a side pane with hunk's live diff of the focused pane's repo. Ghostty maps cmd+shift+r to this.
# Opens a split on the right running `hunk diff --watch` (reloads as files change); focus stays put.
# Pressed again in the same tab it closes that pane. q inside hunk closes it too.
set -eu
exec >>"$HOME/.config/herdr/scripts/hunk-pane.log" 2>&1

PATH="/opt/homebrew/bin:$HOME/.local/bin:$HOME/.hunk/bin:$PATH"
herdr="${HERDR_BIN_PATH:-herdr}"

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

# The pane this script opened in this tab is remembered, so a second press closes it
# even while hunk is still starting
state="${TMPDIR:-/tmp}/herdr-hunk-pane-$(echo "$tab" | tr -c 'A-Za-z0-9\n' '_')"
if [ -f "$state" ]; then
  # Stored as terminal id, unique even if pane ids get reused after a herdr restart
  term=$(cat "$state"); rm -f "$state"
  open=$("$herdr" pane list | jq -r --arg t "$term" '.result.panes[] | select(.terminal_id == $t) | .pane_id' | head -n 1)
  if [ -n "$open" ]; then
    "$herdr" pane close "$open" >/dev/null
    exit 0
  fi
fi

if ! git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  "$herdr" notification show "hunk: not a git repo" --body "$cwd" --sound none >/dev/null
  exit 0
fi

split=$("$herdr" pane split "$pane" --direction right --cwd "$cwd" --no-focus)
new=$(echo "$split" | jq -r '.result.pane.pane_id')
# exec: quitting hunk ends the shell, so the pane closes
echo "$split" | jq -r '.result.pane.terminal_id' > "$state"
"$herdr" pane run "$new" "exec hunk diff --watch" >/dev/null
