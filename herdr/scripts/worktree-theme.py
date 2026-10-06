#!/usr/bin/env python3
"""Peacock-style colours for herdr: every project and worktree gets its own colour.

  - main checkout: the project's colour, calm tint
  - work worktree: its own colour, stronger tint, picked to look as different as possible from
    every other open space (perceptual OKLab distance, not just hue)
  - review worktree (review-*): a review colour, the pinks, which nothing else ever gets, so
    pink always means "reviewing"; window title starts with 🔍
All 22 hues stay clean on a dark background (see HUES). Once picked, a colour is kept.

Colour goes on the frame only, never on the panes or the sidebar background:
  - focused space: tab bar tinted, active tab and focused pane border in full colour, its
    Spaces row tinted; window title "<dot> <name>"; worktrees add
    "work · <name> · :<port>" (or "review · ...") at the right of the tab bar and the port to
    the title
  - every coloured space: its workspace name in its colour, in the Spaces and Agents lists
  - anything that isn't a git repo: grey accent

Colours are remembered in ${XDG_STATE_HOME:-~/.local/state}/herdr/project-colours (repo root)
and worktree-colours (worktree path), "path<TAB>colour" per line. `--next-colour` /
`--prev-colour` (cmd+/ p / P) move the focused space to the next / previous colour of its
set that no other open space has: a main checkout changes its project colour, a worktree only
its own.

herdr has no per-workspace colours, so this writes a generated config: the real
~/.config/herdr/config.toml plus these overrides, at $HERDR_CONFIG_PATH
(~/.config/herdr/config.generated.toml, set in .zshenv). It runs on workspace focus,
worktree create/remove and herdr startup (plugin kris-tools), and reloads herdr only when
the output changed. The name colours go onto lines in config.toml marked "# worktree-colors".

Usage: worktree-theme.py [--reload] [focused workspace id]   (default: ask herdr)
       worktree-theme.py --next-colour|--prev-colour [workspace id]   print the new colour's name
  --reload  reload herdr even if nothing changed: `herdr-reload` after editing config.toml
"""
import json
import os
import re
import socket
import subprocess
import sys

HOME = os.path.expanduser("~")
SOURCE = os.path.join(HOME, ".config/herdr/config.toml")
OUT = os.environ.get("HERDR_CONFIG_PATH") or os.path.join(HOME, ".config/herdr/config.generated.toml")
STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local/state"), "herdr")
REGISTRY = os.path.join(STATE, "ports")
PROJECT_REGISTRY = os.path.join(STATE, "project-colours")
WORKTREE_REGISTRY = os.path.join(STATE, "worktree-colours")
LAYOUT_STATE = os.path.join(STATE, "sidebar-layout.json")  # name rows last reported to herdr
HERDR = os.environ.get("HERDR_BIN_PATH") or "herdr"
MARK = "# worktree-colors"

# Colours that work on a dark background: Catppuccin Mocha plus picks from Tokyo Night,
# Dracula, One Dark, Tailwind and Solarized, warm ones in saturated versions so their tint reads
# warm rather than muddy. Left out: near-copies (orange, honey, olive, mint, cyan, ...), ocean /
# frost / plum go grey, pine / raspberry are too dark for the tab text.
# Projects and work worktrees: (accent, window title dot). Order: the cmd+/ p cycle, jumping
# around the colour wheel. No purples: those mean "review".
HUES = {
    "blue": ("#89b4fa", "🔵"), "green": ("#a6e3a1", "🟢"), "tangerine": ("#ff8c42", "🟠"),
    "aqua": ("#2ac3de", "🔵"), "rose": ("#eb6f92", "🩷"), "emerald": ("#50fa7b", "🟢"),
    "gold": ("#e5c07b", "🟡"), "indigo": ("#7287fd", "🔵"), "red": ("#ff6b6b", "🔴"),
    "teal": ("#94e2d5", "🟢"), "magenta": ("#ff79c6", "🩷"), "sapphire": ("#74c7ec", "🔵"),
    "lime": ("#9ece6a", "🟢"), "peach": ("#fab387", "🟠"), "cobalt": ("#4186f6", "🔵"),
    "pink": ("#f5c2e7", "🩷"), "jade": ("#10b981", "🟢"), "amber": ("#e0af68", "🟠"),
    "azure": ("#61afef", "🔵"), "coral": ("#ff7f6b", "🔴"), "lavender": ("#b4befe", "🔵"),
    "turquoise": ("#2aa198", "🟢"), "hotpink": ("#f92aad", "🩷"), "sky": ("#89dceb", "🔵"),
    "yellow": ("#f9e2af", "🟡"), "fuchsia": ("#e879f9", "🩷"),
}
# Review worktrees only: (light purple accent, 🔍, dark purple the tab bar is tinted with), so
# a review always has a dark purple bar
REVIEW_HUES = {
    "amethyst": ("#cba6f7", "🔍", "#7c3aed"), "iris": ("#b794f6", "🔍", "#6d28d9"),
    "orchid": ("#d0a8ff", "🔍", "#5b21b6"), "plum": ("#c084fc", "🔍", "#7e22ce"),
    "violet": ("#a78bfa", "🔍", "#4c1d95"), "wisteria": ("#e0b0ff", "🔍", "#6b21a8"),
}
NEUTRAL_ACCENT = "#9399b2"  # overlay2: active tab and focus in spaces that aren't a git repo
# Most the colour is mixed into the tab bar and the focused Spaces row. Less when needed: the
# active tab's text is drawn in the tab bar colour and must stay readable on the accent.
STRENGTH = {"main": {"panel": 0.18, "row": 0.18}, "work": {"panel": 0.30, "row": 0.24},
            "review": {"panel": 0.50, "row": 0.40}}
MIN_CONTRAST = 4.5
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


def luminance(colour):
    lin = [v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
           for v in (int(colour[i:i + 2], 16) / 255 for i in (1, 3, 5))]
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]


def contrast(a, b):
    light, dark = sorted((luminance(a), luminance(b)), reverse=True)
    return (light + 0.05) / (dark + 0.05)


def readable_amount(accent, source, base, most):
    """How much of source to mix into base, at most `most`, with accent still readable on it."""
    amount = most
    while amount > 0.08 and contrast(accent, mix(source, base, amount)) < MIN_CONTRAST:
        amount -= 0.01
    return amount


def oklab(colour):
    """OKLab coordinates: distances between them track how different two colours look."""
    lin = [((v / 255 + 0.055) / 1.055) ** 2.4 if v / 255 > 0.04045 else v / 255 / 12.92
           for v in (int(colour[i:i + 2], 16) for i in (1, 3, 5))]
    l, m, s = (sum(w * c for w, c in zip(row, lin)) ** (1 / 3) for row in (
        (0.4122214708, 0.5363325363, 0.0514459929),
        (0.2119034982, 0.6806995451, 0.1073969566),
        (0.0883024619, 0.2817188376, 0.6299787110)))
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


def distance(a, b):
    return sum((x - y) ** 2 for x, y in zip(oklab(a), oklab(b))) ** 0.5


def most_distinct(pool, used):
    """The colour of the pool that looks least like any colour in use (pool order breaks ties)."""
    names = list(pool)
    return max(names, key=lambda n: (min((distance(pool[n][0], u) for u in used), default=1), -names.index(n)))


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


def read_colours(path):
    """path -> colour name, for folders that still exist."""
    known = {}
    try:
        with open(path) as f:
            for line in f:
                folder, _, name = line.rstrip("\n").partition("\t")
                if os.path.isdir(folder):
                    known[folder] = name
    except FileNotFoundError:
        pass
    return known


def write_colours(path, known):
    os.makedirs(STATE, exist_ok=True)
    with open(path + ".tmp", "w") as f:
        f.writelines(f"{folder}\t{name}\n" for folder, name in known.items())
    os.replace(path + ".tmp", path)


def space_colours():
    """(herdr's workspace list, in sidebar order,
    workspace id -> dict(label, colour, name, dot, kind, port, key) for spaces on a git checkout;
    key is the registry entry: the repo root for a main checkout, the path for a worktree)"""
    workspaces = herdr("workspace", "list").get("workspaces", [])
    labels = {w["workspace_id"]: w.get("label", "") for w in workspaces}
    ports = read_ports()
    listings = {}  # repo root -> worktree listing
    for ws in labels:
        if any(ws == wt.get("open_workspace_id") for l in listings.values() for wt in l.get("worktrees", [])):
            continue
        listing = herdr("worktree", "list", "--workspace", ws)
        repo = listing.get("source", {}).get("repo_root")
        if repo:
            listings[repo] = listing
    projects, worktrees = read_colours(PROJECT_REGISTRY), read_colours(WORKTREE_REGISTRY)
    before = (dict(projects), dict(worktrees))
    spaces = []  # (ws, kind, key, port), main checkouts first
    for repo, listing in listings.items():
        for wt in listing.get("worktrees", []):
            ws, path = wt.get("open_workspace_id"), wt.get("path", "")
            if ws in labels:
                kind = "main" if not wt.get("is_linked_worktree") else \
                    "review" if os.path.basename(path).startswith("review-") else "work"
                spaces.append((ws, kind, repo if kind == "main" else path, ports.get(path), wt.get("branch")))
    spaces.sort(key=lambda s: s[1] != "main")
    # Keep remembered colours that still fit their set; then give the rest, one by one, the
    # colour least like everything already on screen
    pool_of = lambda kind: REVIEW_HUES if kind == "review" else HUES
    registry_of = lambda kind: projects if kind == "main" else worktrees
    names = {}
    for ws, kind, key, *_ in spaces:
        if registry_of(kind).get(key) in pool_of(kind):
            names[ws] = registry_of(kind)[key]
    for ws, kind, key, *_ in spaces:
        if ws not in names:
            pool = pool_of(kind)
            names[ws] = registry_of(kind)[key] = most_distinct(pool, [{**HUES, **REVIEW_HUES}[n][0] for n in names.values()])
    if (projects, worktrees) != before:
        write_colours(PROJECT_REGISTRY, projects)
        write_colours(WORKTREE_REGISTRY, worktrees)
    result = {}
    for ws, kind, key, port, branch in spaces:
        colour, dot, *bar = pool_of(kind)[names[ws]]
        result[ws] = {"label": labels[ws], "colour": colour, "bar": (bar or [colour])[0], "name": names[ws],
                      "dot": dot, "kind": kind, "port": port, "key": key, "branch": branch}
    return workspaces, result


NAME_ROWS = 5  # $name, $name2 … $name5 in config.toml's Spaces rows


def split_name(label, width):
    """The label in rows that fit the sidebar, broken after - / or space where possible."""
    rows = []
    while len(label) > width and len(rows) < NAME_ROWS - 1:
        cut = max(label.rfind(c, 0, width) for c in "-/ ") + 1
        cut = cut if cut > width // 2 else width
        rows.append(label[:cut])
        label = label[cut:]
    return rows + [label]


def sidebar_width(configured):
    """The sidebar's real width: the herdr window's terminal width minus the pane area herdr
    reports. A running herdr can keep a width other than config.toml's, so measure when we can."""
    try:
        clients = subprocess.run(["ps", "-axo", "tty=,comm="], capture_output=True, text=True).stdout.split("\n")
        tty = next(l.split()[0] for l in clients if l.split()[1:] and l.split()[-1].endswith("herdr")
                   and l.split()[0] != "??")
        cols = int(subprocess.run(["stty", "-f", f"/dev/{tty}", "size"], capture_output=True, text=True).stdout.split()[1])
        layouts = herdr("api", "snapshot").get("snapshot", {}).get("layouts", [])
        width = cols - max(l["area"]["width"] for l in layouts)
        return width if 10 <= width <= 80 else configured
    except Exception:
        return configured


def sidebar_layout(workspaces, spaces, width):
    """Whole names over as many rows as they need ($name … $name5; herdr has no wrapping), and per project its review
    worktrees last in the group, after all the work worktrees. Returns (workspace id -> tokens,
    [(review ids, id they go before or None)] for groups whose order needs fixing)."""
    tokens, moves = {}, []
    order = [w["workspace_id"] for w in workspaces]
    for w in workspaces:
        child = (w.get("worktree") or {}).get("is_linked_worktree")  # indented under its project
        rows = split_name(w.get("label", ""), width - (11 if child else 5))
        tokens[w["workspace_id"]] = {("name" if i == 0 else f"name{i + 1}"): (rows[i] if i < len(rows) else None)
                                     for i in range(NAME_ROWS)}
    groups = {}
    for w in workspaces:
        repo = (w.get("worktree") or {}).get("repo_key")
        if repo:
            groups.setdefault(repo, []).append(w["workspace_id"])
    for members in groups.values():
        children = [ws for ws in members if spaces.get(ws, {}).get("kind") in ("work", "review")]
        reviews = [ws for ws in children if spaces[ws]["kind"] == "review"]
        if not reviews:
            continue
        if children != [ws for ws in children if ws not in reviews] + reviews:
            after = order.index(members[-1]) + 1
            moves.append((reviews, order[after] if after < len(order) else None))
    return tokens, moves


def apply_layout(tokens, moves):
    """Report the name rows to herdr (only what changed since last time) and reorder reviews."""
    try:
        with open(LAYOUT_STATE) as f:
            reported = json.load(f)
    except (OSError, ValueError):
        reported = {}
    for ws, values in tokens.items():
        if reported.get(ws) == values:
            continue
        args = ["workspace", "report-metadata", ws, "--source", "worktree-theme"]
        for key, value in values.items():
            args += ["--token", f"{key}={value}"] if value else ["--clear-token", key]
        herdr(*args)
    os.makedirs(STATE, exist_ok=True)
    with open(LAYOUT_STATE, "w") as f:
        json.dump(tokens, f)
    for reviews, before in moves:
        api("workspace.move_block", {"workspace_ids": reviews, "before_workspace_id": before})


def api(method, params):
    """One request on herdr's socket, for methods the CLI doesn't have."""
    path = os.environ.get("HERDR_SOCKET_PATH") or os.path.join(HOME, ".config/herdr/herdr.sock")
    try:
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(5)
            sock.connect(path)
            sock.sendall((json.dumps({"id": "worktree-theme", "method": method, "params": params}) + "\n").encode())
            sock.recv(65536)
    except OSError:
        pass


def next_colour(ws, step):
    """Move the space to the next (step 1) or previous (-1) colour of its set that no other open
    space has (any, if all are taken); returns its name, or None if not a repo. A main checkout
    changes its project's colour, a worktree only its own."""
    _, spaces = space_colours()
    space = spaces.get(ws)
    if not space:
        return None
    pool = list(REVIEW_HUES if space["kind"] == "review" else HUES)
    taken = {s["name"] for w, s in spaces.items() if w != ws}
    i = pool.index(space["name"])
    rest = [pool[(i + step * n) % len(pool)] for n in range(1, len(pool))]
    name = next((n for n in rest if n not in taken), rest[0])
    registry = PROJECT_REGISTRY if space["kind"] == "main" else WORKTREE_REGISTRY
    known = read_colours(registry)
    known[space["key"]] = name
    write_colours(registry, known)
    return name


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
    workspaces, spaces = space_colours()
    labels = {w["workspace_id"]: w.get("label", "") for w in workspaces}
    width = sidebar_width(next((int(m.group(1)) for l in lines if (m := re.match(r"\s*sidebar_width\s*=\s*(\d+)", l))), 26))
    tokens, moves = sidebar_layout(workspaces, spaces, width)
    apply_layout(tokens, moves)

    # Name colours on marked rows (herdr allows 16 rules per token): "workspace" by label, the
    # name rows by their text, and "branch" by branch for worktrees (main checkouts all say "main")
    def styled(token, pairs):
        rules = [f"{{ equals = {toml_str(text)}, fg = \"{colour}\" }}" for text, colour in pairs[:16]]
        return f'{{ token = "{token}", rules = [{", ".join(rules)}] }}' if rules else f'"{token}"'
    def rows(key):
        return [(tokens[ws][key], s["colour"]) for ws, s in spaces.items() if tokens.get(ws, {}).get(key)]
    styles = {
        '"workspace"': styled("workspace", [(s["label"], s["colour"]) for s in spaces.values()]),
        **{f'"${key}"': styled(f"${key}", rows(key)) for key in ["name"] + [f"name{i}" for i in range(2, NAME_ROWS + 1)]},
        '"branch"': styled("branch", [(s["branch"], s["colour"]) for s in spaces.values() if s["kind"] != "main" and s["branch"]]),
    }
    for i, l in enumerate(lines):
        if MARK in l:
            for plain, style in styles.items():
                l = l.replace(plain, style, 1)
            lines[i] = l

    # Focused space: its colour on the frame, never on the panes or the sidebar background.
    # active_row_bg tints its Spaces row (and the focused Agent row: herdr shares the token).
    # The title gets the name itself: herdr 0.9.3's {workspace} can stay on an earlier space.
    name = labels.get(focused, "").replace("{", "{{").replace("}", "}}")
    space = spaces.get(focused)
    if space:
        colour, bar, most = space["colour"], space["bar"], STRENGTH[space["kind"]]
        panel = readable_amount(colour, bar, PANEL_BG, most["panel"])
        theme = {
            "accent": colour,
            "panel_bg": mix(bar, PANEL_BG, panel),  # tab bar, and the active tab's text
            "surface0": mix(bar, PANEL_BG, panel + 0.08),  # inactive tabs, a step lighter
            "active_row_bg": mix(bar, BASE_BG, readable_amount(colour, bar, BASE_BG, most["row"])),
        }
        port = f" · :{space['port']}" if space["port"] else ""
        ui = {"window_title": toml_str(f"{space['dot']} {name}{port}")}
        if space["kind"] != "main":
            # herdr names review spaces "review <branch>": don't say "review" twice
            label = space["label"].removeprefix(space["kind"] + " ")
            ui["tab_bar_right"] = f'[{{ type = "text", text = {toml_str(space["kind"] + " · " + label + port)} }}]'
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
