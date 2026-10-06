#!/usr/bin/env bash
# Popup menu for the custom commands: press a letter to run one, esc or q closes.
# Ghostty maps cmd+/ to this (herdr prefix+/). To add an item: a line in `items` and a case in `run`.
set -u
exec 2>>"$HOME/.config/herdr/scripts/menu.log"

PATH="/opt/homebrew/bin:$HOME/.local/bin:$HOME/.hunk/bin:$PATH"
herdr="${HERDR_BIN_PATH:-herdr}"
S="$HOME/.config/herdr/scripts"

items=(
  "c|chat      new chat tab → Claude | Copilot"
  "v|nvim      new code tab"
  "g|lazygit   git tab"
  "r|hunk      right pane: uncommitted changes, live (again = close)"
  "b|branch    right pane: everything this branch changed (again = close)"
  "n|notes     clear this worktree's hunk notes, saved ones too (asks first)"
  "a|agents    jump to the one waiting on you"
  "s|storybook restart in its tab, same port (no install/build)"
  "w|worktree  new worktree → chat | git | code | terminal"
  "x|cleanup   remove this worktree (asks first)"
  "R|review    review worktree for a remote branch (pick from list)"
  "f|lf        file browser"
  "e|setup     edit this repo's worktree setup"
  "p|colour    next colour for this space (again = next one, P = back)"
  "?|keys      full cheatsheet"
)
# Per-machine additions, not in the repo: ~/.config/herdr/menu.local.sh can append to items and
# define run_local <key> for them (returning 1 for keys that aren't its own)
[ -f "$HOME/.config/herdr/menu.local.sh" ] && . "$HOME/.config/herdr/menu.local.sh"

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

# Agent picker for the chat tab: first row is preselected, so enter = Claude.
# Letter runs one directly; j/k or arrows move; esc or q goes back to the menu.
# Row: letter|name shown|tab label|command
chat_agents=(
  "c|Claude|chatc|$(cat "$HOME/.config/herdr/agent" 2>/dev/null || echo claude)"
  "o|Copilot|chatg|copilot"
)

pick_chat() {
  local sel=0 n=${#chat_agents[@]} k rest i row letter label tab cmd
  while :; do
    printf '\033[2J\033[H\n  %snew chat tab%s\n\n' "$bold" "$reset"
    for i in "${!chat_agents[@]}"; do
      IFS='|' read -r letter label _ <<<"${chat_agents[$i]}"
      if [ "$i" -eq "$sel" ]; then row="${bold}▸ ${key}${letter}${reset}${bold}   ${label}${reset}"
      else row="  ${key}${letter}${reset}   ${label}"; fi
      printf '   %s\n' "$row"
    done
    printf '\n  %senter  open · j/k  move · esc / q  back%s\n' "$dim" "$reset"
    IFS= read -rsn1 k || return 1
    case "$k" in
      $'\e')
        # Arrow keys arrive as esc [ A/B; bash 3.2 (macOS /bin/bash) only takes whole-second timeouts
        read -rsn2 -t "$( [ "${BASH_VERSINFO[0]}" -ge 4 ] && echo 0.05 || echo 1)" rest || rest=""
        case "$rest" in
          "[A") k=k ;;
          "[B") k=j ;;
          *) return 1 ;;
        esac ;;
    esac
    case "$k" in
      q) return 1 ;;
      "") break ;;
      j) sel=$(( (sel + 1) % n )) ;;
      k) sel=$(( (sel + n - 1) % n )) ;;
      *)
        for i in "${!chat_agents[@]}"; do
          [ "${chat_agents[$i]%%|*}" = "$k" ] && { sel=$i; break 2; }
        done ;;
    esac
  done
  IFS='|' read -r _ _ tab cmd <<<"${chat_agents[$sel]}"
  "$S/run-in-tab.sh" "$tab" "$cmd"
}

not_repo() { printf '\n  Not a git repo: %s\n  Press any key.' "$cwd"; read -rsn1; }

review_worktree() {
  git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || { not_repo; return; }
  printf '\n  Fetching branches…'
  git -C "$cwd" fetch -q --prune origin 2>/dev/null
  # Newest first: branch, age, last author. Type to filter; a name not in the list is used as typed.
  picked=$(git -C "$cwd" for-each-ref --sort=-committerdate \
      --format='%(refname:lstrip=3)%09%(committerdate:relative)%09%(authorname)' refs/remotes/origin |
    grep -v '^HEAD	' |
    fzf --prompt 'review branch> ' --delimiter '\t' --nth 1 --print-query --reverse --height 100% \
      --header 'Enter: create review worktree · esc: cancel')
  rc=$?  # 0 picked, 1 no match (use what was typed), 130 esc
  [ "$rc" -le 1 ] && [ -n "$picked" ] || return 0
  branch=$(printf '%s\n' "$picked" | tail -n 1 | cut -f1)
  [ -n "$branch" ] || return 0
  printf '\033[2J\033[H\n  Setting up review worktree for %s…' "$branch"
  "$S/review-worktree.sh" "$cwd" "$branch"
}

remove_worktree() {
# hunk notes are saved and restored automatically (hunk-keep.sh); this is the only way to drop them
clear_hunk_notes() {
  git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || { not_repo; return; }
  top=$(git -C "$cwd" rev-parse --show-toplevel)
  printf '\n  Clear all hunk notes in %s,\n  including the saved ones? [y/N] ' "${top/#$HOME/$tilde}"
  read -rsn1 answer; echo
  case "$answer" in y|Y) "$S/hunk-notes.py" clear "$top" && printf '\n  Cleared.' && sleep 1 ;; esac
}

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
  # Its port goes back to the pool (worktree-port.sh); a per-machine
  # ~/.config/herdr/worktree-removed.local.sh <worktree>, if there is one, cleans up after it.
  nohup sh -c '
    "$1" worktree remove --workspace "$2" $3 >/dev/null || exit
    "$6/worktree-port.sh" free "$7"
    [ -x "$HOME/.config/herdr/worktree-removed.local.sh" ] && "$HOME/.config/herdr/worktree-removed.local.sh" "$7"
    "$6/worktree-theme.py"
    [ "$4" != "(detached)" ] && git -C "$5" branch -d "$4" >/dev/null 2>&1
  ' _ "$herdr" "$HERDR_ACTIVE_WORKSPACE_ID" "$([ "$dirty" -gt 0 ] && echo --force)" "$branch" "$root" "$S" "$top" >/dev/null 2>&1 &
  sleep 1
}

# Stays open: herdr repaints behind the popup, so keep pressing p (P = back) until you like it
next_colour() {
  local name
  name=$("$S/worktree-theme.py" "--$1-colour" "$HERDR_ACTIVE_WORKSPACE_ID")
  draw_menu
  printf '\n  colour: %s%s%s\n' "$bold" "$name" "$reset"
}

run() {
  case "$1" in
    c) pick_chat || { draw_menu; return 1; } ;;
    v) "$S/run-in-tab.sh" code "nvim ." ;;
    g) "$S/lazygit-tab.sh" ;;
    r) "$S/hunk-pane.sh" ;;
    b) "$S/hunk-pane.sh" branch ;;
    a) "$S/next-waiting-agent.sh" ;;
    s) "$S/storybook-restart.sh" ;;
    n) clear_hunk_notes ;;
    w) new_worktree ;;
    x) remove_worktree ;;
    R) review_worktree ;;
    f) exec lf ;;
    e) exec "$S/edit-worktree-setup.sh" ;;
    p) next_colour next; return 1 ;;
    P) next_colour prev; return 1 ;;
    "?") cat "$HOME/.config/herdr/cheatsheet.txt" "$HOME/.config/herdr/cheatsheet.local.txt" 2>/dev/null | exec less -R ;;
    *) { declare -F run_local >/dev/null && run_local "$1"; } || return 1 ;;
  esac
}

draw_menu() {
  printf '\033[2J\033[H\n  %sherdr menu%s  %s%s%s\n\n' "$bold" "$reset" "$dim" "${cwd/#$HOME/$tilde}" "$reset"
  for i in "${items[@]}"; do
    printf '   %s%s%s   %s\n' "$key$bold" "${i%%|*}" "$reset" "${i#*|}"
  done
  printf '\n  %sesc / q  close%s\n' "$dim" "$reset"
}

bold=$'\033[1m' dim=$'\033[2m' key=$'\033[38;5;216m' reset=$'\033[0m'
draw_menu
while IFS= read -rsn1 k; do
  case "$k" in
    $'\e'|q|"") exit 0 ;;
  esac
  run "$k" && exit 0
done
