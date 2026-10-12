#!/usr/bin/env bash
# The worktree's pull request as a docs page (md-pager.sh): title, status, branches, reviewers and
# their votes, then the description. Runs in the review `pr` tab. r pulls the latest, o opens it.
#   pr-view.sh [worktree]            the page (default: the current directory)
#   pr-view.sh markdown <worktree>   print it as Markdown
# The PR is the worktree's saved link, or the branch's newest PR (worktree-pr.sh find).
set -u

PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
S="$HOME/.config/herdr/scripts"

# Azure DevOps vote -> what the PR page shows
vote_text() {
  case "$1" in
    10) echo "✅ approved" ;;
    5) echo "☑️ approved with suggestions" ;;
    -5) echo "⏳ waiting for author" ;;
    -10) echo "❌ rejected" ;;
    *) echo "○ no vote yet" ;;
  esac
}

markdown() { # $1 worktree
  local dir=$1 url json branch
  url=$("$S/worktree-pr.sh" find "$dir" 2>/dev/null || true)
  if [ -z "$url" ]; then
    branch=$(git -C "$dir" symbolic-ref -q --short HEAD || echo "(detached)")
    printf '# No pull request yet\n\nNone found for `%s`. Press **r** to look again.\n' "$branch"
    return
  fi
  json=$(az repos pr show --org "$(echo "$url" | cut -d/ -f1-4)" --detect false --id "${url##*/}" -o json) ||
    return 1
  jq -r --arg url "$url" '
    def ref: sub("^refs/heads/"; "");
    def status: if .isDraft then "draft"
      elif .status == "completed" then "merged"
      else .status end;
    "# \(.title)\n",
    "**!\(.pullRequestId)** · \(status) · by \(.createdBy.displayName) · opened \(.creationDate[0:10])",
    "`\(.sourceRefName | ref)` → `\(.targetRefName | ref)`" +
      (if .mergeStatus == "conflicts" then " · ⚠️ **merge conflicts**" else "" end),
    "",
    "\($url)",
    ""' <<<"$json"
  printf '## Reviewers\n\n'
  jq -r '.reviewers[] | [.vote, .displayName, (if .isRequired then " (required)" else "" end)] | @tsv' <<<"$json" |
    while IFS=$'\t' read -r vote name required; do
      printf -- '- %s · %s%s\n' "$(vote_text "$vote")" "$name" "$required"
    done
  printf '\n## Description\n\n'
  jq -r '.description // "_No description._"' <<<"$json"
}

if [ "${1:-}" = markdown ]; then markdown "$2"; exit; fi

dir=$(git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null || echo "${1:-$PWD}")
q=$(printf '%q' "$dir")
exec "$S/md-pager.sh" "$S/pr-view.sh markdown $q" "open \"\$($S/worktree-pr.sh get $q)\""
