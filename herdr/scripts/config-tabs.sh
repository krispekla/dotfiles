#!/bin/sh
# Opens the per-repo tabs listed in a tabs file, in a worktree's workspace.
# Used by worktree-created.sh (<repo>.work) and review-worktree.sh (<repo>.review).
# Usage: config-tabs.sh <tabs file> <workspace> <worktree> <branch> <port> <setup marker>
# File: one tab per line, `name | command`; # comments and blank lines are ignored.
#   {port}    the worktree's port (worktree-port.sh), also usable in the name: dev:{port}
#   {branch}  the worktree's branch
# Each command waits until <setup marker> exists, so it starts after install/setup.
set -eu

PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
herdr="${HERDR_BIN_PATH:-herdr}"
file=$1 workspace=$2 path=$3 branch=$4 port=$5 marker=$6

[ -f "$file" ] || exit 0
wait_setup="echo 'Waiting for setup…'; while [ ! -e '$marker' ]; do sleep 1; done"

grep -vE '^[[:space:]]*(#|$)' "$file" | grep '|' | while IFS= read -r line; do
  line=$(printf '%s' "$line" | sed "s/{port}/$port/g; s#{branch}#$branch#g")
  name=$(printf '%s' "${line%%|*}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  cmd=$(printf '%s' "${line#*|}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  t=$("$herdr" tab create --workspace "$workspace" --cwd "$path" --label "$name" --no-focus)
  "$herdr" pane run "$(echo "$t" | jq -r '.result.root_pane.pane_id')" "$wait_setup; $cmd" >/dev/null
done
