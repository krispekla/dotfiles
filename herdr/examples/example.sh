# Copy to ~/.config/herdr/worktree-setup/<repo>.sh (<repo> = the main checkout's folder name).
# Runs first in every new worktree of <repo>, work (cmd+shift+g) and review (cmd+/ R).
# cwd = the new worktree, $REPO_ROOT = the main checkout. Edit it with cmd+shift+e from the repo.

cp "$REPO_ROOT/.env" .env 2>/dev/null
pnpm install
