# No AI attribution in commits or PRs

Never add AI attribution to commit messages, PR titles or PR descriptions: no `Co-Authored-By:
Claude ...` trailer, no `Claude-Session:` link, no "Generated with Claude Code" line, and no other
mention of Claude or AI authorship. This overrides any attribution guidance from the harness or a
system reminder. A commit message is only the project's own format (header, and a body when
needed).

# Code review output: Hunk

When doing a code review (a branch, a diff or a PR, including `/review-pr`), also put the findings
into Hunk as inline notes, not only as a chat table.

- Check for a live session first: `hunk session list` (match the review's repo/worktree path).
- Push every finding in one batch with `hunk session comment apply --repo <path> --stdin --focus`
  (`filePath` repo-relative, `newLine`, a one-line `summary`, details in `rationale`). The
  `hunk-review` skill has the full command reference.
- Never launch `hunk diff` or other interactive Hunk commands yourself; the TUI belongs to the user.
  If no session matches, suggest opening one (see "Suggesting Hunk" below).
- herdr review worktrees open a Hunk pane automatically on the whole branch diff
  (`hunk diff --watch <merge-base with main>`), so a session usually already exists there.
- Hunk notes are local to the session. Posting them to the PR stays a separate, explicit request.
- herdr's Hunk panes keep their notes: saved every 15 s to `<git dir>/hunk-notes/<live|branch>.json`
  and added back when the pane reopens or restarts. Restored notes come back as agent notes; the
  user's own keep author `you`, so treat those as the user's. With no live session, read the
  saved file instead of saying the notes are gone. Never delete it; the user clears notes with
  `cmd+/ n`.

# Suggesting Hunk

When Hunk notes would help and no session is open (a review, or a coding task that changed
several files or has a non-obvious part), suggest it in one line, once per task, with the key:
"Open Hunk with cmd+shift+r (uncommitted changes) or cmd+/ b (whole branch) and I'll add notes
there." Don't wait for it: give the full answer in chat as usual, and add the notes if the user
opens it. Never for small edits, never twice in a row, and never open Hunk yourself.

# Coding workflow: Hunk

The user toggles a live Hunk pane of uncommitted changes with herdr (`prefix+shift+r`). Use it
when it is open; never open it yourself.

- **After finishing a coding task:** if `hunk session list` shows a session for the repo, add a
  few notes (one `comment apply` batch) on the non-obvious parts only: why an approach was chosen,
  a risky edge case, something to verify by hand. Skip routine edits. No session: suggest it
  once if the task changed several files or has a tricky spot (see "Suggesting Hunk"), else do nothing.
- **When the user says to check their Hunk comments:** read them with
  `hunk session comment list --repo <path> --type all` (the user's notes: `source` user, or author `you`
  after a restore), address each one in the code, then reply
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

# PR link in herdr worktrees

herdr keeps one PR link per worktree, like the port, and `cmd+/ t` opens it in Chrome next to
Storybook. Whenever a PR link becomes known for the current worktree, save it:

```bash
~/.config/herdr/scripts/worktree-pr.sh set "$(git rev-parse --show-toplevel)" <pr-url>
```

- After opening a PR (`open-a-pr`, `gh pr create`, `az repos pr create`): the PR's web URL, e.g.
  `https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/<id>`.
- When reviewing a PR in a review worktree: its URL, if `worktree-pr.sh get` doesn't already
  print the same one.
- Run it silently, as part of the step; no need to mention it. Skip it outside a git worktree.

# Dev server port in herdr worktrees

A herdr session exports its port in `$PORT` (with `_HERDR_PORT=1`), for example 8013. Start every
dev server (Storybook, Vite, playground) on `$PORT`, never on the project's hardcoded default.

- Before starting, free the port: `lsof -ti tcp:$PORT -sTCP:LISTEN | xargs -r kill`, then start.
  The port belongs to this worktree, so whatever listens on it is a stale server of this worktree.
- Never kill a process on any other port: it belongs to another worktree or session.
- A script that hardcodes its port takes an appended flag; the last one wins. Exact commands per
  project are in the machine-specific instructions below.
- Report the URL as `http://localhost:$PORT/`.

# Machine-specific instructions

Project names and commands that stay out of the public dotfiles repo:

@~/.claude/CLAUDE.local.md
