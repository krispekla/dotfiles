#!/bin/sh
# Types a starter prompt into a new worktree's agent, without Enter: you read it, edit it, send it.
# Started in the background by worktree-created.sh (work) and review-worktree.sh (review).
# Usage: agent-prompt.sh <pane> <worktree> <work|review> <setup marker>
# Prompts are per repo, per machine, in ~/.config/herdr/worktree-setup/<repo>.<work|review>-prompt:
# one template per line, # comments ignored; the first line whose placeholders all resolve is typed.
#   {branch}         the branch
#   {pr}             the worktree's PR link (worktree-pr.sh find)
#   {ticket}         the ticket key: in the branch name (feat/abc-1234-x -> ABC-1234), else the first
#                    task linked in the PR's description (worktree-ticket.sh)
#   {ticket:ABC}     the same, only for project ABC
# No file, or no line resolves: nothing is typed.
set -u
exec >>"$HOME/.config/herdr/scripts/agent-prompt.log" 2>&1
echo "--- $(date) $*"

PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
herdr="${HERDR_BIN_PATH:-herdr}"
S="$HOME/.config/herdr/scripts"
pane=$1 path=$2 kind=$3 marker=$4

root=$(dirname "$(git -C "$path" rev-parse --path-format=absolute --git-common-dir)")
file="$HOME/.config/herdr/worktree-setup/$(basename "$root").$kind-prompt"
[ -f "$file" ] || exit 0
branch=$(git -C "$path" symbolic-ref -q --short HEAD || echo "")

# Setup first (up to 30 min); the agent only starts when it succeeded
n=0
until [ -e "$marker" ]; do
  n=$((n + 1)); [ $n -gt 1800 ] && { echo "setup never finished"; exit 0; }
  sleep 1
done
# The marker holds setup's exit code (setup-run.sh); empty when the repo has no setup
s=$(cat "$marker" 2>/dev/null)
[ -z "$s" ] || [ "$s" = 0 ] || { echo "setup failed ($s), no prompt"; exit 0; }

ticket() { "$S/worktree-ticket.sh" "$path" "$1"; }

text=""
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  ok=1
  for ph in $(printf '%s\n' "$line" | grep -oE '\{[a-z]+(:[A-Za-z]+)?\}' | sort -u); do
    case "$ph" in
      '{branch}') val=$branch ;;
      '{pr}') val=$("$S/worktree-pr.sh" find "$path" 2>/dev/null || true) ;;
      '{ticket}') val=$(ticket "") ;;
      '{ticket:'*) p=${ph#\{ticket:}; val=$(ticket "${p%\}}") ;;
      *) val="" ;;
    esac
    [ -n "$val" ] || { ok=0; break; }
    line=$(printf '%s' "$line" | awk -v ph="$ph" -v val="$val" '{ i = index($0, ph); while (i) { $0 = substr($0, 1, i - 1) val substr($0, i + length(ph)); i = index($0, ph) } print }')
  done
  [ $ok -eq 1 ] && { text=$line; break; }
done < "$file"
[ -n "$text" ] || { echo "no template resolved for $branch"; exit 0; }

# Wait until the agent is up and idle at its prompt (up to 2 min), then type without Enter
n=0
until [ "$("$herdr" agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // empty')" = idle ]; do
  n=$((n + 1)); [ $n -gt 120 ] && { echo "agent never became idle"; exit 0; }
  sleep 1
done
sleep 2  # the input box draws a moment after the agent reports idle
"$herdr" pane send-text "$pane" "$text" >/dev/null && echo "typed: $text"
