#!/bin/sh
# Open experimental headless Chrome in a herdr tab; no changes to the normal Chrome profile.
set -eu
PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
S=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
herdr="${HERDR_BIN_PATH:-herdr}"

if [ "${1:-}" = --help ]; then
  echo "Usage: chrome-pane.sh [http(s)://url]"
  echo "Opens a chrome tab in this workspace; defaults to its worktree port (main: 8000)."
  exit 0
fi
[ "$#" -le 1 ] || { echo "Usage: chrome-pane.sh [http(s)://url]" >&2; exit 2; }
[ "${HERDR_ENV:-}" = 1 ] || { echo "Run this inside herdr." >&2; exit 1; }
workspace="${HERDR_ACTIVE_WORKSPACE_ID:-${HERDR_WORKSPACE_ID:-}}"
[ -n "$workspace" ] || { echo "No herdr workspace context." >&2; exit 1; }
node=$(command -v node) || { echo "Chrome pane needs Node.js 22+ on PATH." >&2; exit 1; }
cwd="${HERDR_ACTIVE_PANE_CWD:-$PWD}"
url="${1:-}"
if [ -z "$url" ]; then
  top=$(git -C "$cwd" rev-parse --show-toplevel)
  port=$("$S/worktree-port.sh" get "$top")
  url="http://localhost:${port:-8000}/"
fi
"$node" --input-type=module -e '
  const {webURL, CHROME} = await import(process.argv[2]);
  webURL(process.argv[3]);
  const {access} = await import("node:fs/promises");
  await access(process.env.CHROME_BIN || CHROME);
' chrome-pane-preflight \
  "$S/chrome-pane.mjs" "$url"

created=$("$herdr" tab create --workspace "$workspace" --cwd "$cwd" --label chrome --no-focus)
pane=$(printf '%s' "$created" | jq -er '.result.root_pane.pane_id')
# Pass arguments as shell literals, never interpolate a URL as a command.
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
command="$(quote "$node") $(quote "$S/chrome-pane.mjs") $(quote "$url")"
"$herdr" pane run "$pane" "$command" >/dev/null
printf 'Chrome is starting in %s (tab chrome). Ctrl+Q quits the browser.\n' "$pane"
