#!/bin/sh
# herdr worktree.created hook (wired in plugins/kris-tools). Lays out the new workspace as
# chat | git | code | <repo>.work tabs | terminal. The chat tab runs ~/.config/herdr/worktree-setup/<repo>.sh
# first, then the agent from ~/.config/herdr/agent. The worktree gets its own port (worktree-port.sh):
# $PORT in its shells, {port} in <repo>.work.
set -eu
exec >>"$HOME/.config/herdr/scripts/worktree-created.log" 2>&1
echo "--- $(date) ${HERDR_PLUGIN_EVENT_JSON:-}"

PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
herdr="${HERDR_BIN_PATH:-herdr}"
agent=$(cat "$HOME/.config/herdr/agent" 2>/dev/null || echo claude)

event="${HERDR_PLUGIN_EVENT_JSON:-}"
path=$(echo "$event" | jq -r '[.. | objects | .worktree? | objects | .path] | first // empty')
workspace=$(echo "$event" | jq -r '[.. | objects | .workspace? | objects | .workspace_id] | first // empty')
[ -n "$path" ] && [ -n "$workspace" ] || { echo "no worktree path/workspace in event"; exit 0; }

# Setup scripts are keyed by the main checkout's folder name, so every worktree of a repo shares one.
root=$(dirname "$(git -C "$path" rev-parse --path-format=absolute --git-common-dir)")
repo=$(basename "$root")
setup="$HOME/.config/herdr/worktree-setup/$repo.sh"
tabs="$HOME/.config/herdr/worktree-setup/$repo.work"
S="$HOME/.config/herdr/scripts"
port=$("$S/worktree-port.sh" assign "$path")
branch=$(git -C "$path" symbolic-ref -q --short HEAD || echo HEAD)

pane=$("$herdr" pane list | jq -r --arg w "$workspace" '[.result.panes[] | select(.workspace_id == $w)][0].pane_id')
tab=$("$herdr" pane get "$pane" | jq -r '.result.pane.tab_id')
"$herdr" tab rename "$tab" chat >/dev/null

# The code tab waits for this marker so nvim (and its LSP) starts after setup. It lives in the
# worktree's own git dir: never shows as untracked, removed with the worktree.
marker="$(git -C "$path" rev-parse --absolute-git-dir)/herdr-setup-done"
if [ -f "$setup" ]; then
  "$herdr" pane run "$pane" "REPO_ROOT='$root' sh '$setup'; s=\$?; touch '$marker'; [ \$s -eq 0 ] && $agent" >/dev/null
  editor="echo 'Waiting for setup in the chat tab…'; while [ ! -e '$marker' ]; do sleep 1; done; nvim ."
else
  touch "$marker"
  "$herdr" pane run "$pane" "$agent" >/dev/null
  editor="nvim ."
fi

opened=$("$herdr" plugin pane open --plugin kris.tools --entrypoint lazygit --placement tab \
  --workspace "$workspace" --cwd "$path" --no-focus)
"$herdr" tab rename "$(echo "$opened" | jq -r '.result.plugin_pane.pane.tab_id')" git >/dev/null

code=$("$herdr" tab create --workspace "$workspace" --cwd "$path" --label code --no-focus)
"$herdr" pane run "$(echo "$code" | jq -r '.result.root_pane.pane_id')" "$editor" >/dev/null

"$S/config-tabs.sh" "$tabs" "$workspace" "$path" "$branch" "$port" "$marker"
"$herdr" tab create --workspace "$workspace" --cwd "$path" --label terminal --no-focus >/dev/null
"$S/worktree-theme.py" || true  # colours for the new worktree
