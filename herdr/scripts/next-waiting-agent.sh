#!/bin/sh
# Focus the agent that is waiting on you: blocked ones (approval/question) first,
# then finished-but-unseen ("done"), longest-waiting first. Ghostty maps cmd+i to this.
set -eu
exec >>"$HOME/.config/herdr/scripts/next-waiting-agent.log" 2>&1

PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
herdr="${HERDR_BIN_PATH:-herdr}"

target=$("$herdr" agent list | jq -r '
  [.result.agents[] | select(.focused | not)
   | select(.agent_status == "blocked" or .agent_status == "done")]
  | sort_by(
      (if .agent_status == "blocked" then 0 else 1 end),
      (.completion_seq // .state_change_seq // 0))
  | first | .pane_id // empty')

if [ -n "$target" ]; then
  "$herdr" agent focus "$target" >/dev/null
else
  "$herdr" notification show "No agents waiting" --sound none >/dev/null
fi
