#!/usr/bin/env bash
# Popup menu for the custom commands: press a letter to run one, esc or q closes.
# Ghostty maps cmd+/ to this (herdr prefix+/). To add an item: a line in `items` and a case in `run`.
set -u
exec 2>>"$HOME/.config/herdr/scripts/menu.log"

PATH="/opt/homebrew/bin:$HOME/.local/bin:$HOME/.hunk/bin:$PATH"
herdr="${HERDR_BIN_PATH:-herdr}"
S="$HOME/.config/herdr/scripts"

items=(
  "c|Claude    new chat tab"
  "v|nvim      new code tab"
  "g|lazygit   git tab"
  "r|hunk      right pane: uncommitted changes, live (again = close)"
  "b|branch    right pane: everything this branch changed (again = close)"
  "a|agents    jump to the one waiting on you"
  "w|worktree  new worktree → chat | git | code | terminal"
  "x|cleanup   remove this worktree (asks first)"
  "f|lf        file browser"
  "e|setup     edit this repo's worktree setup"
  "?|keys      full cheatsheet"
)

# Context of the pane behind the popup; the scripts below read these
pane="${HERDR_ACTIVE_PANE_ID:-}"
if [ -z "$pane" ]; then
  tab=$("$herdr" workspace list | jq -r '.result.workspaces[] | select(.focused) | .active_tab_id')
  pane=$("$herdr" pane list | jq -r --arg t "$tab" '[.result.panes[] | select(.tab_id == $t)] | (map(select(.focused)) + .)[0].pane_id')
fi
info=$("$herdr" pane get "$pane")
export HERDR_ACTIVE_PANE_ID="$pane"
export HERDR_ACTIVE_WORKSPACE_ID="${HERDR_ACTIVE_WORKSPACE_ID:-$(echo "$info" | jq -r '.result.pane.workspace_id')}"
export HERDR_ACTIVE_PANE_CWD="${HERDR_ACTIVE_PANE_CWD:-$(echo "$info" | jq -r '.result.pane.foreground_cwd // .result.pane.cwd')}"
cwd="$HERDR_ACTIVE_PANE_CWD"

tilde='~'

new_worktree() {
  if ! git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    printf '\n  Not a git repo: %s\n  Press any key.' "$cwd"; read -rsn1; return
  fi
  printf '\n  Branch name (e.g. feat/xyz), empty to cancel: '
  read -r branch
  if [ -n "$branch" ]; then
    "$herdr" worktree create --cwd "$cwd" --branch "$branch" --focus >/dev/null
  fi
}

not_repo() { printf '\n  Not a git repo: %s\n  Press any key.' "$cwd"; read -rsn1; }

remove_worktree() {
  git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || { not_repo; return; }
  gitdir=$(git -C "$cwd" rev-parse --path-format=absolute --git-dir)
  common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir)
  if [ "$gitdir" = "$common" ]; then
    printf '\n  This is the main checkout, not a worktree. Nothing to remove.\n  Press any key.'; read -rsn1; return
  fi
  top=$(git -C "$cwd" rev-parse --show-toplevel)
  branch=$(git -C "$cwd" symbolic-ref -q --short HEAD || echo "(detached)")
  dirty=$(git -C "$cwd" status --porcelain | wc -l | tr -d ' ')
  printf '\n  Remove worktree %s\n  branch %s' "${top/#$HOME/$tilde}" "$branch"
  [ "$dirty" -gt 0 ] && printf '\n  \033[33m%s uncommitted change(s) will be lost\033[0m' "$dirty"
  printf '\n\n  Remove it and close this workspace? [y/N] '
  read -rsn1 answer; echo
  case "$answer" in y|Y) ;; *) return ;; esac
  root=$(dirname "$common")
  # Detached: closing the workspace also closes this popup. The branch is deleted only if
  # git sees it as merged (branch -d); otherwise it's kept.
  nohup sh -c '
    "$1" worktree remove --workspace "$2" $3 >/dev/null &&
      [ "$4" != "(detached)" ] && git -C "$5" branch -d "$4" >/dev/null 2>&1
  ' _ "$herdr" "$HERDR_ACTIVE_WORKSPACE_ID" "$([ "$dirty" -gt 0 ] && echo --force)" "$branch" "$root" >/dev/null 2>&1 &
  sleep 1
}

run() {
  case "$1" in
    c) "$S/run-in-tab.sh" chat "$(cat "$HOME/.config/herdr/agent" 2>/dev/null || echo claude)" ;;
    v) "$S/run-in-tab.sh" code "nvim ." ;;
    g) "$S/lazygit-tab.sh" ;;
    r) "$S/hunk-pane.sh" ;;
    b) "$S/hunk-pane.sh" branch ;;
    a) "$S/next-waiting-agent.sh" ;;
    w) new_worktree ;;
    x) remove_worktree ;;
    f) exec lf ;;
    e) exec "$S/edit-worktree-setup.sh" ;;
    "?") exec less -R "$HOME/.config/herdr/cheatsheet.txt" ;;
    *) return 1 ;;
  esac
}

bold=$'\033[1m' dim=$'\033[2m' key=$'\033[38;5;216m' reset=$'\033[0m'
printf '\033[2J\033[H\n  %sherdr menu%s  %s%s%s\n\n' "$bold" "$reset" "$dim" "${cwd/#$HOME/$tilde}" "$reset"
for i in "${items[@]}"; do
  printf '   %s%s%s   %s\n' "$key$bold" "${i%%|*}" "$reset" "${i#*|}"
done
printf '\n  %sesc / q  close%s\n' "$dim" "$reset"

while IFS= read -rsn1 k; do
  case "$k" in
    $'\e'|q|"") exit 0 ;;
  esac
  run "$k" && exit 0
done
