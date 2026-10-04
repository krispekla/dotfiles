#!/bin/sh
# Open a new tab named <label> in the current workspace, in the focused pane's directory,
# and run <command> in it. Used by prefix+shift+c (chat) and prefix+shift+v (code).
# Usage: run-in-tab.sh <label> <command>
set -eu
exec >>"$HOME/.config/herdr/scripts/run-in-tab.log" 2>&1

PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
herdr="${HERDR_BIN_PATH:-herdr}"

created=$("$herdr" tab create --workspace "$HERDR_ACTIVE_WORKSPACE_ID" \
  --cwd "${HERDR_ACTIVE_PANE_CWD:-$PWD}" --label "$1" --focus)
"$herdr" pane run "$(echo "$created" | jq -r '.result.root_pane.pane_id')" "$2" >/dev/null
