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
author "you" so they can still be told apart. A note whose line isn't in the diff right now
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


def restore(session_id, saved):
    """Add saved notes back, roots first, then replies under their restored parents. One note
    per call: a batch fails as a whole if any note's line has left the diff. Returns the notes
    that couldn't be placed."""
    new_id, unplaced = {}, []
    for note in sorted(saved, key=lambda n: parent_of(n) is not None):
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
        res = run("hunk", "session", "comment", "apply", session_id, "--stdin", "--json",
                  stdin=json.dumps({"comments": [{**target, **item(note)}]}))
        applied = ((res or {}).get("result") or {}).get("applied") or []
        if applied:
            new_id[note["noteId"]] = applied[0]["commentId"]
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
        sessions = (run("hunk", "session", "list", "--json") or {}).get("sessions", [])
        for s in sessions:
            wrapper = wrapper_of(s["pid"], wrappers)
            if not wrapper:
                continue
            path, max_mb, flag = wrappers[wrapper]
            state = known.get(s["sessionId"])
            if state is None:  # new pane, or hunk restarted: put the saved notes back
                state = known[s["sessionId"]] = {"file": path, "unplaced": restore(s["sessionId"], load(path)), "last": None}
                continue  # the snapshot doesn't have the restored notes yet; save next round
            current = s.get("snapshot", {}).get("state", {}).get("reviewNotes", [])
            if state["last"] is not None and not os.path.exists(path):  # cleared (cmd+/ n)
                state["unplaced"] = []
            if current + state["unplaced"] != state["last"]:
                save(path, current + state["unplaced"])
                state["last"] = current + state["unplaced"]
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
