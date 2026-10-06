#!/bin/zsh
# lazygit for the "git" tab (plugin kris-tools). q closes the tab as usual, but lazygit is
# started again in the same tab:
#   - after a crash: logged with its last output to lazygit-crash.log next to this script;
#     3 crashes within a minute stop and show the error
#   - every few hours, as prevention (long-running lazygit has crashed after a day): only
#     when it has run REFRESH_HOURS (default 4), you aren't looking at its tab, and no
#     rebase / merge / cherry-pick / revert or index.lock is in progress. Checked every 10 min.
log="$HOME/.config/herdr/scripts/lazygit-crash.log"
out="${TMPDIR:-/tmp}/lazygit-stderr-$$"
refresh="${TMPDIR:-/tmp}/lazygit-refresh-$$"
herdr="${HERDR_BIN_PATH:-$HOME/.local/bin/herdr}"
git_dir=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null)
wrapper=$$

# Is the user looking at this pane right now? (its tab active in the focused workspace)
watched() {
  "$herdr" pane list 2>/dev/null | /opt/homebrew/bin/jq -e --arg p "$HERDR_PANE_ID" \
    '.result.panes[] | select(.pane_id == $p) | .focused' >/dev/null &&
  "$herdr" workspace list 2>/dev/null | /opt/homebrew/bin/jq -e --arg w "$HERDR_WORKSPACE_ID" \
    '.result.workspaces[] | select(.workspace_id == $w) | .focused' >/dev/null
}

busy_git() {
  [ -n "$git_dir" ] || return 1
  for f in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD index.lock; do
    [ -e "$git_dir/$f" ] && return 0
  done
  return 1
}

refresher() {
  local started=$(date +%s)
  while sleep ${LAZYGIT_CHECK_SECONDS:-600}; do
    (( $(date +%s) - started < ${REFRESH_HOURS:-4} * 3600 )) && continue
    watched || busy_git && continue
    local lg=$(pgrep -P $wrapper -x lazygit)
    [ -n "$lg" ] || continue
    touch "$refresh"
    kill $lg
    return
  done
}

crashes=()
while :; do
  rm -f "$refresh"
  refresher &
  timer=$!
  /opt/homebrew/bin/lazygit 2> >(tee "$out" >&2)
  code=$?
  pkill -P $timer 2>/dev/null; kill $timer 2>/dev/null
  sleep 0.2  # let tee finish writing the output
  [ -f "$refresh" ] && continue  # planned refresh: start again right away
  [ $code -eq 0 ] && break
  { echo "--- $(date '+%F %T') exit $code in $PWD"; tail -n 20 "$out"; } >> "$log"
  now=$(date +%s)
  crashes+=($now)
  recent=0
  for t in $crashes; do (( t > now - 60 )) && (( recent++ )); done
  if (( recent >= 3 )); then
    echo "\nlazygit crashed 3 times in a minute (exit $code). Last output is in $log"
    echo "Press any key to close."
    read -k1
    break
  fi
  echo "\nlazygit exited with $code, restarting…"
  sleep 2
done
rm -f "$out" "$refresh"
