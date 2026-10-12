#!/usr/bin/env bash
# The worktree's Jira ticket as a docs page (md-pager.sh): summary, status, people, linked tickets,
# description and comments. Needs the `trac` CLI, signed in. r pulls the latest, o opens it.
#   ticket-view.sh [PROJECT] [worktree]     the page (worktree: default the current directory)
#   ticket-view.sh markdown <worktree> [PROJECT]
# The ticket is worktree-ticket.sh's: the KEY-123 in the branch name, else the PR's first task link.
# PROJECT keeps it to that project's keys, e.g. ticket-view.sh ABC.
set -u

PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
S="$HOME/.config/herdr/scripts"

# Jira's address from trac's own settings, so no host is written here
base_url() { trac auth status 2>/dev/null | awk '$1 == "URL:" { print $2; exit }'; }

markdown() { # $1 worktree, $2 project
  local key branch
  command -v trac >/dev/null || { printf '# No ticket viewer\n\nThe `trac` CLI is not installed.\n'; return; }
  key=$("$S/worktree-ticket.sh" "$1" "${2:-}")
  if [ -z "$key" ]; then
    branch=$(git -C "$1" symbolic-ref -q --short HEAD || echo "(detached)")
    printf '# No ticket\n\n`%s` names no %sticket, and its PR links none.\n' "$branch" "${2:+$2 }"
    return
  fi
  trac issue get "$key" --include-comments --no-cache | "$S/jira-md.py" "$(base_url)"
}

if [ "${1:-}" = markdown ]; then markdown "$2" "${3:-}"; exit; fi

project=""
case "${1:-}" in [A-Za-z]*) [ -d "$1" ] || { project=$1; shift; } ;; esac
dir=$(git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null || echo "${1:-$PWD}")
q=$(printf '%q' "$dir")
exec "$S/md-pager.sh" "$S/ticket-view.sh markdown $q $project" \
  "k=\$($S/worktree-ticket.sh $q $project) && [ -n \"\$k\" ] && open \"\$(trac auth status | awk '\$1 == \"URL:\" { print \$2; exit }')/browse/\$k\""
