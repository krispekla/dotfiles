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
| `claude/CLAUDE.md` | `~/.claude/CLAUDE.md` | Global Claude instructions: review findings and coding notes go into Hunk, and the Hunk → Azure DevOps PR review flow |
| `claude/skills/timesheet/` | `~/.claude/skills/timesheet/` | `/timesheet [date or range]`: one copy-paste line per day from git commits and Claude sessions, always ending in "code review, meetings" |
| `shell/.zshenv` | `~/.zshenv` | `EDITOR=nvim` (+ cargo env if present) |
| `shell/essentials.zsh` | `~/.config/zsh/essentials.zsh` | Only the shell bits this setup needs: herdr/claude/hunk on `PATH`, fzf keys, `$PORT` inside worktrees. Loaded from `~/.zshrc` |
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
   - **GitHub Copilot CLI** (optional, the second agent in `cmd+/ c`): `npm install -g @github/copilot`
3. `./install.sh --check`: shows every file as `linked` / `same` / `missing` / `differs`, with diffs, then a **Requirements** list:
   tools on `PATH`, fzf keys, `EDITOR`, apps, herdr plugin + agent integrations, the hunk-review skill, and the commit check. Each one is `ok` or `missing` with the fix. Changes nothing.
4. If anything differs, merge it first. The easiest way is to open Claude in this repo; `CLAUDE.md` tells it how.
5. `./install.sh`: links what's safe, skips what still differs, backs up anything it replaces to `~/.dotfiles-backup/<timestamp>/`. Safe to run again.
   It also turns on the repo's pre-commit check (see Safeguards).
6. Register the herdr plugin (herdr keeps its own copy, `plugins.json`; re-run after editing the manifest):
   `herdr plugin link ~/.config/herdr/plugins/kris-tools`
7. Hook the agents into herdr (Claude's adds a `SessionStart` hook to `~/.claude/settings.json`), and give Claude Hunk's review skill:
   `herdr integration install claude` (and `herdr integration install copilot` if you use Copilot)
   `mkdir -p ~/.claude/skills && ln -sfn "$(dirname "$(hunk skill path hunk-review)")" ~/.claude/skills/hunk-review`
8. Add one line to the end of `~/.zshrc` (the rest of `.zshrc` stays per machine and out of this repo):
   `[ -f ~/.config/zsh/essentials.zsh ] && source ~/.config/zsh/essentials.zsh`
9. Open nvim once so lazy.nvim installs the plugins pinned in `lazy-lock.json`.
10. Restart herdr from a new terminal, so it picks up `HERDR_CONFIG_PATH` (project colours). Run `./install.sh --check` again: everything should be `ok`.

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

## Work and review worktrees

| | Work worktree | Review worktree |
|---|---|---|
| Start | `cmd+shift+g`, type a new branch name | `cmd+/` `R`, pick someone's remote branch |
| Branch | new, from `main` | theirs: created tracking `origin/<branch>`, or an existing local copy fast-forwarded |
| Tabs | chat \| git \| code \| tabs from `<repo>.work` \| terminal | review (agent + whole-branch hunk pane) \| git \| code \| tabs from `<repo>.review` \| terminal |
| Port | its own, e.g. 3100 | its own, e.g. 3101 |
| Clean up | `cmd+/` `x` | `cmd+/` `x` (the local branch copy goes too if it matches origin) |

Both run `worktree-setup/<repo>.sh` first. `<repo>.work` and `<repo>.review` add tabs per repo (one `name | command` per line): e.g. a dev server (`dev:{port}`), tests, or for review the PR page for that repo's host (GitHub, GitLab, Azure DevOps). See `herdr/examples/`.

**Ports**: every worktree gets its own dev-server port when it's created (from 3100 up, unique across all repos; your main checkout keeps its usual one). It stays reserved while the worktree exists and is released by `cmd+/ x`. It's `{port}` in the tab files and `$PORT` in every shell inside the worktree (`shell/essentials.zsh`), so `pnpm exec vite dev --port $PORT` works by hand too. Registry: `~/.local/state/herdr/ports` (`herdr/scripts/worktree-port.sh`).

## Hunk notes are kept

Hunk keeps review notes only in memory, so they're lost when its pane closes or crashes (hunk issue [#113](https://github.com/modem-dev/hunk/issues/113)). Every hunk pane herdr opens runs through `herdr/scripts/hunk-keep.sh`, which fixes that without anything to do by hand:
- **Saved** every 15 s (one shared saver for all panes, under 1% of a CPU core) to `<git dir>/hunk-notes/<live|branch>.json` (inside `.git`, never committed), and **added back** when the pane opens again. Notes come back as agent notes; yours keep author `you`. A note whose line isn't in the diff right now stays saved and returns when it is.
- **Restarted when it grows**: Hunk's `--watch` keeps memory after every reload (up to ~1 GB per pane over a day), so above 700 MB (`HUNK_MAX_MB`) the pane saves, restarts and restores on its own.
- **Cleared** only by you: **`cmd+/ n`** clears the worktree's notes and saved files (asks first).

**lazygit** in the git tab restarts itself (`herdr/scripts/lazygit-keep.sh`); `q` still closes the tab.
- **After a crash**: logged with its last output to `~/.config/herdr/scripts/lazygit-crash.log`; 3 crashes within a minute stop and show the error.
- **Every 4 hours, as prevention** (long-running lazygit has crashed after a day): only while you aren't looking at its tab and no rebase / merge / cherry-pick / revert is in progress, so you never see it.

nvim isn't restarted: it would lose unsaved changes and undo history, and its memory stays flat (40–60 MB after a day).

## Project colours

Like VS Code's Peacock: every project and worktree gets its own colour, so you can tell spaces apart at a glance.
- **Main checkout**: the project's colour, calm tint.
- **Work worktree**: its own colour, stronger tint, picked to look as different as possible from every other open space (by how different colours look, not just hue).
- **Review worktree**: a dark purple tab bar with a light purple accent. Purples are reserved for reviews, so purple always means "reviewing". The window title starts with 🔍.

26 colours for projects and work worktrees, picked to work on a dark background: blues (blue, sapphire, sky, azure, cobalt, indigo, aqua, lavender), greens (green, emerald, jade, teal, turquoise, lime), warm ones (red, coral, tangerine, peach, amber, gold, yellow) and pinks (rose, pink, magenta, hotpink, fuchsia). 6 purples for reviews. Each tint is as strong as it can be while the active tab's text (drawn in the tab bar colour) stays readable. The colour goes on the frame only, never on the panes or the sidebar background.
- **The space you're in**: tinted tab bar, active tab and focused pane border in full colour, its Spaces row tinted, Ghostty window title `🔵 <name>`. Worktrees also get `work · <name> · :<port>` (or `review · …`) at the right of the tab bar, and the port in the title.
- **Every coloured space**: its name in its colour in the Spaces and Agents lists, and a worktree's branch line too.
- **Spaces list**: a name too long for the sidebar continues on the next rows, so the whole name always shows (herdr can't wrap or show tooltips, so the script reports the name in parts), and each project's review worktrees always sit last in its group, after the work worktrees.
- **Anything that isn't a git repo**: grey.

A colour is picked the first time a space is seen and kept in `~/.local/state/herdr/project-colours` (per repo) and `worktree-colours` (per worktree). Don't like it? **`cmd+/ p`** moves the space you're in to the next colour of its set that no other open space has: on a main checkout that's the project's colour, on a worktree only that worktree's. The menu stays open, so keep pressing `p` (`P` goes back) until you like it, then esc.

Use one Ghostty window for herdr. With a second one attached, each window can show a different space, but the colours are one config for all of them and follow whichever window switched last, and herdr only updates the title of the window used most recently.

herdr has no per-workspace colours, so `herdr/scripts/worktree-theme.py` writes `~/.config/herdr/config.generated.toml` (your `config.toml` plus the colours) on every workspace switch, worktree create/remove and herdr start, and reloads herdr. herdr reads that file through `HERDR_CONFIG_PATH` (set in `shell/.zshenv` once the file exists, which needs **one herdr restart** to take effect).

- Edit `~/.config/herdr/config.toml` as usual, then run **`herdr-reload`** (plain `herdr server reload-config` reloads the old generated copy).
- To validate your edits: `env -u HERDR_CONFIG_PATH herdr config check`.
- Name colours go onto `config.toml` rows marked `# worktree-colors`.

## Per-machine things (not in the repo)

- **Claude instructions with project names or commands**: `~/.claude/CLAUDE.local.md`, imported at the end of `claude/CLAUDE.md`. Anything naming a work project goes there, since this repo is public.
- **Worktree setup scripts**: `~/.config/herdr/worktree-setup/<repo-folder>.sh` runs in each new worktree of that repo (for example `pnpm install`, or `cp "$REPO_ROOT/.env" .env`). Create or edit one with `cmd+shift+e` from inside the repo. These are gitignored here because repos differ per machine.
- **Worktree tabs**: `~/.config/herdr/worktree-setup/<repo>.work` and `<repo>.review`, one tab per line (`name | command`). Start from `herdr/examples/`.
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
