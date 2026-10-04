# dotfiles

Config for an agent-first dev setup on macOS:
**AeroSpace** (windows) → **Ghostty** (terminal) → **herdr** (workspaces, tabs, agents) → **Claude Code** / **LazyVim** / **lazygit** / **hunk** inside it.

The repo holds the *workflow*, not machine state. It has no repo names, no absolute user paths and no secrets.

## What's here and where it goes

| Repo path | Lives at | What it does |
|---|---|---|
| `herdr/config.toml` | `~/.config/herdr/config.toml` | herdr keys, theme, sidebar. Custom commands call the scripts below |
| `herdr/cheatsheet.txt` | `~/.config/herdr/cheatsheet.txt` | All keys on one page (`cmd+shift+h`) |
| `herdr/agent` | `~/.config/herdr/agent` | Which agent chat tabs start (`claude`) |
| `herdr/scripts/*.sh` | `~/.config/herdr/scripts/` | lazygit tab, jump to waiting agent, new chat/code tab, worktree layout |
| `herdr/plugins/kris-tools/` | `~/.config/herdr/plugins/kris-tools/` | Local herdr plugin: lazygit pane + `worktree.created` hook |
| `ghostty/config.ghostty` | `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty` | `cmd+…` shortcuts → herdr prefix sequences, font, theme |
| `nvim/` | `~/.config/nvim/` | LazyVim starter + catppuccin, typescript/tailwind extras, `lazy-lock.json` |
| `lazygit/config.yml` | `~/Library/Application Support/lazygit/config.yml` | Catppuccin Mocha colours |
| `hunk/config.toml` | `~/.config/hunk/config.toml` | hunk diff viewer display settings |
| `claude/settings.json` | `~/.claude/settings.json` | Claude Code settings (status line, effort, notifications) |
| `claude/statusline.sh` | `~/.claude/statusline.sh` | Status line: project, branch, model/effort, context + usage meters |
| `shell/.zshenv` | `~/.zshenv` | `EDITOR=nvim` (+ cargo env if present) |
| `shell/essentials.zsh` | `~/.config/zsh/essentials.zsh` | Only the shell bits this setup needs: herdr/claude/hunk on `PATH`, fzf keys. Loaded from `~/.zshrc` |
| `aerospace/aerospace.toml` | `~/.config/aerospace/aerospace.toml` | Tiling window manager, `alt` layer |
| `Brewfile` | — | Tools the above needs |

Theme everywhere: Catppuccin (Mocha).

## Install on a Mac

Config files are **symlinked** to this repo. A change to your live config shows up in `git status` here. Keep the repo where you cloned it: moving it breaks the links.

1. Install [Homebrew](https://brew.sh), then the tools: `brew bundle --file=Brewfile`
2. Install the tools that aren't in the Brewfile:
   - **Ghostty**: download from [ghostty.org](https://ghostty.org) and drag to Applications
   - **herdr**: `curl -fsSL https://herdr.dev/install.sh | sh`. It installs to `~/.local/bin`, so that needs to be on your `PATH`. Update later with `herdr update`.
   - **hunk**: `curl -fsSL https://hunk.dev/install.sh | sh`. It installs to `~/.hunk/bin` and adds that to `PATH` in `~/.zshrc`. Update later with `hunk update`.
   - **Claude Code**
3. `./install.sh --check`: shows every file as `linked` / `same` / `missing` / `differs`, with diffs, then a **Requirements** list:
   tools on `PATH`, fzf keys, `EDITOR`, apps, herdr plugin + Claude integration, and the commit check. Each one is `ok` or `missing` with the fix. Changes nothing.
4. If anything differs, merge it first. The easiest way is to open Claude in this repo; `CLAUDE.md` tells it how.
5. `./install.sh`: links what's safe, skips what still differs, backs up anything it replaces to `~/.dotfiles-backup/<timestamp>/`. Safe to run again.
   It also turns on the repo's pre-commit check (see Safeguards).
6. Register the herdr plugin (herdr keeps its own copy, `plugins.json`; re-run after editing the manifest):
   `herdr plugin link ~/.config/herdr/plugins/kris-tools`
7. Hook Claude into herdr (this adds a `SessionStart` hook to `~/.claude/settings.json`):
   `herdr integration install claude`
8. Add one line to the end of `~/.zshrc` (the rest of `.zshrc` stays per machine and out of this repo):
   `[ -f ~/.config/zsh/essentials.zsh ] && source ~/.config/zsh/essentials.zsh`
9. Open nvim once so lazy.nvim installs the plugins pinned in `lazy-lock.json`.
10. `herdr server reload-config` (or restart herdr). Run `./install.sh --check` again: everything should be `ok`.

Live config points at whatever branch is checked out here. Keep this repo on `main` day to day.

**Not linked, merged by hand** (`merge` in `install.sh`). These are copied in only if missing:
- `aerospace.toml`, because display/monitor setup differs per machine.
- `claude/settings.json`, because herdr and Claude Code write into it.

## Safeguards

Linked files write straight into this repo, so a secret or a `/Users/<name>/…` path added to a live config shows up here too. `.githooks/pre-commit` blocks the commit if either reaches staged changes:
- **Secrets**: [gitleaks](https://github.com/gitleaks/gitleaks) scans for tokens, API keys and private keys. If gitleaks is missing, the commit is refused.
- **Home paths**: any `/Users/<name>` in an added line. Use `~` or `$HOME` instead.

Where secrets and machine-specific values go instead (never in the repo):
- **Shell**: `~/.zshenv.local`, loaded by `shell/.zshenv` if it exists. Put API keys and per-machine exports there.

## Per-machine things (not in the repo)

- **Worktree setup scripts**: `~/.config/herdr/worktree-setup/<repo-folder>.sh` runs in each new worktree of that repo (for example `pnpm install`, or `cp "$REPO_ROOT/.env" .env`). Create or edit one with `cmd+shift+e` from inside the repo. These are gitignored here because repos differ per machine.
- **herdr ↔ Claude hook**: generated by `herdr integration install claude` (step 5). herdr manages it, so it isn't stored here.
- **AeroSpace**: the `[[on-window-detected]]` rule with a `com.apple.Safari.WebApp.<UUID>` app id and the `[workspace-to-monitor-force-assignment]` block match this machine's web app and monitors. Adjust both on a new machine.

## Assumptions

- Apple Silicon Homebrew at `/opt/homebrew`. herdr scripts prepend `/opt/homebrew/bin` and `$HOME/.local/bin` to `PATH`, because herdr runs them without your shell profile.
- Ghostty sends herdr's prefix `ctrl+b` (`\x02`). If you change the herdr prefix, update `ghostty/config.ghostty`.
- The status line and lazygit use Nerd Font icons. Ghostty ships the Nerd Font symbols built in.

## Rules for this repo

- Never commit secrets, tokens, `~/.claude.json`, history, `projects/`, sessions, logs, sockets or `.bak-*` files.
- Use `$HOME` or `~`, never `/Users/<name>`.
- Work on a branch, use Conventional Commits, and open a PR. Nobody pushes to `main`.
