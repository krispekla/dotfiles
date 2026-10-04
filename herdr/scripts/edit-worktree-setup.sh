#!/bin/sh
# Edit the worktree setup script for the focused pane's repo. Bound to prefix+shift+e (popup).
cwd="${HERDR_ACTIVE_PANE_CWD:-$PWD}"
common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
  echo "Not a git repo: $cwd"; echo "Press any key to close."; read -r _; exit 0; }
repo=$(basename "$(dirname "$common")")
file="$HOME/.config/herdr/worktree-setup/$repo.sh"
[ -f "$file" ] || printf '# Runs in every new worktree of %s (cwd = the new worktree,\n# $REPO_ROOT = main checkout). e.g. pnpm install / yarn install / cp "$REPO_ROOT/.env" .env\n' "$repo" > "$file"
exec "${EDITOR:-/opt/homebrew/bin/nvim}" "$file"
