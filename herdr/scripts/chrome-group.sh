#!/bin/sh
# Open this worktree in a Chrome tab group (cmd+/ t): Storybook on the worktree's port, plus the
# worktree's PR when one is known and the task(s) its description links (worktree-pr.sh). Needs the herdr tab groups extension
# (dotfiles chrome/herdr-tab-groups, loaded unpacked), which names and colours the group.
#   work   worktree: group "text area"         (blue, cyan, green, yellow)
#   review worktree: group "review text area"  (purple, pink, red, orange)
# The name is the branch without its folder and ticket: feat/abc-1234-text-area -> text area.
# Running it again focuses the group if it's already open.
# Setup per machine: chrome://extensions → Developer mode → Load unpacked → chrome/herdr-tab-groups
# in this repo, then put the ID Chrome shows for it in ~/.config/herdr/chrome-extension-id.
set -eu
exec >>"$HOME/.config/herdr/scripts/chrome-group.log" 2>&1
echo "--- $(date) ${HERDR_ACTIVE_PANE_CWD:-}"

PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
S="$HOME/.config/herdr/scripts"
herdr="${HERDR_BIN_PATH:-herdr}"
extension=$(tr -d '[:space:]' < "$HOME/.config/herdr/chrome-extension-id" 2>/dev/null || true)
if [ -z "$extension" ]; then
  "$herdr" notification show "Chrome tab groups: extension ID missing" \
    --body "Load chrome/herdr-tab-groups unpacked (chrome://extensions), put its ID in ~/.config/herdr/chrome-extension-id" \
    --sound none >/dev/null
  exit 0
fi
cwd="${HERDR_ACTIVE_PANE_CWD:-$PWD}"

top=$(git -C "$cwd" rev-parse --show-toplevel)
branch=$(git -C "$top" symbolic-ref -q --short HEAD || echo detached)
port=$("$S/worktree-port.sh" get "$top")
port=${port:-8000}  # main checkout: no registered port, Storybook's own default

# review-worktree.sh puts review worktrees in review-<branch> folders
case "$(basename "$top")" in
  review-*) kind=review ;;
  *) kind=work ;;
esac

# folder/TICKET-123-some-nameHere (or ticket at the end) -> some name here
name=$(printf '%s' "${branch##*/}" |
  sed -E 's/^review-//; s/^[A-Za-z]+-[0-9]+-//; s/-[A-Za-z]+-[0-9]+$//; s/([a-z])([A-Z])/\1 \2/g; s/[-_]+/ /g' |
  tr '[:upper:]' '[:lower:]')
title=$([ "$kind" = review ] && echo "review $name" || echo "$name")

# The worktree's PR (saved link, or the branch's newest Azure DevOps PR) and the task link(s) from
# its description, both saved after the first lookup (worktree-pr.sh)
pr=$("$S/worktree-pr.sh" find "$top" || true)
tasks=$([ -n "$pr" ] && "$S/worktree-pr.sh" task "$top" || true)

enc() { jq -rn --arg v "$1" '$v | @uri'; }
url="chrome-extension://$extension/launch.html?kind=$kind&title=$(enc "$title")&url=$(enc "http://localhost:$port/")"
if [ -n "$pr" ]; then url="$url&url=$(enc "$pr")"; fi
for task in $tasks; do url="$url&url=$(enc "$task")"; done
echo "$url"
open -a "Google Chrome" "$url"
