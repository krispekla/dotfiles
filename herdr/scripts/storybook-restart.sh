#!/bin/sh
# Restart Storybook in this workspace's storybook tab on the worktree's own port (cmd+/ s).
# Stops whatever runs in the tab (ctrl+c, then kill if it hangs) and runs `yarn dev:storybook`
# again. No install or build: those ran once in the worktree setup. No storybook tab yet: opens one.
# The main checkout has no registered port, so it runs without -p (the script's own 8000).
set -eu
exec >>"$HOME/.config/herdr/scripts/storybook-restart.log" 2>&1
echo "--- $(date) ${HERDR_ACTIVE_PANE_CWD:-}"

PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
herdr="${HERDR_BIN_PATH:-herdr}"
S="$HOME/.config/herdr/scripts"
workspace="$HERDR_ACTIVE_WORKSPACE_ID"
cwd="${HERDR_ACTIVE_PANE_CWD:-$PWD}"

top=$(git -C "$cwd" rev-parse --show-toplevel)
port=$("$S/worktree-port.sh" get "$top")
cmd="yarn dev:storybook${port:+ -p $port}"

tab=$("$herdr" tab list --workspace "$workspace" |
  jq -r '[.result.tabs[] | select(.label | startswith("storybook"))][0].tab_id // empty')

if [ -z "$tab" ]; then
  created=$("$herdr" tab create --workspace "$workspace" --cwd "$top" --label "storybook:${port:-8000}" --focus)
  "$herdr" pane run "$(echo "$created" | jq -r '.result.root_pane.pane_id')" "$cmd" >/dev/null
  exit 0
fi

pane=$("$herdr" pane list | jq -r --arg t "$tab" '[.result.panes[] | select(.tab_id == $t)][0].pane_id')
"$herdr" tab focus "$tab" >/dev/null

# Busy until only the shell is in the foreground again
busy() {
  "$herdr" pane process-info --pane "$pane" |
    jq -e '[.result.process_info.foreground_processes[].name] - ["zsh", "bash", "sh", "fish"] | length > 0' >/dev/null
}
n=0
while busy; do
  [ $((n % 6)) -eq 0 ] && "$herdr" pane send-keys "$pane" ctrl+c >/dev/null  # again every 3s
  n=$((n + 1))
  if [ $n -gt 20 ]; then  # still running after ~10s: kill the foreground process group
    pg=$("$herdr" pane process-info --pane "$pane" | jq -r '.result.process_info.foreground_process_group_id')
    kill -9 -"$pg" 2>/dev/null || true
    sleep 1
    break
  fi
  sleep 0.5
done

"$herdr" pane run "$pane" "$cmd" >/dev/null
