#!/bin/sh
# Open lazygit in a "git" tab of the current workspace, or focus that tab if it already exists.
# lazygit itself is launched by the local plugin in ~/.config/herdr/plugins/kris-tools,
# which starts it directly as a tab (no typing into a shell). Ghostty maps cmd+g to this.
set -eu
exec >>"$HOME/.config/herdr/scripts/lazygit-tab.log" 2>&1

PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
herdr="${HERDR_BIN_PATH:-herdr}"

# Pane the user was looking at: provided by herdr when available, else the focused pane
# in the focused workspace's active tab.
pane="${HERDR_ACTIVE_PANE_ID:-}"
if [ -z "$pane" ]; then
  tab=$("$herdr" workspace list | jq -r '.result.workspaces[] | select(.focused) | .active_tab_id')
  pane=$("$herdr" pane list | jq -r --arg t "$tab" '[.result.panes[] | select(.tab_id == $t)] | (map(select(.focused)) + .)[0].pane_id')
fi

info=$("$herdr" pane get "$pane")
workspace=$(echo "$info" | jq -r '.result.pane.workspace_id')
cwd=$(echo "$info" | jq -r '.result.pane.foreground_cwd // .result.pane.cwd')

if ! git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  "$herdr" notification show "lazygit: not a git repo" --body "$cwd" --sound none >/dev/null
  exit 0
fi

existing=$("$herdr" tab list --workspace "$workspace" | jq -r '.result.tabs[] | select(.label == "git") | .tab_id' | head -n 1)
if [ -n "$existing" ]; then
  "$herdr" tab focus "$existing" >/dev/null
  exit 0
fi

opened=$("$herdr" plugin pane open --plugin kris.tools --entrypoint lazygit --placement tab \
  --workspace "$workspace" --cwd "$cwd" --focus)
"$herdr" tab rename "$(echo "$opened" | jq -r '.result.plugin_pane.pane.tab_id')" git >/dev/null
