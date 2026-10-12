#!/bin/sh
# PR registry: the pull request link of each worktree, and the task link(s) from that PR's
# description, saved once they're known, like worktree-port.sh.
#   worktree-pr.sh set <worktree> <url>   save the PR link (Claude does this after opening or reviewing a PR)
#   worktree-pr.sh get <worktree>         print the saved PR link, if any
#   worktree-pr.sh find <worktree>        print the saved PR link; with none, ask Azure DevOps for the
#                                         branch's newest PR (any status) and save that
#   worktree-pr.sh task <worktree>        print the saved task link(s), one per line; with none, read
#                                         them from the PR's description (Jira .../browse/KEY-123 links)
#                                         and save them. Asks again next time while there are none.
#   worktree-pr.sh free <worktree>        forget both (cmd+/ x does this)
# Registry: ${XDG_STATE_HOME:-~/.local/state}/herdr/prs, one "worktree<TAB>pr<TAB>tasks" per line
# (tasks space-separated, may be empty). Entries for deleted worktree folders are dropped on every
# write. Read by pr-view.sh (the review `pr` tab), worktree-ticket.sh and agent-prompt.sh, which
# fill it in on first use.
set -eu

PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
reg="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/prs"
mkdir -p "$(dirname "$reg")"
touch "$reg"
tab=$(printf '\t')

cmd=${1:-}
[ $# -ge 2 ] || { echo "usage: $0 set|get|find|task|free <worktree> [url]" >&2; exit 2; }
# Same form worktree-port.sh keys on: the worktree's top level, if it still exists
dir=$(git -C "$2" rev-parse --show-toplevel 2>/dev/null || echo "$2")

lookup() { awk -F'\t' -v d="$dir" -v col="$1" '$1 == d { print $col; exit }' "$reg"; }

# One writer at a time
lock() {
  n=0
  until mkdir "$reg.lock" 2>/dev/null; do
    n=$((n + 1)); [ $n -gt 50 ] && rm -rf "$reg.lock"  # stale after ~5s
    sleep 0.1
  done
  trap 'rmdir "$reg.lock" 2>/dev/null' EXIT INT TERM
}

# save <pr> <tasks>: rewrites the registry without this worktree's line and without lines for
# deleted folders, then appends this worktree's (empty pr = just forget it)
save() {
  lock
  tmp=$(mktemp "$reg.XXXXXX")
  # Own names: sh has no locals, and the callers use url/tasks
  while IFS="$tab" read -r line_dir line_pr line_tasks; do
    [ -n "$line_dir" ] && [ "$line_dir" != "$dir" ] && [ -d "$line_dir" ] &&
      printf '%s\t%s\t%s\n' "$line_dir" "$line_pr" "$line_tasks"
  done < "$reg" > "$tmp" || true
  [ -n "$1" ] && printf '%s\t%s\t%s\n' "$dir" "$1" "$2" >> "$tmp"
  mv "$tmp" "$reg"
  rmdir "$reg.lock" 2>/dev/null || true
  trap - EXIT INT TERM
}

# Newest PR whose source is this worktree's branch, on an Azure DevOps origin
# (git@ssh.dev.azure.com:v3/<org>/<project>/<repo> or https://dev.azure.com/<org>/<project>/_git/<repo>)
azure_pr() {
  branch=$(git -C "$dir" symbolic-ref -q --short HEAD) || return 0
  remote=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 0
  case "$remote" in *dev.azure.com*) ;; *) return 0 ;; esac
  repo_url=$(printf '%s' "$remote" | sed -E 's#^.*dev\.azure\.com[:/](v3/)?([^/]+)/([^/]+)/(_git/)?([^/]+)$#https://dev.azure.com/\2/\3/_git/\5#')
  id=$(az repos pr list --org "$(echo "$repo_url" | cut -d/ -f1-4)" \
    --project "$(echo "$repo_url" | cut -d/ -f5)" --repository "$(echo "$repo_url" | cut -d/ -f7)" \
    --source-branch "$branch" --status all --top 1 --query '[0].pullRequestId' -o tsv 2>/dev/null || true)
  [ -n "$id" ] && echo "$repo_url/pullrequest/$id"
  return 0
}

# Task links in the description of the PR at $1 (https://dev.azure.com/<org>/.../pullrequest/<id>),
# space-separated, in order of appearance, no repeats
azure_tasks() {
  case "$1" in https://dev.azure.com/*/pullrequest/*) ;; *) return 0 ;; esac
  az repos pr show --org "$(echo "$1" | cut -d/ -f1-4)" --detect false --id "${1##*/}" \
    --query description -o tsv 2>/dev/null |
    grep -Eo 'https?://[^][ <>()"'"'"']+/browse/[A-Z][A-Z0-9]*-[0-9]+' |
    awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//' || true
}

case "$cmd" in
  get) lookup 2 ;;
  set)
    [ $# -eq 3 ] && [ -n "$3" ] || { echo "usage: $0 set <worktree> <url>" >&2; exit 2; }
    # A different PR gets its tasks read again
    tasks=$([ "$(lookup 2)" = "$3" ] && lookup 3 || true)
    save "$3" "$tasks" ;;
  find)
    url=$(lookup 2)
    if [ -z "$url" ]; then
      url=$(azure_pr)
      [ -n "$url" ] && save "$url" ""
    fi
    [ -n "$url" ] && echo "$url"
    exit 0 ;;
  task)
    tasks=$(lookup 3)
    if [ -z "$tasks" ]; then
      url=$("$0" find "$dir")
      tasks=$(azure_tasks "$url")
      [ -n "$tasks" ] && save "$url" "$tasks"
    fi
    [ -n "$tasks" ] && printf '%s\n' $tasks
    exit 0 ;;
  free) save "" "" ;;
  *) echo "usage: $0 set|get|find|task|free <worktree> [url]" >&2; exit 2 ;;
esac
