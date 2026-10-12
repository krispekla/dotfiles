#!/bin/sh
# Runs a repo's worktree setup in the current pane (cwd = the new worktree), then says how it went:
# a herdr notification, so you can work elsewhere meanwhile. Writes the setup's exit code into the
# marker file that the other tabs (and agent-prompt.sh) wait for. Exits with that code, so
# `setup-run.sh … && claude` starts the agent only after a good setup.
# Usage: setup-run.sh <main checkout> <setup script> <marker> <label>
root=$1 setup=$2 marker=$3 label=$4
herdr="${HERDR_BIN_PATH:-herdr}"

REPO_ROOT="$root" sh "$setup"
s=$?
echo "$s" > "$marker"
if [ "$s" -eq 0 ]; then
  "$herdr" notification show "setup done: $label" --sound done >/dev/null 2>&1
else
  "$herdr" notification show "setup failed: $label" --body "exit $s, see the first tab" --sound request >/dev/null 2>&1
fi
exit "$s"
