# Shell bits the herdr setup needs, nothing else. Loaded from ~/.zshrc:
#   [ -f ~/.config/zsh/essentials.zsh ] && source ~/.config/zsh/essentials.zsh
# Only adds what's missing, so it never reorders an existing PATH.

# herdr and claude live in ~/.local/bin, hunk in ~/.hunk/bin
for d in "$HOME/.local/bin" "$HOME/.hunk/bin"; do
  [[ -d $d && ":$PATH:" != *":$d:"* ]] && path+=("$d")
done
unset d

# fzf keys: ctrl+r history search, ctrl+t file picker (see herdr cheatsheet)
if command -v fzf >/dev/null && (( ! $+functions[fzf-history-widget] )); then
  source <(fzf --zsh)
fi

# $PORT inside herdr worktrees: each worktree has its own dev-server port (herdr/scripts/worktree-port.sh).
# Checked before each prompt and command, but only re-read when the directory or the registry changes.
zmodload -F zsh/stat b:zstat 2>/dev/null
typeset -g _herdr_port_key=
_herdr_port() {
  local reg=${XDG_STATE_HOME:-$HOME/.local/state}/herdr/ports top p
  local -a m
  [[ -f $reg ]] && zstat -A m +mtime -- $reg 2>/dev/null
  [[ "$PWD|${m[1]:-}" == "$_herdr_port_key" ]] && return
  _herdr_port_key="$PWD|${m[1]:-}"
  top=$(git rev-parse --show-toplevel 2>/dev/null)
  [[ -n $top && -f $reg ]] && p=$(awk -F'\t' -v d="$top" '$2 == d { print $1; exit }' $reg)
  if [[ -n $p ]]; then
    export PORT=$p _HERDR_PORT=1
  elif [[ -n ${_HERDR_PORT:-} ]]; then
    unset PORT _HERDR_PORT  # left a worktree: drop the port we set, keep anyone else's
  fi
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _herdr_port
add-zsh-hook preexec _herdr_port  # commands typed in by herdr right after the shell starts

# After editing ~/.config/herdr/config.toml: regenerate herdr's coloured config and reload it
# (plain `herdr server reload-config` would reload the old generated copy)
alias herdr-reload='~/.config/herdr/scripts/worktree-theme.py --reload'
