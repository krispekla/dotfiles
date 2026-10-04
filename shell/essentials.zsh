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
