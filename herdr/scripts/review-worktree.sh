#!/bin/sh
# Review worktree for someone else's remote branch, laid out for review. Started from the menu (cmd+/ R).
# Usage: review-worktree.sh <dir inside the repo> <branch>
#   - fetches origin/<branch>; creates the local branch tracking it, or fast-forwards an existing one
#   - worktree at ~/.herdr/worktrees/<repo>/review-<branch>, opened as a herdr workspace
#   - tabs: review (agent + whole-branch hunk pane) | git | code | tabs from <repo>.review | terminal
# Per repo, per machine (not in the dotfiles repo), in ~/.config/herdr/worktree-setup/:
#   <repo>.sh      install/setup, shared with work worktrees; runs first in the review tab
#   <repo>.review  extra tabs, one per line: `name | command`. {port} = this worktree's own port
#                  (worktree-port.sh, also $PORT in its shells), {branch} = the branch.
#                  See herdr/examples/example.review in the dotfiles repo.
set -eu
exec >>"$HOME/.config/herdr/scripts/review-worktree.log" 2>&1
echo "--- $(date) $*"

PATH="/opt/homebrew/bin:$HOME/.local/bin:$HOME/.hunk/bin:$PATH"
herdr="${HERDR_BIN_PATH:-herdr}"
S="$HOME/.config/herdr/scripts"
agent=$(cat "$HOME/.config/herdr/agent" 2>/dev/null || echo claude)

notify() { "$herdr" notification show "review: $1" --body "${2:-}" --sound none >/dev/null; echo "$1 ${2:-}"; }

cwd=$1
branch=${2#origin/}
root=$(dirname "$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir)")
repo=$(basename "$root")
setup="$HOME/.config/herdr/worktree-setup/$repo.sh"
tabs="$HOME/.config/herdr/worktree-setup/$repo.review"

git -C "$root" fetch -q origin "$branch" || { notify "no branch $branch on origin" "$repo"; exit 0; }
git -C "$root" rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null ||
  git -C "$root" fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch"

# Already checked out in some worktree: bring it up to date and open that one
existing=$(git -C "$root" worktree list --porcelain | awk -v b="refs/heads/$branch" '/^worktree /{p=substr($0,10)} $0=="branch "b{print p}')
if [ -n "$existing" ]; then
  git -C "$existing" merge -q --ff-only "origin/$branch" || notify "$branch has local changes, not updated" "$existing"
  "$herdr" worktree open --cwd "$root" --path "$existing" --focus >/dev/null
  notify "$branch was already open" "${existing#"$HOME"/}"
  exit 0
fi

# Local branch: create it tracking origin, or fast-forward it if it only lags behind
if git -C "$root" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
  if git -C "$root" merge-base --is-ancestor "$branch" "origin/$branch"; then
    git -C "$root" branch -q -f --track "$branch" "origin/$branch"
  else
    notify "local $branch has commits origin doesn't, using it as is" "$repo"
  fi
else
  git -C "$root" branch -q --track "$branch" "origin/$branch"
fi

slug=$(echo "$branch" | tr -c 'A-Za-z0-9._\n-' '-')
path="$HOME/.herdr/worktrees/$repo/review-$slug"
n=2; while [ -e "$path" ]; do path="$HOME/.herdr/worktrees/$repo/review-$slug-$n"; n=$((n + 1)); done
mkdir -p "$(dirname "$path")"
git -C "$root" worktree add -q "$path" "$branch"
port=$("$S/worktree-port.sh" assign "$path")

opened=$("$herdr" worktree open --cwd "$root" --path "$path" --label "review $branch" --focus)
workspace=$(echo "$opened" | jq -r '[.. | objects | .workspace_id? // empty] | first')
pane=$("$herdr" pane list | jq -r --arg w "$workspace" '[.result.panes[] | select(.workspace_id == $w)][0].pane_id')
review_tab=$("$herdr" pane get "$pane" | jq -r '.result.pane.tab_id')
"$herdr" tab rename "$review_tab" review >/dev/null

# Tabs that need dependencies wait for this marker. It lives in the worktree's own git dir:
# never shows as untracked, removed with the worktree.
marker="$(git -C "$path" rev-parse --absolute-git-dir)/herdr-setup-done"
wait_setup="echo 'Waiting for setup in the review tab…'; while [ ! -e '$marker' ]; do sleep 1; done"

# review: setup, then the agent; whole-branch diff on the right
if [ -f "$setup" ]; then
  "$herdr" pane run "$pane" "REPO_ROOT='$root' sh '$setup'; s=\$?; touch '$marker'; [ \$s -eq 0 ] && $agent" >/dev/null
else
  touch "$marker"
  "$herdr" pane run "$pane" "$agent" >/dev/null
fi
HERDR_ACTIVE_PANE_ID="$pane" "$S/hunk-pane.sh" branch

new_tab() { # $1 label, $2 command (empty = plain shell)
  t=$("$herdr" tab create --workspace "$workspace" --cwd "$path" --label "$1" --no-focus)
  [ -n "$2" ] && "$herdr" pane run "$(echo "$t" | jq -r '.result.root_pane.pane_id')" "$2" >/dev/null
  return 0
}

opened=$("$herdr" plugin pane open --plugin kris.tools --entrypoint lazygit --placement tab \
  --workspace "$workspace" --cwd "$path" --no-focus)
"$herdr" tab rename "$(echo "$opened" | jq -r '.result.plugin_pane.pane.tab_id')" git >/dev/null

new_tab code "$wait_setup; nvim ."

"$S/config-tabs.sh" "$tabs" "$workspace" "$path" "$branch" "$port" "$marker"

new_tab terminal ""
"$herdr" tab focus "$review_tab" >/dev/null
