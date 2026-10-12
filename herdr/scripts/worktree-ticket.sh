#!/bin/sh
# Prints the ticket key of a worktree: the first KEY-123 in its branch name (2+ letters, 3+ digits,
# upper-cased: feat/abc-1234-x -> ABC-1234), else the first task linked in its PR's description
# (worktree-pr.sh task). Prints nothing when there's none.
# Usage: worktree-ticket.sh <worktree> [PROJECT]   PROJECT: only keys of that project, e.g. ABC
set -u

PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
path=$1 want=${2:-}

# first_key: the first KEY-123 of stdin, as words split on / _ - and other separators
first_key() {
  tr -c 'A-Za-z0-9\n' '\n' | awk -v want="$want" '
    prev ~ /^[A-Za-z][A-Za-z]+$/ && $0 ~ /^[0-9][0-9][0-9]+$/ &&
      (want == "" || toupper(prev) == toupper(want)) { print toupper(prev) "-" $0; exit }
    { prev = $0 }'
}

key=$(git -C "$path" symbolic-ref -q --short HEAD 2>/dev/null | first_key)
[ -n "$key" ] || key=$("$HOME/.config/herdr/scripts/worktree-pr.sh" task "$path" 2>/dev/null | sed 's#.*/browse/##' | first_key)
[ -n "$key" ] && echo "$key"
exit 0
