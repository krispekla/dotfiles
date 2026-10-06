---
name: timesheet
description: Timesheet entries, one short copy-paste line per working day, built from git commits and Claude session prompts. Use when the user asks for their timesheet, what they worked on today, a day, a week or a month, or invokes /timesheet. Optional argument is a date or range (today when empty).
---

# Timesheet

The user copies each day's line into their timesheet as is. Get the format right; it is the whole point.

## Range

- No argument: today.
- A date (`5.10`, `yesterday`, `monday`) or range (`this week`, `october`, `1.10 to today`): every working day (Mon to Fri) in it, up to today.

## Sources

Collect both, for every day in the range, then merge per day:

1. **Commits.** In every git repo under `~/projects` (worktrees share their main repo's log, so one `--all` per repo is enough):
   `git log --all --author="$(git config user.name)" --since=<start> --until=<end+1> --date=format:'%a %d.%m %H:%M' --pretty='%ad  %s'`.
   Merge commits carry no work; skip them.
2. **Claude sessions.** User prompts in `~/.claude/projects/*/*.jsonl` (skip `subagents/`), grouped by the `timestamp` field's local date. Keep `type: "user"` text messages; drop tool results, `isMeta`, interrupts and slash-command noise. The project folder name tells which repo or worktree it was. This catches uncommitted work, investigations, tickets, PR descriptions and support questions.

## Writing a day's line

- Short comma list of topics, named by component or feature as the team would say it: `Datepicker, Datepicker modal migration, Table spacing fixes`.
- Group many commits on one thing into one topic. No ticket IDs, no commit types, no file names.
- Name PR reviews when they took real time: `PR reviews (Stepper, Textarea)`.
- Tooling or environment setup counts as work: `dev tooling setup`.
- **Always end every day with `code review, meetings`**, even when nothing else shows. They are real work that leaves no trace.
- A day with no trace at all: mark it `(no trace, fill in)` and give only `code review, meetings`. Never invent work.
- Today is partial: say so in the notes.

## Output

One bold heading and one `text` code fence per day, so each day has its own copy button:

**01.10 Thu**
```text
API docs Types tab follow-up, Progress indicator accessibility fixes, code review, meetings
```

**02.10 Fri** (no trace, fill in)
```text
code review, meetings
```

Then at most three short notes: days with no trace, judgment calls (a topic you named one way that could be named another), and that today is partial. Nothing else.

## Clipboard

The terminal has no copy button on code fences, so put the text on the clipboard too:

- One day: pipe its line to `pbcopy` and say "Copied to clipboard."
- Several days: copy the last day, say which, and end with "Say a date (e.g. `02.10`) and I'll copy that day." When the user then names a date, `pbcopy` that line and reply with one short sentence only.
- Copy the line exactly as shown in its fence, with no trailing newline (`printf '%s' '<line>' | pbcopy`).

No em dashes anywhere.
