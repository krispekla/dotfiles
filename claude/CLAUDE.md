# Code review output: Hunk

When doing a code review (a branch, a diff or a PR, including `/review-pr`), also put the findings
into Hunk as inline notes, not only as a chat table.

- Check for a live session first: `hunk session list` (match the review's repo/worktree path).
- Push every finding in one batch with `hunk session comment apply --repo <path> --stdin --focus`
  (`filePath` repo-relative, `newLine`, a one-line `summary`, details in `rationale`). The
  `hunk-review` skill has the full command reference.
- Never launch `hunk diff` or other interactive Hunk commands yourself; the TUI belongs to the user.
  If no session matches, tell the user and suggest they open one.
- herdr review worktrees open a Hunk pane automatically on the whole branch diff
  (`hunk diff --watch <merge-base with main>`), so a session usually already exists there.
- Hunk notes are local to the session. Posting them to the PR stays a separate, explicit request.

# Coding workflow: Hunk

The user toggles a live Hunk pane of uncommitted changes with herdr (`prefix+shift+r`). Use it
when it is open; never open it yourself.

- **After finishing a coding task:** if `hunk session list` shows a session for the repo, add a
  few notes (one `comment apply` batch) on the non-obvious parts only: why an approach was chosen,
  a risky edge case, something to verify by hand. Skip routine edits. No session: do nothing.
- **When the user says to check their Hunk comments:** read them with
  `hunk session comment list --repo <path> --type user`, address each one in the code, then reply
  on each with `hunk session comment add --repo <path> --reply-to <note-id> --summary "<what changed>"`.
- The pane runs with `--watch`, so notes on a file can drop when that file changes; re-add them
  if asked.

# Reviewing someone else's PR: Hunk to the PR

Hunk notes are the draft; the PR is where approved comments get published, under the user's name,
only when they say "push". What the user approves in Hunk is what gets posted.

The PR lives on whatever host the repo uses. Detect it from `git remote get-url origin` and use
that host's CLI (see "Per host" below): `github.com` → `gh`, `dev.azure.com` / `*.visualstudio.com`
→ `az repos`, `gitlab.*` → `glab`. If the CLI is missing or not logged in, say so and stop; don't
fall back to another host or to the browser.

1. Write each review finding into Hunk already in its final, postable form (see "Code review
   output: Hunk"), so the user reviews the exact wording:
   `<label>: <Observation starting with a capital.>` (the `@<PR owner>` tag is added at post time).
   - Labels follow Conventional Comments (conventionalcomments.org), lowercase: `praise`,
     `nit-pick` (the user's spelling, not `nitpick`), `suggestion`, `issue`, `todo`, `question`, `thought`, `chore`, `note`, `typo`,
     `polish`, `quibble`.
   - Optional decoration right after the label, no space: `(blocking)`, `(non-blocking)`,
     `(if-minor)`. Add one only when it matters; a bare `nit-pick:` is fine.
   - Short and human: one or two sentences. No rule-file citations or review-skill jargon. Put
     longer reasoning in the note's `rationale`, which is never posted.
   - Do not edit the notes after the user starts going through them.
2. The user replies to each note in Hunk: `ok` approves it as written, `x` drops it, any other
   text approves it with that correction (a different label, extra context, or new wording). The
   user's own notes on a line count as approved findings. A note with no reply is NOT approved and
   is never posted.
3. On "push", read the notes and replies (`hunk session review --repo <path> --include-notes --json`)
   and post only approved findings. The user picks the mode:
   - separate threads: one comment per finding, anchored to its file and line, each starting with
     the owner mention: `@<PR owner> <label>: <Observation>`;
   - one thread: one PR-level comment, mentioning the owner once, with each finding as a list item
     naming `file:line`.
4. Before posting: check local HEAD equals the PR's head commit (otherwise line anchors drift) and
   skip findings an existing comment already covers. Show only the findings whose text changed
   because of a correction reply; approved `ok` notes post exactly as written. Then post.
5. After posting, report the PR URL and comment count; clear the Hunk notes only if the user asks.

## Per host

| | GitHub (`gh`) | Azure DevOps (`az repos`) | GitLab (`glab`) |
|---|---|---|---|
| Find the PR | `gh pr view <branch> --json number,url,author,headRefOid` | `az repos pr list --source-branch <branch> --status active` | `glab mr view <branch> -F json` |
| Owner mention | `@<author.login>` | `@<{identity-id}>`, id from `createdBy.id` | `@<author.username>` |
| PR head commit | `headRefOid` | `lastMergeSourceCommit.commitId` | `sha` |
| Existing comments | `gh api repos/{owner}/{repo}/pulls/<n>/comments` and `gh pr view <n> --comments` | `az rest` GET on the PR's `threads` | `glab api projects/:id/merge_requests/<iid>/discussions` |
| Line comments | one review with all comments: `gh api repos/{owner}/{repo}/pulls/<n>/reviews` with `event=COMMENT`, `commit_id`, `comments[]` (`path`, `line`, `side=RIGHT`, `body`) | `az rest` POST to the PR's `threads`, one thread per finding with `threadContext` (`filePath`, `rightFileStart`/`rightFileEnd`) | `glab api` POST to `.../discussions` per finding with `position` (`position_type=text`, `base_sha`, `start_sha`, `head_sha`, `new_path`, `new_line`) |
| One PR-level comment | `gh pr comment <n> --body-file -` | `az rest` POST to `threads` without `threadContext` | `glab mr note <iid> -m` |

Another host (Bitbucket, Gitea, …): find its CLI or API the same way, show the user the exact
calls, and post only after they agree.
