#!/usr/bin/env python3
"""Keep Hunk review notes: Hunk holds them only in its daemon's memory, so they're gone when
the pane closes, crashes or restarts (modem-dev/hunk#113).

  hunk-notes.py watch
      One saver for every Hunk pane hunk-keep.sh started (each registers itself in PANES).
      Every INTERVAL seconds a single `hunk session list` returns all sessions with their notes;
      a pane's notes file is written only when its notes changed. A new or restarted pane gets
      its saved notes back within a second. Hunk's watch mode keeps memory after every reload,
      so above the pane's limit it saves, touches the pane's restart flag and stops hunk (the
      wrapper starts it again). Exits once no pane has been registered for a minute.
      Cost: one Hunk CLI call (~0.1 s CPU) per INTERVAL for all panes together, plus `ps`.
  hunk-notes.py clear <worktree>
      Clears the notes of the worktree's live Hunk sessions and its saved notes files.

Saved notes come back as agent notes (Hunk has no way to add user notes); the user's keep
author "you" so they can still be told apart. Only notes the session doesn't hold yet come back,
and repeats (same line, text and parent text) are removed from the session and the file, so a
pane restored twice doesn't double its notes. A note whose line isn't in the diff right now
stays in the file and is tried again on the next start, until the notes are cleared.
"""
import fcntl
import json
import os
import signal
import subprocess
import sys
import time

INTERVAL = 15  # seconds between saves: notes made in the last INTERVAL before a crash are lost
STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "herdr")
PANES = os.path.join(STATE, "hunk-panes")  # <wrapper pid> -> "<notes file>\t<max MB>\t<restart flag>"


def run(*args, stdin=None):
    try:
        out = subprocess.run(args, input=stdin, capture_output=True, text=True, timeout=10)
        return json.loads(out.stdout) if out.returncode == 0 else None
    except Exception:
        return None


def ps(pid, field):
    try:
        return int(subprocess.run(["ps", "-o", f"{field}=", "-p", str(pid)], capture_output=True, text=True).stdout)
    except ValueError:
        return None


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def panes():
    """wrapper pid -> (notes file, max MB, restart flag); drops registrations of dead wrappers."""
    found = {}
    for name in os.listdir(PANES) if os.path.isdir(PANES) else []:
        path = os.path.join(PANES, name)
        if not name.isdigit() or not alive(int(name)):
            os.remove(path)
            continue
        try:
            notes_file, max_mb, flag = open(path).read().rstrip("\n").split("\t")
            found[int(name)] = (notes_file, int(max_mb), flag)
        except (OSError, ValueError):
            pass
    return found


def wrapper_of(session_pid, wrappers):
    """hunk's binary runs under its node shim, which the wrapper started."""
    parent = ps(session_pid, "ppid")
    for pid in (parent, ps(parent, "ppid") if parent else None):
        if pid in wrappers:
            return pid
    return None


def parent_of(note):
    return note.get("parentId") or note.get("parentNoteId") or note.get("replyTo")


def item(note):
    summary, _, rationale = (note.get("body") or "").partition("\n\n")
    out = {"summary": summary or "(empty)"}
    if rationale:
        out["rationale"] = rationale
    author = note.get("author") or ("you" if note.get("source") == "user" else None)
    if author:
        out["author"] = author
    return out


def anchor(note):
    return note.get("filePath"), (note.get("newRange") or note.get("oldRange") or [None])[0]


def text(note):
    return (note.get("body") or "").strip()


def keys(notes):
    """noteId -> what makes two notes the same: line and text, and for a reply its parent's
    text too, so two findings on one line can each keep their own "ok"."""
    by_id = {n["noteId"]: n for n in notes}
    return {n["noteId"]: (*anchor(n), text(by_id[parent_of(n)]) if parent_of(n) in by_id
                          else ("(gone)" if parent_of(n) else None), text(n)) for n in notes}


def unique(notes):
    """The notes without repeats. A reply under a dropped repeat moves to the kept copy (its
    parentId changes); a reply whose parent is gone is dropped when its line has that reply."""
    key, alias, kept, out = keys(notes), {}, {}, []
    for note in sorted(notes, key=lambda n: parent_of(n) is not None):
        k = key[note["noteId"]]
        if k in kept:
            alias[note["noteId"]] = kept[k]
            continue
        kept[k] = note["noteId"]
        if parent_of(note) in alias:
            note = {**note, "parentId": alias[parent_of(note)]}
        out.append(note)
    replies = {(*anchor(n), text(n)) for n in out if parent_of(n) and key[n["noteId"]][2] != "(gone)"}
    return [n for n in out if key[n["noteId"]][2] != "(gone)" or (*anchor(n), text(n)) not in replies]


def apply(session_id, note, target):
    res = run("hunk", "session", "comment", "apply", session_id, "--stdin", "--json",
              stdin=json.dumps({"comments": [{**target, **item(note)}]}))
    applied = ((res or {}).get("result") or {}).get("applied") or []
    return applied[0]["commentId"] if applied else None


def dedupe(session_id, current):
    """Remove repeated notes from a live session: replies first, as Hunk keeps a note that
    still has replies. A distinct reply under a repeat is added again under the kept copy."""
    keep = unique(current)
    was_under = {n["noteId"]: parent_of(n) for n in current}
    drop = set(was_under) - {n["noteId"] for n in keep}
    for note in keep:
        if parent_of(note) != was_under[note["noteId"]]:
            if apply(session_id, note, {"replyTo": parent_of(note)}):
                drop.add(note["noteId"])
            else:
                drop.discard(was_under[note["noteId"]])  # its parent can't go while it stays
    for note in sorted(current, key=lambda n: parent_of(n) is None):
        if note["noteId"] in drop:
            run("hunk", "session", "comment", "rm", session_id, note["noteId"], "--json")


def restore(session_id, saved, current):
    """Add saved notes back that the session doesn't hold yet (a pane can be restored twice:
    the saver restarted, or a `session list` missed it), roots first, then replies under their
    parents. One note per call: a batch fails as a whole if any note's line has left the diff.
    Returns the notes that couldn't be placed."""
    saved = unique(saved)
    have = {k: i for i, k in keys(current).items()}
    new_id, unplaced, key = {}, [], keys(saved)
    for note in sorted(saved, key=lambda n: parent_of(n) is not None):
        if key[note["noteId"]] in have:
            new_id[note["noteId"]] = have[key[note["noteId"]]]
            continue
        if parent_of(note):
            if parent_of(note) not in new_id:
                unplaced.append(note)
                continue
            target = {"replyTo": new_id[parent_of(note)]}
        else:
            side = "newLine" if note.get("newRange") else "oldLine"
            line = (note.get("newRange") or note.get("oldRange") or [None])[0]
            if not note.get("filePath") or line is None:
                continue
            target = {"filePath": note["filePath"], side: line}
        new = apply(session_id, note, target)
        if new:
            new_id[note["noteId"]] = new
        else:
            unplaced.append(note)
    return unplaced


def load(path):
    try:
        with open(path) as f:
            return json.load(f).get("notes", [])
    except (OSError, ValueError):
        return []


def save(path, notes):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"saved": time.strftime("%Y-%m-%dT%H:%M:%S"), "notes": notes}, f, indent=1)
    os.replace(tmp, path)


def registry_stamp():
    """Changes when a pane registers, leaves, or touches its file to say hunk restarted."""
    with os.scandir(PANES) as entries:
        return os.stat(PANES).st_mtime, max((e.stat().st_mtime for e in entries), default=0)


def watch():
    os.makedirs(PANES, exist_ok=True)
    lock = open(os.path.join(STATE, "hunk-notes.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)  # one saver at a time
    except OSError:
        return
    known = {}  # session id -> {"file", "unplaced", "last"}
    last_cycle, last_seen, registry, waiting = 0.0, time.time(), None, 0
    while True:
        # Full round every INTERVAL; sooner when a pane opened, restarted or closed, and every
        # second while a pane's hunk hasn't shown up yet (it takes a moment to register)
        changed = registry_stamp() != registry
        if not changed and not waiting and time.time() - last_cycle < INTERVAL:
            time.sleep(1)
            continue
        if waiting:
            time.sleep(1)
            waiting -= 1
        registry, last_cycle = registry_stamp(), time.time()
        wrappers = panes()
        if wrappers:
            last_seen = time.time()
        elif time.time() - last_seen > 60:
            return
        listing = run("hunk", "session", "list", "--json")
        if listing is None:  # a failed call lists no session: forgetting them all would restore them again
            continue
        sessions = listing.get("sessions", [])
        for s in sessions:
            wrapper = wrapper_of(s["pid"], wrappers)
            if not wrapper:
                continue
            path, max_mb, flag = wrappers[wrapper]
            state = known.get(s["sessionId"])
            current = s.get("snapshot", {}).get("state", {}).get("reviewNotes", [])
            if state is None:  # new pane, or hunk restarted: put the saved notes back
                if len(unique(current)) < len(current):
                    dedupe(s["sessionId"], current)
                state = known[s["sessionId"]] = {"file": path, "unplaced": restore(s["sessionId"], load(path), unique(current)), "last": None}
                continue  # the snapshot doesn't have the restored notes yet; save next round
            if state["last"] is not None and not os.path.exists(path):  # cleared (cmd+/ n)
                state["unplaced"] = []
            notes = unique(current + state["unplaced"])
            if notes != state["last"]:
                save(path, notes)
                state["last"] = notes
            if (ps(s["pid"], "rss") or 0) // 1024 > max_mb:
                open(flag, "w").close()
                os.kill(s["pid"], signal.SIGTERM)
        live = {s["sessionId"] for s in sessions}
        known = {k: v for k, v in known.items() if k in live}
        matched = {wrapper_of(s["pid"], wrappers) for s in sessions}
        if not set(wrappers) - matched:
            waiting = 0
        elif changed:
            waiting = 20


def clear(worktree):
    top = os.path.realpath(worktree)
    for s in (run("hunk", "session", "list", "--json") or {}).get("sessions", []):
        if os.path.realpath(s.get("repoRoot") or s.get("cwd") or "") == top:
            run("hunk", "session", "comment", "clear", s["sessionId"], "--all", "--yes", "--json")
    git_dir = subprocess.run(["git", "-C", worktree, "rev-parse", "--path-format=absolute", "--git-dir"],
                             capture_output=True, text=True).stdout.strip()
    folder = os.path.join(git_dir, "hunk-notes")
    if os.path.isdir(folder):
        for name in os.listdir(folder):
            if name.endswith(".json"):
                os.remove(os.path.join(folder, name))


if __name__ == "__main__":
    if sys.argv[1:2] == ["watch"]:
        watch()
    elif sys.argv[1:2] == ["clear"]:
        clear(sys.argv[2])
    else:
        sys.exit(__doc__)
