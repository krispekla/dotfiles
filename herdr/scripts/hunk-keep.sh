#!/bin/sh
# Runs `hunk diff --watch` in a herdr pane (started by hunk-pane.sh) and keeps its review notes:
# the pane registers with one shared saver (hunk-notes.py watch), which saves the notes to
# <git dir>/hunk-notes/<mode>.json, adds them back when hunk starts, and restarts hunk (notes
# saved first) above HUNK_MAX_MB (default 700): its watch mode keeps memory after every reload.
#   hunk-keep.sh live|branch [hunk diff target]
# q in hunk still closes the pane: only a memory restart starts it again.
mode=$1
shift
S="$HOME/.config/herdr/scripts"
dir="$(git rev-parse --path-format=absolute --git-dir)/hunk-notes"
panes="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/hunk-panes"
restart="$dir/.restart-$$"
mkdir -p "$dir" "$panes"
printf '%s\t%s\t%s\n' "$dir/$mode.json" "${HUNK_MAX_MB:-700}" "$restart" > "$panes/$$"
trap 'rm -f "$panes/$$" "$restart"' EXIT
trap 'exit 1' HUP INT TERM  # herdr closing the pane: still run the EXIT cleanup

# The saver exits on its own once no pane is left; start it if it isn't running (it locks)
nohup "$S/hunk-notes.py" watch >/dev/null 2>&1 &

while :; do
  rm -f "$restart"
  hunk diff --watch "$@"
  [ -f "$restart" ] || break
  touch "$panes/$$"  # wake the saver: the restarted hunk gets its notes back right away
done
