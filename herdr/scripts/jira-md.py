#!/usr/bin/env python3
"""Jira ticket as Markdown, for ticket-view.sh: reads `trac issue get --include-comments` JSON on
stdin and prints the first issue as a page: summary, fields, links, description, comments. Jira's
wiki markup (h2., *bold*, {code}, [text|url], ||tables||, {color}…) becomes Markdown that glow renders.

  trac issue get ABC-123 --include-comments | jira-md.py [base url]

base url (https://<jira host>) makes the key a link to the ticket.
"""
import json
import re
import sys

EMOTICONS = {"(/)": "✅", "(x)": "❌", "(!)": "⚠️", "(i)": "ℹ️", "(?)": "❓", "(y)": "👍", "(n)": "👎",
             "(on)": "💡", "(*)": "⭐"}


def inline(text):
    # The editor pads markup with {} and writes {*}bold{*} next to other text: plain markers first.
    # Then code, so nothing inside it is touched.
    text = re.sub(r"\{([*_+^~?-])\}", r"\1", text.replace("{}", ""))
    parts = re.split(r"\{\{(.*?)\}\}", text)
    out = []
    for i, part in enumerate(parts):
        if i % 2:
            out.append("`%s`" % part)
            continue
        part = re.sub(r"\{color(:[^}]*)?\}", "", part)
        part = re.sub(r"\[~([^\]]+)\]", r"@\1", part)
        part = re.sub(r"\[([^\]|]+)\|([^\]]+)\]", r"[\1](\2)", part)
        part = re.sub(r"\[((?:https?|mailto):[^\]]+)\]", r"<\1>", part)
        part = re.sub(r"!([^!\s|]+)(\|[^!]*)?!", r"_(image: \1)_", part)
        part = re.sub(r"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])", r"**\1**", part)
        part = re.sub(r"(?<![\w_])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w_])", r"*\1*", part)
        part = re.sub(r"(?<![\w-])-(?=\S)([^-\n]+?)(?<=\S)-(?![\w-])", r"~~\1~~", part)
        part = re.sub(r"\?\?(.+?)\?\?", r"*\1*", part)
        for k, v in EMOTICONS.items():
            part = part.replace(k, v)
        out.append(part)
    return "".join(out).replace("\\\\", "  \n")


def table_row(line):
    cells = re.split(r"\|\|?", line.strip().strip("|"))
    return "| " + " | ".join(inline(c.strip()) for c in cells) + " |", len(cells)


def wiki(text, heading_shift=1):
    """Jira wiki markup -> Markdown. Headings move down a level: the page's own # is the summary."""
    lines = (text or "").replace("\r\n", "\n").replace(" ", " ").split("\n")
    out, block, table_cols = [], None, 0
    for line in lines:
        m = re.match(r"\s*\{(code|noformat)(?::([^}|]*))?[^}]*\}(.*)$", line)
        if block:
            end = line.find("{%s}" % block)
            if end >= 0:
                if line[:end].strip():
                    out.append(line[:end])
                out.append("```")
                block = None
            else:
                out.append(line)
            continue
        if m:
            block = m.group(1)
            out.append("```" + (m.group(2) or "").strip())
            rest = m.group(3)
            if rest.endswith("{%s}" % block):
                out.append(rest[: -len(block) - 2])
                out.append("```")
                block = None
            elif rest.strip():
                out.append(rest)
            continue
        if re.match(r"\s*\{quote\}\s*$", line):
            continue
        stripped = line.strip()
        if stripped.startswith("|"):
            row, cols = table_row(stripped)
            if not table_cols:
                out.append("")
                if not stripped.startswith("||"):  # Markdown needs a header row
                    out.append("|" + " |" * cols)
                    out.append("|" + " --- |" * cols)
                    table_cols = cols
                else:
                    out.append(row)
                    out.append("|" + " --- |" * cols)
                    table_cols = cols
                    continue
            out.append(row)
            continue
        if table_cols:
            table_cols = 0
            out.append("")
        h = re.match(r"h([1-6])\.\s*(.*)$", stripped)
        if h:
            out += ["", "#" * min(6, int(h.group(1)) + heading_shift) + " " + inline(h.group(2)), ""]
            continue
        if stripped.startswith("bq. "):
            out.append("> " + inline(stripped[4:]))
            continue
        if re.match(r"-{4,}$", stripped):
            out.append("\n---\n")
            continue
        li = re.match(r"([*#-]+)\s+(.*)$", stripped)
        if li and (li.group(1)[0] != "-" or len(li.group(1)) == 1):
            marks = li.group(1)
            bullet = "1." if marks[-1] == "#" else "-"
            out.append("  " * (len(marks) - 1) + bullet + " " + inline(li.group(2)))
            continue
        # Jira breaks the line at every newline; Markdown needs two trailing spaces for that
        out.append(inline(line.rstrip()) + ("  " if stripped else ""))
    if block:
        out.append("```")
    md = "\n".join(out)
    return re.sub(r"\n{3,}", "\n\n", md).strip()


def name(person):
    return (person or {}).get("displayName") or "nobody"


def main():
    base = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else ""
    data = json.load(sys.stdin)
    issues = data.get("issues") or []
    if not issues:
        print("# Ticket not found\n\n" + json.dumps(data.get("errors") or data, indent=2)[:2000])
        return
    t = issues[0]
    key = t["key"]
    print("# %s · %s\n" % (key, t.get("summary", "")))
    facts = [t.get("issueType"), "**%s**" % t.get("status"), t.get("priority") and "priority %s" % t["priority"]]
    print(" · ".join(f for f in facts if f))
    print("assignee %s · reporter %s · created %s · updated %s" % (
        name(t.get("assignee")), name(t.get("reporter")), (t.get("created") or "")[:10], (t.get("updated") or "")[:10]))
    extra = []
    sprints = [s.get("name") for s in t.get("sprint") or [] if s.get("name")]
    if sprints:
        extra.append("sprint " + sprints[-1])
    if t.get("storyPoints") is not None:
        extra.append("%s points" % t["storyPoints"])
    if t.get("epicLink"):
        extra.append("epic " + t["epicLink"])
    for label in ("labels", "components"):
        if t.get(label):
            extra.append("%s: %s" % (label, ", ".join(map(str, t[label]))))
    if extra:
        print(" · ".join(extra))
    if base:
        print("\n%s/browse/%s" % (base, key))

    links = t.get("links") or []
    if links:
        print("\n## Linked tickets\n")
        for link in links:
            other = link.get("issue") or {}
            kind = link.get("type")
            if isinstance(kind, dict):
                kind = kind.get(link.get("direction") or "") or kind.get("name")
            print("- %s **%s** %s · _%s_" % (kind or "", other.get("key"), other.get("summary", ""), other.get("status", "")))

    print("\n## Description\n")
    print(wiki(t.get("description")) or "_No description._")

    comments = t.get("comments") or []
    if comments:
        print("\n## Comments (%d)\n" % len(comments))
        for c in comments:
            print("### %s · %s\n" % (name(c.get("author")) if isinstance(c.get("author"), dict) else c.get("author"),
                                      (c.get("created") or "")[:10]))
            print(wiki(c.get("body"), heading_shift=3) + "\n")


if __name__ == "__main__":
    main()
