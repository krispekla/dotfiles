#!/usr/bin/env bash
# Full-screen Markdown page, rendered like a docs page (glow, at most 100 columns, centred), with a
# key to pull the latest. pr-view.sh and ticket-view.sh run in it.
#   md-pager.sh <fetch command> [open command]
#     <fetch command>  prints the page as Markdown; runs at start and on r
#     [open command]   runs on o, e.g. opens the page's source in the browser
#   j/k ↓/↑ scroll · space/b page · d/u half page · g/G top/bottom · mouse wheel · r refresh · q quit
#   md-pager.sh --fetch|--show <cache> <fetch command>   (internal)
set -u

PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
self="$HOME/.config/herdr/scripts/md-pager.sh"

fetch() { # $1 cache, $2 fetch command
  local tmp
  tmp=$(mktemp "$1.XXXXXX")
  if ! bash -c "$2" > "$tmp" 2> "$tmp.err"; then
    printf '# Could not load this page\n\n```\n%s\n```\n\nPress **r** to try again.\n' "$(cat "$tmp.err")" >> "$tmp"
  fi
  rm -f "$tmp.err"
  printf '\n---\n\n_Updated %s · r refresh%s · q quit_\n' "$(date +%H:%M)" "${OPEN_HINT:-}" >> "$tmp"
  mv "$tmp" "$1"
}

show() { # $1 cache, $2 fetch command
  [ -f "$1" ] || fetch "$1" "$2"
  # Inside fzf's preview, glow sees no terminal: force colour
  local cols=${FZF_PREVIEW_COLUMNS:-100} width=100
  [ "$cols" -lt $((width + 2)) ] && width=$((cols - 2))
  CLICOLOR_FORCE=1 glow --style "${GLOW_STYLE:-dark}" --width "$width" "$1" |
    sed "s/^/$(printf '%*s' $(( (cols - width) / 2 )) '')/"
}

case "${1:-}" in
  --fetch) fetch "$2" "$3"; exit ;;
  --show) show "$2" "$3"; exit ;;
  ''|-*) echo "usage: md-pager.sh <fetch command> [open command]" >&2; exit 2 ;;
esac

command -v glow >/dev/null || { echo "md-pager.sh needs glow: brew install glow"; exit 1; }
cmd=$1 open_cmd=${2:-}
[ -n "$open_cmd" ] && export OPEN_HINT=" · o open in browser"
cache="${TMPDIR:-/tmp}/herdr-md-pager-$(printf '%s' "$cmd" | shasum | cut -c1-12).md"
q() { printf '%q' "$1"; }

fetch "$cache" "$cmd"
# fzf as a pager: the preview fills the screen, the list and input are hidden
: | fzf --no-input --disabled --ansi --no-info --no-separator --pointer='' \
  --preview "$self --show $(q "$cache") $(q "$cmd")" --preview-window 'up,99%,wrap,border-none' \
  --bind "r:execute-silent($self --fetch $(q "$cache") $(q "$cmd"))+refresh-preview" \
  ${open_cmd:+--bind "o:execute-silent($open_cmd)"} \
  --bind 'j:preview-down,k:preview-up,down:preview-down,up:preview-up' \
  --bind 'space:preview-page-down,b:preview-page-up,d:preview-half-page-down,u:preview-half-page-up' \
  --bind 'g:preview-top,G:preview-bottom,q:abort,esc:abort'
