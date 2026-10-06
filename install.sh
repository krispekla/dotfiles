#!/usr/bin/env bash
# Link this repo's config into place. See README.md and CLAUDE.md.
#   ./install.sh --check   show the state of every file and diffs; changes nothing
#   ./install.sh           link files that are missing or identical; skip ones that differ
# Anything replaced is moved to ~/.dotfiles-backup/<timestamp>/ first.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"

check=0
case "${1:-}" in
  --check) check=1 ;;
  "") ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

# repo path | target, relative to $HOME | link or merge
# merge: never linked. Tools or the machine itself write into these (herdr's Claude hook,
# AeroSpace monitor layout), so they are compared and merged by hand. Copied in only if missing.
entries() {
  cat <<'EOF'
herdr/config.toml|.config/herdr/config.toml|link
herdr/cheatsheet.txt|.config/herdr/cheatsheet.txt|link
herdr/agent|.config/herdr/agent|link
herdr/plugins/kris-tools/herdr-plugin.toml|.config/herdr/plugins/kris-tools/herdr-plugin.toml|link
ghostty/config.ghostty|Library/Application Support/com.mitchellh.ghostty/config.ghostty|link
nvim|.config/nvim|link
lazygit/config.yml|Library/Application Support/lazygit/config.yml|link
hunk/config.toml|.config/hunk/config.toml|link
claude/statusline.sh|.claude/statusline.sh|link
claude/CLAUDE.md|.claude/CLAUDE.md|link
claude/skills/timesheet|.claude/skills/timesheet|link
shell/.zshenv|.zshenv|link
shell/essentials.zsh|.config/zsh/essentials.zsh|link
claude/settings.json|.claude/settings.json|merge
aerospace/aerospace.toml|.config/aerospace/aerospace.toml|merge
EOF
  # Scripts are linked one by one so their logs stay out of the repo
  for f in "$REPO"/herdr/scripts/*.sh "$REPO"/herdr/scripts/*.py; do
    [ -f "$f" ] && printf 'herdr/scripts/%s|.config/herdr/scripts/%s|link\n' "${f##*/}" "${f##*/}"
  done
}

same() { # identical content, file or directory
  if [ -d "$1" ]; then diff -rq "$1" "$2" >/dev/null 2>&1; else cmp -s "$1" "$2"; fi
}

backup() {
  mkdir -p "$(dirname "$BACKUP/$1")"
  mv "$HOME/$1" "$BACKUP/$1"
}

requirements() { # fresh login + interactive zsh, like a new terminal: PATH and fzf come only from your zsh config
  env -i HOME="$HOME" USER="${USER:-}" TERM="${TERM:-xterm-256color}" PATH=/usr/bin:/bin:/usr/sbin:/sbin zsh -lic '
    r() { if eval "$2" >/dev/null 2>&1; then echo "REQ ok       $1"; else echo "REQ missing  $1  ($3)"; fi; }
    for c in herdr hunk claude nvim lazygit jq gh lf fzf rg fd gitleaks; do
      r "$c" "command -v $c" "see README install steps"
    done
    r "fzf keys (ctrl+r, ctrl+t)" "(( \$+functions[fzf-history-widget] ))" "load ~/.config/zsh/essentials.zsh from ~/.zshrc"
    r "EDITOR=nvim" "[ \"\$EDITOR\" = nvim ]" "link shell/.zshenv"
    r "Ghostty.app" "[ -d /Applications/Ghostty.app ]" "download from ghostty.org"
    r "AeroSpace.app" "[ -d /Applications/AeroSpace.app ]" "brew bundle"
    r "herdr plugin kris.tools" "herdr plugin list | grep -q kris.tools" "herdr plugin link ~/.config/herdr/plugins/kris-tools"
    r "herdr Claude integration" "herdr integration status | grep -q \"^claude: current\"" "herdr integration install claude"
    r "herdr Copilot integration (if copilot is installed)" "! command -v copilot || herdr integration status | grep -q \"^copilot: current\"" "herdr integration install copilot"
    r "Claude hunk-review skill" "[ -e ~/.claude/skills/hunk-review/SKILL.md ]" "mkdir -p ~/.claude/skills && ln -sfn \"\$(dirname \"\$(hunk skill path hunk-review)\")\" ~/.claude/skills/hunk-review"
  ' </dev/null 2>/dev/null | sed -n 's/^REQ //p'
  # herdr's server must have been started with HERDR_CONFIG_PATH (from a shell opened after
  # .zshenv set it), or worktree colours never show
  server=$(ps -axo pid=,command= | awk '$2 ~ /herdr$/ && $3 == "server" {print $1}' | head -n 1 || true)
  server_env=" $( [ -n "$server" ] && ps eww -p "$server" -o command= 2>/dev/null || true) "
  if [ -z "$server" ]; then
    echo "missing  herdr server running  (start herdr)"
  elif case "$server_env" in *" HERDR_CONFIG_PATH="*) true ;; *) false ;; esac; then
    echo "ok       herdr server reads the generated config (worktree colours)"
  else
    echo "missing  herdr server reads the generated config  (herdr server stop, then run herdr in a NEW terminal tab)"
  fi
  if [ "$(git -C "$REPO" config core.hooksPath)" = .githooks ]; then
    echo "ok       pre-commit check (gitleaks + home paths)"
  else
    echo "missing  pre-commit check  (run ./install.sh)"
  fi
}

differs=0
while IFS='|' read -r src dst mode; do
  s="$REPO/$src" d="$HOME/$dst"
  if [ -L "$d" ] && [ "$(readlink "$d")" = "$s" ]; then state=linked
  elif [ ! -e "$d" ] && [ ! -L "$d" ]; then state=missing
  elif same "$s" "$d"; then state=same
  else state=differs; fi

  printf '%-8s %-6s ~/%s\n' "$state" "$mode" "$dst"
  [ "$state" = differs ] && differs=$((differs + 1))

  if [ "$check" = 1 ]; then
    # - local, + repo
    [ "$state" = differs ] && { diff -ru "$d" "$s" | sed 's/^/    /' || true; }
    continue
  fi

  case "$mode:$state" in
    link:missing)  mkdir -p "$(dirname "$d")"; ln -s "$s" "$d"; echo "         -> linked" ;;
    link:same)     backup "$dst"; ln -s "$s" "$d"; echo "         -> backed up, linked" ;;
    merge:missing) mkdir -p "$(dirname "$d")"; cp "$s" "$d"; echo "         -> copied (merge file, not linked)" ;;
  esac
done < <(entries)

if [ "$check" = 0 ]; then
  mkdir -p "$HOME/.config/herdr/worktree-setup"
  # Secret and home-path check before every commit in this repo
  git -C "$REPO" config core.hooksPath .githooks
  # Generated herdr config with worktree colours; .zshenv points herdr at it once it exists
  "$HOME/.config/herdr/scripts/worktree-theme.py" || echo "worktree-theme.py failed: herdr keeps using config.toml"
  [ -d "$BACKUP" ] && echo "Backups: $BACKUP"
fi
if [ "$check" = 1 ]; then
  echo
  echo "Requirements:"
  requirements | sed 's/^/  /'
fi
if [ "$differs" -gt 0 ]; then
  echo
  echo "$differs differ. install skips differing link files: merge them into the repo, commit, run again."
  echo "merge ones are never linked: merge by hand in whichever direction is right."
fi
