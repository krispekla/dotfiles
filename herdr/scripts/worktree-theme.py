#!/usr/bin/env python3
"""Peacock-style project colours for herdr.

Each repo gets a colour; its main checkout has it and its worktrees the two nearest hues on
the colour wheel (blue: azure / indigo), so the colour family says which project you're in and
the exact hue which checkout. 22 hues, all chosen to stay clean on a dark background (see HUES).
Worktrees get the stronger tint and a text label, since two hues can still look alike. Review
worktrees (review-*) share the family; the label says "review".

Colour goes on the frame only, never on the panes or the sidebar background:
  - focused space: tab bar tinted, active tab and focused pane border in full colour, its
    Spaces row tinted; window title "<family dot> <name>"; worktrees add
    "work · <name> · :<port>" at the right of the tab bar and the port to the title
  - every coloured space: its workspace name in its colour, in the Spaces and Agents lists
  - anything that isn't a git repo: grey accent

A repo gets a colour the first time it's seen (least used first, blue / mauve / green before
the rest) and keeps it in ${XDG_STATE_HOME:-~/.local/state}/herdr/project-colours
("repo<TAB>colour" per line). `--next-colour` / `--prev-colour` (cmd+/ p / P) move the focused
project to the next / previous one. A worktree's hue is picked by its port (worktree-port.sh).

herdr has no per-workspace colours, so this writes a generated config: the real
~/.config/herdr/config.toml plus these overrides, at $HERDR_CONFIG_PATH
(~/.config/herdr/config.generated.toml, set in .zshenv). It runs on workspace focus,
worktree create/remove and herdr startup (plugin kris-tools), and reloads herdr only when
the output changed. The name colours go onto lines in config.toml marked "# worktree-colors".

Usage: worktree-theme.py [--reload] [focused workspace id]   (default: ask herdr)
       worktree-theme.py --next-colour|--prev-colour [workspace id]   print the new colour's name
  --reload  reload herdr even if nothing changed: `herdr-reload` after editing config.toml
"""
import colorsys
import json
import os
import subprocess
import sys

HOME = os.path.expanduser("~")
SOURCE = os.path.join(HOME, ".config/herdr/config.toml")
OUT = os.environ.get("HERDR_CONFIG_PATH") or os.path.join(HOME, ".config/herdr/config.generated.toml")
STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local/state"), "herdr")
REGISTRY = os.path.join(STATE, "ports")
FAMILY_REGISTRY = os.path.join(STATE, "project-colours")
HERDR = os.environ.get("HERDR_BIN_PATH") or "herdr"
MARK = "# worktree-colors"

# Hues that stay clean as tints on a dark background, with the window title dot: Catppuccin
# Mocha pastels plus a few from other dark themes (Tokyo Night, Dracula, One Dark), then deeper
# jewel tones (Tailwind, Solarized, Synthwave; cobalt, grape and purple lightened a little). Every one
# keeps the active tab's dark text readable (contrast >= 4.5). Left out: warm ones (peach,
# yellow, amber, coral, lime, sage) go brown or olive, ocean / frost / plum go grey, crimson /
# cherry read as an error, pine / raspberry are too dark for the tab text.
# Order: assignment preference and the cmd+/ p cycle, jumping around the colour wheel.
HUES = {
    "blue": ("#89b4fa", "🔵"), "mauve": ("#cba6f7", "🟣"), "green": ("#a6e3a1", "🟢"),
    "rose": ("#eb6f92", "🩷"), "aqua": ("#2ac3de", "🔵"), "indigo": ("#7287fd", "🔵"),
    "pink": ("#f5c2e7", "🩷"), "emerald": ("#50fa7b", "🟢"), "sapphire": ("#74c7ec", "🔵"),
    "violet": ("#9d7cd8", "🟣"), "magenta": ("#ff79c6", "🩷"), "teal": ("#94e2d5", "🟢"),
    "azure": ("#61afef", "🔵"), "lavender": ("#b4befe", "🟣"), "fuchsia": ("#e879f9", "🟣"),
    "sky": ("#89dceb", "🔵"), "cobalt": ("#4186f6", "🔵"), "hotpink": ("#f92aad", "🩷"),
    "jade": ("#10b981", "🟢"), "grape": ("#986ef7", "🟣"), "turquoise": ("#2aa198", "🟢"),
    "purple": ("#af63f8", "🟣"),
}


def hue(colour):
    return colorsys.rgb_to_hls(*[int(colour[i:i + 2], 16) / 255 for i in (1, 3, 5)])[0] * 360


def worktree_hues(name):
    """A project's worktrees get the two hues nearest to its own, so they read as the same family."""
    def distance(other):
        d = abs(hue(HUES[name][0]) - hue(HUES[other][0]))
        return min(d, 360 - d)
    return sorted((h for h in HUES if h != name), key=distance)[:2]


NEUTRAL_ACCENT = "#9399b2"  # overlay2: active tab and focus in spaces that aren't a git repo
# How strongly the colour is mixed into the tab bar, inactive tabs and the focused Spaces row
STRENGTH = {
    "main": {"panel": 0.18, "chip": 0.26, "row": 0.18},
    "worktree": {"panel": 0.30, "chip": 0.38, "row": 0.24},
}
# Catppuccin Mocha backgrounds the tints are mixed into: tab bar (mantle), sidebar (base)
PANEL_BG = "#181825"
BASE_BG = "#1e1e2e"


def herdr(*args):
    try:
        out = subprocess.run([HERDR, *args], capture_output=True, text=True, timeout=5).stdout
        return json.loads(out).get("result", {})
    except Exception:
        return {}


def mix(color, base, amount):
    c = [int(color[i:i + 2], 16) for i in (1, 3, 5)]
    b = [int(base[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(b[i] + (c[i] - b[i]) * amount):02x}" for i in range(3))


def read_ports():
    ports = {}
    try:
        with open(REGISTRY) as f:
            for line in f:
                port, _, path = line.rstrip("\n").partition("\t")
                if port.isdigit():
                    ports[path] = int(port)
    except FileNotFoundError:
        pass
    return ports


def read_families():
    known = {}
    try:
        with open(FAMILY_REGISTRY) as f:
            for line in f:
                repo, _, family = line.rstrip("\n").partition("\t")
                if family in HUES and os.path.isdir(repo):
                    known[repo] = family
    except FileNotFoundError:
        pass
    return known


def write_families(known):
    os.makedirs(STATE, exist_ok=True)
    tmp = FAMILY_REGISTRY + ".tmp"
    with open(tmp, "w") as f:
        f.writelines(f"{repo}\t{family}\n" for repo, family in known.items())
    os.replace(tmp, FAMILY_REGISTRY)


def families_for(repos):
    """repo root -> project colour: remembered, else the least used one (and remembered)."""
    known = read_families()
    new = [repo for repo in repos if repo not in known]
    for repo in new:
        used = list(known.values())
        known[repo] = min(HUES, key=lambda fam: (used.count(fam), list(HUES).index(fam)))
    if new:
        write_families(known)
    return known


def next_colour(ws, step):
    """Move the workspace's project to the next (step 1) or previous (-1) colour no other project
    has (any, if all are taken); returns its name, or None if not a repo."""
    repo = herdr("worktree", "list", "--workspace", ws).get("source", {}).get("repo_root")
    if not repo:
        return None
    known = families_for([repo])
    order = list(HUES)
    taken = {fam for r, fam in known.items() if r != repo}
    i = order.index(known[repo])
    rest = [order[(i + step * n) % len(order)] for n in range(1, len(order))]
    known[repo] = next((fam for fam in rest if fam not in taken), rest[0])
    write_families(known)
    return known[repo]


def space_colours():
    """(workspace id -> label for every space,
    workspace id -> dict(label, colour, dot, kind, port) for spaces open on a git checkout)"""
    labels = {w["workspace_id"]: w.get("label", "") for w in herdr("workspace", "list").get("workspaces", [])}
    ports = read_ports()
    listings = {}  # repo root -> worktree listing
    for ws in labels:
        if any(ws == wt.get("open_workspace_id") for l in listings.values() for wt in l.get("worktrees", [])):
            continue
        listing = herdr("worktree", "list", "--workspace", ws)
        repo = listing.get("source", {}).get("repo_root")
        if repo:
            listings[repo] = listing
    # Repos with the most worktrees pick first, so the busiest get the most distinct colours
    families = families_for(sorted(listings, key=lambda r: -sum(
        1 for wt in listings[r].get("worktrees", []) if wt.get("is_linked_worktree"))))
    result = {}
    for repo, listing in listings.items():
        family = families[repo]
        dot, main_colour = HUES[family][1], HUES[family][0]
        wt_colours = [HUES[h][0] for h in worktree_hues(family)]
        linked = [wt for wt in listing.get("worktrees", []) if wt.get("is_linked_worktree")]
        for wt in listing.get("worktrees", []):
            ws, path = wt.get("open_workspace_id"), wt.get("path", "")
            if ws not in labels:
                continue
            port = ports.get(path)
            if wt.get("is_linked_worktree"):
                kind = "review" if os.path.basename(path).startswith("review-") else "work"
                i = port - 3100 if port else linked.index(wt)
                colour = wt_colours[i % len(wt_colours)]
            else:
                kind, colour = "main", main_colour
            result[ws] = {"label": labels[ws], "colour": colour, "dot": dot, "kind": kind, "port": port}
    return labels, result


def toml_str(text):
    return json.dumps(text, ensure_ascii=False)


def insert(lines, table, keys):
    """Add keys to a table (creating it at the end if missing). Keys config.toml sets itself win."""
    if table not in lines:
        lines += ["", f"{table}  # added by worktree-theme.py"]
        start = len(lines)
    else:
        start = lines.index(table) + 1
    end = next((i for i in range(start, len(lines)) if lines[i].startswith("[")), len(lines))
    own = {l.split("=")[0].strip() for l in lines[start:end] if "=" in l and not l.lstrip().startswith("#")}
    lines[start:start] = [f"{k} = {v}" for k, v in keys.items() if k not in own]


def generate(focused):
    with open(SOURCE) as f:
        lines = f.read().splitlines()
    labels, spaces = space_colours()

    # Name colours: style the "workspace" token on marked rows (herdr allows 16 rules per token)
    rules = [f"{{ equals = {toml_str(s['label'])}, fg = \"{s['colour']}\" }}" for s in list(spaces.values())[:16]]
    styled = f'{{ token = "workspace", rules = [{", ".join(rules)}] }}' if rules else '"workspace"'
    lines = [l.replace('"workspace"', styled, 1) if MARK in l else l for l in lines]

    # Focused space: its colour on the frame, never on the panes or the sidebar background.
    # active_row_bg tints its Spaces row (and the focused Agent row: herdr shares the token).
    # The title gets the name itself: herdr 0.9.3's {workspace} can stay on an earlier space.
    name = labels.get(focused, "").replace("{", "{{").replace("}", "}}")
    space = spaces.get(focused)
    if space:
        colour, strength = space["colour"], STRENGTH["main" if space["kind"] == "main" else "worktree"]
        theme = {
            "accent": colour,
            "panel_bg": mix(colour, PANEL_BG, strength["panel"]),  # tab bar
            "surface0": mix(colour, PANEL_BG, strength["chip"]),  # inactive tabs, readable on the tint
            "active_row_bg": mix(colour, BASE_BG, strength["row"]),
        }
        port = f" · :{space['port']}" if space["port"] else ""
        ui = {"window_title": toml_str(f"{space['dot']} {name}{port}")}
        if space["kind"] != "main":
            ui["tab_bar_right"] = f'[{{ type = "text", text = {toml_str(space["kind"] + " · " + space["label"] + port)} }}]'
    else:
        theme = {"accent": NEUTRAL_ACCENT}
        ui = {"window_title": toml_str(name)}
    insert(lines, "[ui]", ui)
    insert(lines, "[theme.custom]", {k: toml_str(v) for k, v in theme.items()})

    text = "# GENERATED by herdr/scripts/worktree-theme.py from config.toml. Edit config.toml, not this.\n" \
        + "\n".join(lines) + "\n"
    try:
        with open(OUT) as f:
            if f.read() == text:
                return False
    except FileNotFoundError:
        pass
    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, OUT)
    return True


def main():
    args = sys.argv[1:]
    force = "--reload" in args
    step = 1 if "--next-colour" in args else -1 if "--prev-colour" in args else 0
    args = [a for a in args if a not in ("--reload", "--next-colour", "--prev-colour")]
    event = json.loads(os.environ.get("HERDR_PLUGIN_EVENT_JSON") or "{}")
    focused = args[0] if args else event.get("data", {}).get("workspace_id") or next(
        (w["workspace_id"] for w in herdr("workspace", "list").get("workspaces", []) if w.get("focused")), None)
    if step:
        name = next_colour(focused, step)
        print(name or "not a git repo")
        if not name:
            return
    if (generate(focused) or force) and os.environ.get("HERDR_CONFIG_PATH") == OUT:
        subprocess.run([HERDR, "server", "reload-config"], capture_output=True, timeout=5)


if __name__ == "__main__":
    main()
