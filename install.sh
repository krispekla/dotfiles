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
shell/.zshenv|.zshenv|link
claude/settings.json|.claude/settings.json|merge
aerospace/aerospace.toml|.config/aerospace/aerospace.toml|merge
EOF
  # Scripts are linked one by one so their logs stay out of the repo
  for f in "$REPO"/herdr/scripts/*.sh; do
    printf 'herdr/scripts/%s|.config/herdr/scripts/%s|link\n' "${f##*/}" "${f##*/}"
  done
}

same() { # identical content, file or directory
  if [ -d "$1" ]; then diff -rq "$1" "$2" >/dev/null 2>&1; else cmp -s "$1" "$2"; fi
}

backup() {
  mkdir -p "$(dirname "$BACKUP/$1")"
  mv "$HOME/$1" "$BACKUP/$1"
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
  [ -d "$BACKUP" ] && echo "Backups: $BACKUP"
fi
if [ "$differs" -gt 0 ]; then
  echo
  echo "$differs differ. install skips differing link files: merge them into the repo, commit, run again."
  echo "merge ones are never linked: merge by hand in whichever direction is right."
fi
