#!/bin/bash
# Claude Code status line. Items share a line while they fit and wrap when they don't:
#    project   branch                                   Opus 5.5 · high
#    context ▰▰▰▰▱▱▱▱▱▱ 42%    session ▰▰▰▰▱ 73% resets 3:30pm    week 91%
# Colour only appears as a warning (yellow >= 70%, red >= 90%) so the line stays calm.

export LC_ALL=en_US.UTF-8
input=$(cat)

IFS=$'\t' read -r dir model effort ctx five five_reset week < <(
  echo "$input" | jq -r '[
    .workspace.current_dir,
    .model.display_name,
    (.effort.level // ""),
    (.context_window.used_percentage // "" | tostring | split(".")[0]),
    (.rate_limits.five_hour.used_percentage // "" | tostring | split(".")[0]),
    (.rate_limits.five_hour.resets_at // ""),
    (.rate_limits.seven_day.used_percentage // "" | tostring | split(".")[0])
  ] | @tsv'
)

bold=$'\033[1m'; dim=$'\033[2m'; blue=$'\033[34m'; magenta=$'\033[35m'; cyan=$'\033[36m'; green=$'\033[32m'
periwinkle=$'\033[38;5;111m'
yellow=$'\033[33m'; red=$'\033[31m'; reset=$'\033[0m'

visible_len() { # length without colour codes
  local s
  s=$(printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g')
  echo "${#s}"
}

meter() { # $1 label, $2 percent, $3 bar cells (0 = number only), $4 colour, $5 optional suffix
  local p=$2 cells=$3 hue=$4 c=$4 filled bar="" i
  if [ "$p" -ge 90 ]; then c=$red; elif [ "$p" -ge 70 ]; then c=$yellow; fi
  if [ "$cells" -gt 0 ]; then
    filled=$(( (p * cells + 50) / 100 )); [ "$filled" -gt "$cells" ] && filled=$cells
    bar=" ${c}"
    for ((i = 0; i < cells; i++)); do
      [ "$i" -eq "$filled" ] && bar+="${reset}${dim}"
      if [ "$i" -lt "$filled" ]; then bar+="▰"; else bar+="▱"; fi
    done
    bar+="${reset}"
  fi
  printf '%s%s%s%s %s%s%s%%%s%s' "$hue" "$1" "$reset" "$bar" "$bold" "$c" "$p" "$reset" "$5"
}

# Row 1: where you are (left) and what is running (right)
i_dir=$'\xef\x81\xbb' i_branch=$'\xee\x82\xa0' i_ctx=$'\xef\x81\xb5' i_clock=$'\xef\x80\x97' i_cal=$'\xef\x81\xb3' # Nerd Font icons

left="${blue}${bold}${i_dir} ${dir##*/}${reset}"
branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || git -C "$dir" rev-parse --short HEAD 2>/dev/null)
[ -n "$branch" ] && left+="   ${magenta}${i_branch} ${branch}${reset}"

right="${bold}${periwinkle}${model}${reset}"
# Effort: Claude Code's own level symbols (○ ◐ ● ◉ ◈); colour heats up lavender → orange → red
case "$effort" in
  low)    effort_i="○" ;;
  medium) effort_i="◐" ;;
  xhigh)  effort_i="◉" ;;
  max)    effort_i="◈" ;;
  *)      effort_i="●" ;;
esac
case "$effort" in
  medium) effort_c=$'\033[38;2;145;200;130m' ;;    # green
  high)  effort_c=$'\033[38;2;175;135;255m' ;;     # lavender
  xhigh) effort_c=$'\033[38;2;255;153;0m' ;;       # orange
  max)   effort_c=$'\033[1;38;2;235;95;87m' ;;     # red
  *)     effort_c=$dim ;;                          # low: quiet
esac
[ -n "$effort" ] && right+=" ${dim}·${reset} ${effort_c}${effort_i} ${effort}${reset}"

width=$(( ${COLUMNS:-100} - 12 ))  # row with right-aligned model: keep clear of the edge, Claude Code cuts there
mwidth=$(( ${COLUMNS:-100} - 4 )) # meter rows: nothing right-aligned, so they can run closer to the edge
sep="   "

# Usage meters
meters=()
[ -n "$ctx" ] && meters+=("$(meter "${i_ctx} context" "$ctx" 10 "$cyan")")
if [ -n "$five" ]; then
  t=$( [ -n "$five_reset" ] && date -r "$five_reset" '+%-I:%M%p' | tr 'APM' 'apm')
  meters+=("$(meter "${i_clock} session" "$five" 5 "$green" "${t:+ ${dim}resets $t${reset}}")")
fi
if [ -n "$week" ]; then
  meters+=("$(meter "${i_cal} week" "$week" 0 "$blue")")
fi

# Layout: one line if everything fits; otherwise wrap items onto new lines
right_align() { # $1 left, $2 right
  local gap=$(( width - $(visible_len "$1") - $(visible_len "$2") ))
  printf '%s%*s%s' "$1" "$gap" "" "$2"
}

all="$left"
for m in "${meters[@]}"; do all+="$sep$m"; done
if [ $(( $(visible_len "$all") + ${#sep} + $(visible_len "$right") )) -le "$width" ]; then
  right_align "$all" "$right"
  exit 0
fi

if [ $(( $(visible_len "$left") + ${#sep} + $(visible_len "$right") )) -le "$width" ]; then
  right_align "$left" "$right"
else
  printf '%s\n%s' "$left" "$right"
fi

line=""
for m in "${meters[@]}"; do
  if [ -n "$line" ] && [ $(( $(visible_len "$line") + ${#sep} + $(visible_len "$m") )) -gt "$mwidth" ]; then
    printf '\n%s' "$line"; line="$m"
  else
    line+="${line:+$sep}$m"
  fi
done
[ -n "$line" ] && printf '\n%s' "$line"
exit 0
