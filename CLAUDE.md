# CLAUDE.md

Personal dotfiles for a herdr + Ghostty + LazyVim + lazygit + hunk + Claude Code setup on macOS.
README.md has where each file lives and the install steps. Read it first.

## Setting up a machine (new or already configured)

The user may already have their own settings on that machine. Compare before linking anything:

1. Run `./install.sh --check`. It changes nothing and prints each file as `linked`, `same`, `missing` or `differs` (with a diff: `-` local, `+` repo).
2. For every `differs` file, show the user the diff and ask: keep the repo version, keep the local one, or combine them. Don't decide alone.
3. Put the agreed result into the repo file, then commit it on a branch (see Git below).
4. For `link` files, make the local file match the repo, or move it aside, so the next check says `same`.
5. Run `./install.sh`. It backs up and links `same` files, links `missing` ones, and skips anything that still differs. Backups go to `~/.dotfiles-backup/<timestamp>/`.
6. Do the remaining README steps (Brewfile, herdr, `herdr integration install claude`, the `essentials.zsh` line in `~/.zshrc`).
7. Run `./install.sh --check` again and fix every `missing` line under Requirements. Each line names its fix.

`merge` files are never linked. Always merge them by hand, in whichever direction is right:
- `~/.config/aerospace/aerospace.toml`: each machine keeps its own `[workspace-to-monitor-force-assignment]` block and app-specific `[[on-window-detected]]` rules, such as Safari web-app IDs. Only shared keybindings/settings move between the repo and the machine. Never overwrite a machine's display setup.
- `~/.claude/settings.json`: herdr adds a `hooks.SessionStart` block with an absolute path. That difference is expected; leave it out of the repo. Merge the other settings.

## Rules

- **Scope**: only config for this setup (herdr, Ghostty, LazyVim, lazygit, hunk, Claude Code, AeroSpace) and what it directly needs. Nothing else from the machine: no unrelated tools' PATHs, no API keys, no other `.zshrc` content. When unsure, ask.
- Keep the repo machine-independent: no absolute `/Users/<name>` paths, no repo names, no secrets. Use `$HOME`/`~`.
- `.githooks/pre-commit` (gitleaks + home-path check) must stay on. Never bypass it with `--no-verify`, never disable it.
- If it blocks a commit, stop and tell the user what it found. For a secret: move it out to a local file (`~/.zshenv.local` for shell), and never commit it. For a path: ask whether it's shared (switch to `~`/`$HOME`) or machine-specific (move it to a local file). Don't guess.
- herdr worktree setup scripts (`~/.config/herdr/worktree-setup/<repo>.sh`) are per machine. Don't add them here.
- Before every commit, scan for tokens, keys, passwords, emails, hostnames and user paths. Ask if unsure.
- New config file: add it to the repo, to the table in README.md and to `entries()` in `install.sh`.

## Git

Branch + Conventional Commits + PR via `gh`. Merge or push to `main` only when the user explicitly says so for that change.
